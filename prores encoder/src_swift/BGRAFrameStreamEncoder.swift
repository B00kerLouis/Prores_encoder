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
/// await muxing for ordinary BGRA; the live B-frame path uses 64 slots for its
/// codec delay. Neither queue grows with sequence duration.
private final class BGRAStreamMuxer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.proresencoder.ama.mux", qos: .userInitiated)
    private let capacity: DispatchSemaphore
    private let timeScale: Int32
    private let failure = PipelineFailureBox()
    private let writer: AVAssetWriter
    private let transaction: DirectOutputTransaction
    private let cancellationRequested: () -> Bool
    private var input: AVAssetWriterInput?
    private var writtenFrames: Int64 = 0

    init(transaction: DirectOutputTransaction, cancellationRequested: @escaping () -> Bool,
         timeScale: Int32 = 600, capacity: Int = 8) throws {
        self.timeScale = timeScale
        self.capacity = DispatchSemaphore(value: capacity)
        self.transaction = transaction
        self.cancellationRequested = cancellationRequested
        writer = try AVAssetWriter(outputURL: transaction.workingURL,
            fileType: transaction.finalURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        writer.movieTimeScale = timeScale
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
            track.mediaTimeScale = timeScale
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

/// AMA-only generated Profile 5 path: RGB stays high precision until the native
/// transform, CMU measures each submitted picture, and HEVC runs during host
/// rendering. Finishing adds metadata to compressed samples without decoding.
final class HDRFrameStreamEncoder: @unchecked Sendable {
    private let pool: CVPixelBufferPool
    private let compression: ProResSession
    private let native: NativeDolbyVisionColorPipeline?
    private let color: MetalColorPipeline?
    private let sourceFormat: OSType
    private let packed422: Bool
    private let analyzer: CMUMetalAnalyzer
    private let mux: BGRAStreamMuxer
    private let outputURL: URL
    private let spoolURL: URL
    private let width: Int, height: Int
    private let rate: FramerateInfo
    private let options: ProResEncodeOptions
    private let cancellationRequested: @Sendable () -> Bool
    // RPC owns submitted count/pool; this serial queue owns stats and GPU work.
    // Four owned RGB buffers let host rendering overlap worker processing. No
    // shared-memory frame survives the synchronous copy in append().
    private let processing = DispatchQueue(label: "com.proresencoder.ama.hdr", qos: .userInitiated)
    private let inputCapacity = DispatchSemaphore(value: 4)
    private let failure = PipelineFailureBox()
    private var submitted: Int64 = 0
    private var stats: [CMUFrameStats] = []
    private var committed = false

    static func supports(options: ProResEncodeOptions, format: ProResOutputFormat, sourceColor: SourceColorSpace? = nil) -> Bool {
        let proRes = ["proxy", "422lt", "422", "422hq", "4444", "4444xq"].contains(options.quality)
        let p5 = options.quality == "hevc" && options.dolbyVisionProfile?.rawValue == "5"
            && options.includeGeneratedDolbyVisionMetadata && options.cmuMasteringNits != nil
            && options.multiPass != true
        let pq = options.colorConversion?.transferFunction.rawValue == "pq"
            && ["rec2020", "rec2020lm"].contains(options.colorConversion?.gamut.rawValue ?? "")
        // Live analysis and authoring use a Rec.2020 PQ master. Preserve the
        // file pipeline for unconverted P3 rather than mislabel its RGB stats.
        let native2020PQ = sourceColor?.transfer == VideoOETF.pq.transferFunction
            && sourceColor?.primaries == VideoGamut.rec2020.colorPrimaries
        return (proRes && format == .mov || p5 && (format == .mov || format == .mp4))
            && (pq || (options.colorConversion == nil && native2020PQ))
            && options.dolbyVisionXMLURL == nil && options.extraAudioURL == nil
            && options.lutColorConversion == nil && !options.outputVideoRaw && options.aafMode == .none
    }

    init(outputURL: URL, width: Int, height: Int, numerator: Int32, denominator: Int32,
         options: ProResEncodeOptions, sourceColor: SourceColorSpace? = nil,
         sourcePixelFormat: OSType = kCVPixelFormatType_64RGBAHalf, packed422: Bool = false,
         alreadyMapped: Bool = true, cancellationRequested: @escaping @Sendable () -> Bool) throws {
        self.sourceFormat = sourcePixelFormat; self.packed422 = packed422
        self.outputURL = outputURL; self.width = width; self.height = height
        self.options = options; self.cancellationRequested = cancellationRequested
        rate = FramerateInfo(numerator: Int(numerator), denominator: Int(denominator), isDropFrame: false)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        spoolURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".ama-live-\(UUID().uuidString).\(outputURL.pathExtension)")
        let codec = proResCodecType(options.quality)
        let p5 = codec == kCMVideoCodecType_HEVC
        let request: ColorTransformRequest?
        let outputColor: SourceColorSpace
        if alreadyMapped {
            request = nil
            outputColor = sourceColor ?? SourceColorSpace(primaries: VideoGamut.rec2020.colorPrimaries,
                transfer: VideoOETF.pq.transferFunction, matrix: VideoGamut.rec2020.yCbCrMatrix,
                masteringDisplayColorVolume: nil, contentLightLevelInfo: nil,
                mxfPrimaries: nil, mxfTransfer: nil, mxfMatrix: nil)
        } else {
            guard let sourceColor else { throw ColorTransformError.unsupportedSourcePrimaries(nil) }
            request = try options.makeColorTransformRequest()
            if let request {
                let resolved = try resolveColorTransform(request: request, sourceColorSpace: sourceColor)
                guard resolved.outputOETF == .pq else { throw ProResEncoderError.invalidOption("Live HDR requires PQ output.") }
                outputColor = resolved.outputColorSpace
            } else {
                let input = try resolveSourceColorProfile(from: sourceColor)
                guard input.oetf == .pq else { throw ProResEncoderError.invalidOption("Declare a PQ transform for live SDR-to-HDR conversion.") }
                outputColor = sourceColor
            }
        }
        if let sourceColor, let request {
            color = try MetalColorPipeline(transform: resolveColorTransform(request: request, sourceColorSpace: sourceColor),
                width: width, height: height, pixelFormat: sourcePixelFormat, outputPixelFormat: kCVPixelFormatType_64RGBAHalf)
        } else if sourcePixelFormat != kCVPixelFormatType_64RGBAHalf {
            guard let sourceColor else { throw ColorTransformError.unsupportedSourcePrimaries(nil) }
            let profile = try resolveSourceColorProfile(from: sourceColor)
            let identity = try ColorTransformRequest(gamut: ["rec709", "rec2020", "p3d65", "rec2020lm"][Int(profile.gamut.rawValue)], oetf: "pq", nits: String(profile.peakNits))
            color = try MetalColorPipeline(transform: ResolvedColorTransform(input: profile, request: identity),
                width: width, height: height, pixelFormat: sourcePixelFormat, outputPixelFormat: kCVPixelFormatType_64RGBAHalf)
        } else { color = nil }
        let outputGamut = outputColor.primaries == VideoGamut.p3D65.colorPrimaries ? VideoGamut.p3D65 : .rec2020
        native = p5 ? try NativeDolbyVisionColorPipeline(width: width, height: height, inputGamut: outputGamut,
            inputPixelFormat: kCVPixelFormatType_64RGBAHalf) : nil
        analyzer = try CMUMetalAnalyzer()
        compression = try ProResSession(width: width, height: height, codecType: codec,
            fpsHint: max(1, Int(rate.fps.rounded())), colorSpace: p5 ? nil : outputColor,
            hevcOptions: p5 ? HEVCEncodeOptions(bitrateMbps: options.bitrateMbps ?? 50, dvProfile: .profile5,
                bFrames: options.bFrames, multiPass: false) : nil,
            sourcePixelFormat: p5 ? NativeDolbyVisionColorPipeline.outputPixelFormat : kCVPixelFormatType_64RGBAHalf,
            maximumFrameDelay: p5 ? 8 : nil)
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: sourcePixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary, &newPool)
        guard status == kCVReturnSuccess, let newPool else { throw MetalColorPipelineError.pixelBufferPoolFailed(status) }
        pool = newPool
        mux = try BGRAStreamMuxer(transaction: DirectOutputTransaction(finalURL: spoolURL),
            cancellationRequested: cancellationRequested, timeScale: numerator, capacity: 64)
        compression.setEncodedSampleHandler { [mux] sample in mux.enqueue(sample) }
        print("[AMA live] Shared CLI color pipeline; source format \(cmuFourCC(sourcePixelFormat)), packed422=\(packed422), mapped=\(alreadyMapped); live \(options.quality), CMU on the same PQ RGB pictures.")
    }

    func append(_ data: Data, stride: Int) throws {
        guard !cancellationRequested() else { throw CancellationError() }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while inputCapacity.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellationRequested() { throw CancellationError() }
            if let error = failure.error { throw error }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ProResEncoderError.invalidOption("AMA live RGB processing timed out waiting for queue capacity.")
            }
        }
        var enqueued = false
        defer { if !enqueued { inputCapacity.signal() } }
        if let error = failure.error { throw error }
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let picture = created else { throw MetalColorPipelineError.pixelBufferAllocationFailed(status) }
        CVPixelBufferLockBaseAddress(picture, [])
        if packed422 {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(picture, 0) / 2
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(picture, 1) / 2
            let y = CVPixelBufferGetBaseAddressOfPlane(picture, 0)!.assumingMemoryBound(to: UInt16.self)
            let uv = CVPixelBufferGetBaseAddressOfPlane(picture, 1)!.assumingMemoryBound(to: UInt16.self)
            data.withUnsafeBytes { raw in
                for row in 0..<height {
                    let source = raw.baseAddress!.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                    for x in Swift.stride(from: 0, to: width, by: 2) {
                        uv[row * uvStride + x] = source[x * 2]
                        y[row * yStride + x] = source[x * 2 + 1]
                        uv[row * uvStride + x + 1] = source[x * 2 + 2]
                        y[row * yStride + x + 1] = source[x * 2 + 3]
                    }
                }
            }
        } else {
            guard let address = CVPixelBufferGetBaseAddress(picture) else { CVPixelBufferUnlockBaseAddress(picture, []); throw MetalColorPipelineError.commandEncodingFailed }
            let destinationStride = CVPixelBufferGetBytesPerRow(picture)
            let rowBytes = width * (sourceFormat == kCVPixelFormatType_64RGBAHalf ? 8 : 4)
            data.withUnsafeBytes { raw in
                for row in 0..<height { memcpy(address.advanced(by: row * destinationStride), raw.baseAddress!.advanced(by: row * stride), rowBytes) }
            }
        }
        CVPixelBufferUnlockBaseAddress(picture, [])
        let index = submitted
        let pts = CMTime(value: index * Int64(rate.denominator), timescale: Int32(rate.numerator))
        let owned = SendablePixelBuffer(buf: picture)
        processing.async { [self] in
            defer { inputCapacity.signal() }
            guard failure.error == nil else { return }
            do {
                try autoreleasepool {
                    if cancellationRequested() { throw CancellationError() }
                    let mapped = try color?.process(owned.buf, pts: pts) ?? owned.buf
                    let measured = try analyzer.analyzeRGBFrame(mapped, frameIndex: index, pts: pts)
                    let encodedPicture = try native?.process(mapped, pts: pts) ?? mapped
                    try mux.reserveFrame(codecError: { self.compression.callbackError })
                    guard compression.submit(pixelBuffer: encodedPicture, pts: pts,
                        duration: CMTime(value: Int64(rate.denominator), timescale: Int32(rate.numerator))) else {
                        mux.releaseFrame(); throw compression.callbackError ?? MetalColorPipelineError.commandEncodingFailed
                    }
                    stats.append(measured)
                }
            } catch { failure.store(error) }
        }
        submitted += 1
        enqueued = true
    }

    func finish() throws {
        guard submitted > 0, !cancellationRequested() else { throw CancellationError() }
        let drained = DispatchSemaphore(value: 0)
        processing.async { drained.signal() }
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while drained.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellationRequested() { throw CancellationError() }
            if let error = failure.error { throw error }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ProResEncoderError.invalidOption("AMA live RGB processing timed out draining its queue.")
            }
        }
        if let error = failure.error { throw error }
        guard stats.count == submitted else { throw ProResEncoderError.invalidOption("AMA live analysis frame coverage is incomplete.") }
        try compression.completeFramesChecked()
        try mux.finish(expectedFrames: Int64(stats.count), endTime: CMTime(value: Int64(stats.count * rate.denominator), timescale: Int32(rate.numerator)))
        compression.invalidate()
        let box = EncodeResultForHDRStream()
        let frames = stats, file = spoolURL, final = outputURL, rate = rate, settings = options
        let cancelled = cancellationRequested
        let rasterWidth = width, rasterHeight = height
        Task.detached {
            do { try await finalizeAMAColorStream(spoolURL: file, outputURL: final,
                width: rasterWidth, height: rasterHeight, rate: rate, options: settings,
                frames: frames, cancellationRequested: cancelled) }
            catch { box.error = error }
            box.complete.signal()
        }
        box.complete.wait()
        if let error = box.error { throw error }
        committed = true
    }

    deinit {
        compression.invalidate()
        if !committed { mux.cancel() }
        try? FileManager.default.removeItem(at: spoolURL)
    }
}
private final class EncodeResultForHDRStream: @unchecked Sendable {
    let complete = DispatchSemaphore(value: 0)
    var error: Error?
}
