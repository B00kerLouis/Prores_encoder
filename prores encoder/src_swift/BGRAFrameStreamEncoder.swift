import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import Darwin

/// A bounded, single-pass path for host-rendered BGRA frames. It reuses the
/// encoder's Metal transforms and VideoToolbox session, and muxes their samples
/// directly beside the destination. Replay/metadata workflows keep the file API.
final class BGRAFrameStreamEncoder {
    private let width: Int
    private let height: Int
    private let frameDuration: CMTime
    private let pool: CVPixelBufferPool
    private let compression: ProResSession
    private let transform: MetalColorPipeline?
    private let mux: BGRAStreamMuxer
    private var frames: Int64 = 0
    private let cancellationRequested: () -> Bool
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var committed = false

    static func supports(options: ProResEncodeOptions, format: ProResOutputFormat) -> Bool {
        let proRes = ["proxy", "422lt", "422", "422hq", "4444", "4444xq"].contains(options.quality.lowercased())
        // Default GOP/multi-pass behavior remains in the existing file pipeline.
        let simpleCompressed = ["hevc", "h264"].contains(options.quality.lowercased())
            && options.bFrames == false && options.multiPass == false
        return (proRes && format == .mov || simpleCompressed && (format == .mov || format == .mp4))
            && options.extraAudioURL == nil && options.forcedOutputStartTimecode == nil
            && options.dolbyVisionXMLURL == nil && options.dolbyVisionProfile == nil
            && options.cmuMasteringNits == nil && !options.includeGeneratedDolbyVisionMetadata
            && !options.useDolbyVisionCodecTag && !options.outputVideoRaw && options.aafMode == .none
    }

    init(outputURL: URL, width: Int, height: Int, numerator: Int32, denominator: Int32,
         options: ProResEncodeOptions, sourceColor: SourceColorSpace?,
         cancellationRequested: @escaping () -> Bool) throws {
        self.cancellationRequested = cancellationRequested
        self.width = width
        self.height = height
        frameDuration = CMTime(value: Int64(denominator), timescale: numerator)
        let transaction = DirectOutputTransaction(finalURL: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let codec = proResCodecType(options.quality.lowercased())
        let compressed = codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_H264
        let destinationFormat = compressed ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let request = try options.makeColorTransformRequest()
        if let request {
            guard let sourceColor else { throw ColorTransformError.unsupportedSourcePrimaries(nil) }
            transform = try MetalColorPipeline(
                transform: resolveColorTransform(request: request, sourceColorSpace: sourceColor),
                width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA,
                outputPixelFormat: destinationFormat)
        } else {
            transform = nil
        }
        let outputColor = try request.map { request in
            try resolveColorTransform(request: request, sourceColorSpace: sourceColor!).outputColorSpace
        } ?? sourceColor
        compression = try ProResSession(width: width, height: height, codecType: codec,
            fpsHint: max(1, Int((Double(numerator) / Double(denominator)).rounded())), colorSpace: outputColor,
            hevcOptions: compressed ? HEVCEncodeOptions(bitrateMbps: options.bitrateMbps ?? 50,
                dvProfile: nil, bFrames: false, multiPass: false) : nil,
            sourcePixelFormat: transform == nil ? kCVPixelFormatType_32BGRA : destinationFormat)
        var createdPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary, &createdPool)
        guard status == kCVReturnSuccess, let createdPool else {
            throw MetalColorPipelineError.pixelBufferPoolFailed(status)
        }
        pool = createdPool
        mux = try BGRAStreamMuxer(transaction: transaction, cancellationRequested: cancellationRequested)
        compression.setEncodedSampleHandler { [mux] sample in mux.enqueue(sample) }
    }

    func append(_ bytes: Data, stride: Int) throws {
        guard !isCancelled else { throw CancellationError() }
        var picture: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &picture)
        guard status == kCVReturnSuccess, let picture else {
            throw MetalColorPipelineError.pixelBufferAllocationFailed(status)
        }
        CVPixelBufferLockBaseAddress(picture, [])
        guard let destination = CVPixelBufferGetBaseAddress(picture) else {
            CVPixelBufferUnlockBaseAddress(picture, [])
            throw ProResEncoderError.invalidOption("The BGRA picture has no writable storage.")
        }
        let rowStride = CVPixelBufferGetBytesPerRow(picture)
        bytes.withUnsafeBytes { source in
            for row in 0..<height {
                memcpy(destination.advanced(by: row * rowStride), source.baseAddress!.advanced(by: row * stride), width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(picture, [])
        let pts = CMTime(value: frames * frameDuration.value, timescale: frameDuration.timescale)
        let converted = try transform?.process(picture, pts: pts) ?? picture
        try mux.reserveFrame(codecError: { self.compression.callbackError })
        guard compression.submit(pixelBuffer: converted, pts: pts, duration: frameDuration) else {
            mux.releaseFrame()
            throw compression.callbackError ?? ProResEncoderError.invalidOption("VideoToolbox rejected a host frame.")
        }
        frames += 1
    }

    func finish() throws {
        guard frames > 0, !isCancelled else { throw ProResEncoderError.invalidOption("No completed video frames are available.") }
        try compression.completeFramesChecked()
        try mux.finish(expectedFrames: frames,
            endTime: CMTime(value: frames * frameDuration.value, timescale: frameDuration.timescale))
        committed = true
        compression.invalidate()
    }

    func requestCancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    private var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled || cancellationRequested()
    }

    deinit {
        compression.invalidate()
        if !committed {
            mux.cancel()
        }
    }
}


/// Only this queue touches the writer/input. At most eight submitted frames may
/// await muxing, so memory and queued work do not grow with sequence duration.
private final class BGRAStreamMuxer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.proresencoder.ama.mux", qos: .userInitiated)
    private let capacity = DispatchSemaphore(value: 8)
    private let failure = PipelineFailureBox()
    private let writer: AVAssetWriter
    private let transaction: DirectOutputTransaction
    private let cancellationRequested: () -> Bool
    private var input: AVAssetWriterInput?
    private var writtenFrames: Int64 = 0

    init(transaction: DirectOutputTransaction, cancellationRequested: @escaping () -> Bool) throws {
        self.transaction = transaction
        self.cancellationRequested = cancellationRequested
        writer = try AVAssetWriter(outputURL: transaction.workingURL,
            fileType: transaction.finalURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
    }

    func reserveFrame(codecError: () -> Error?) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while capacity.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellationRequested() { throw CancellationError() }
            if let error = failure.error ?? codecError() { throw error }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ProResEncoderError.invalidOption("VideoToolbox timed out delivering a host frame.")
            }
        }
        if let error = failure.error ?? codecError() { capacity.signal(); throw error }
        if cancellationRequested() { capacity.signal(); throw CancellationError() }
    }

    func releaseFrame() { capacity.signal() }

    func enqueue(_ sample: SendableSampleBuffer) {
        queue.async { [self] in
            defer { capacity.signal() }
            guard failure.error == nil else { return }
            do {
                try autoreleasepool { try append(sample.buf) }
            } catch { failure.store(error) }
        }
    }

    private func append(_ sample: CMSampleBuffer) throws {
        if cancellationRequested() { throw CancellationError() }
        if input == nil {
            let track = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
            track.expectsMediaDataInRealTime = false
            guard writer.canAdd(track) else { throw ProResEncoderError.invalidOption("The container rejected the encoded format.") }
            writer.add(track)
            guard writer.startWriting() else { throw writer.error ?? ProResEncoderError.invalidOption("The video writer did not start.") }
            writer.startSession(atSourceTime: .zero)
            input = track
        }
        guard let input else { throw ProResEncoderError.invalidOption("The video track is missing.") }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !input.isReadyForMoreMediaData {
            if cancellationRequested() { throw CancellationError() }
            guard writer.status == .writing else { throw writer.error ?? ProResEncoderError.invalidOption("The writer stopped accepting frames.") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProResEncoderError.invalidOption("The writer timed out accepting a frame.") }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard input.append(sample) else { throw writer.error ?? ProResEncoderError.invalidOption("The container rejected an encoded frame.") }
        writtenFrames += 1
    }

    func finish(expectedFrames: Int64, endTime: CMTime) throws {
        let complete = DispatchSemaphore(value: 0)
        queue.async { [self] in
            if failure.error != nil { complete.signal(); return }
            guard writtenFrames == expectedFrames else {
                failure.store(ProResEncoderError.invalidOption("Encoded frame coverage is incomplete: \(writtenFrames)/\(expectedFrames)."))
                complete.signal()
                return
            }
            input?.markAsFinished()
            writer.endSession(atSourceTime: endTime)
            writer.finishWriting { complete.signal() }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while complete.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellationRequested() { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProResEncoderError.invalidOption("The writer timed out finalizing.") }
        }
        if let error = failure.error { throw error }
        guard writer.status == .completed, !cancellationRequested() else {
            throw writer.error ?? ProResEncoderError.invalidOption("The writer did not complete.")
        }
        guard rename(transaction.workingURL.path, transaction.finalURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func cancel() {
        queue.async { [self] in
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: transaction.workingURL)
        }
    }
}
