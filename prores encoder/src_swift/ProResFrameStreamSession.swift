import AVFoundation
import CoreMedia
import Foundation

/// Feeds host frames into the existing `ProResEncoder.encode` file pipeline.
///
/// Incoming pictures are stored as a temporary ProRes 4444 movie, then the unchanged
/// public encode API writes the requested codec and container. Existing encode
/// functions are not modified. H.264 is never given Dolby Vision options. HEVC and
/// AV1 receive Dolby Vision only when `includeDolbyVision` is set by the caller.
private final class EncodeResult: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var error: Error?
}

@objc(ProResFrameStreamSession)
public final class ProResFrameStreamSession: NSObject {
    private let outputURL: URL
    private let width: Int
    private let height: Int
    private let fpsNumerator: Int32
    private let fpsDenominator: Int32
    private let quality: String
    private let format: ProResOutputFormat
    private let bitrateMbps: Double
    private let includeDolbyVision: Bool
    private let advancedOptions: NSDictionary
    private let lock = NSLock()
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var directEncoder: BGRAFrameStreamEncoder?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var carrierURL: URL?
    private var frameIndex: Int64 = 0
    private var started = false
    private var compressedCarrier = false
    private var compressedSourceCodec: String?
    private var closed = false
    private var failure: String?

    @objc public private(set) var lastErrorMessage: String = ""

    @objc public convenience init(
        outputURL: URL,
        width: Int,
        height: Int,
        fpsNumerator: Int,
        fpsDenominator: Int,
        quality: String,
        containerExtension: String,
        bitrateMbps: Double,
        includeDolbyVision: Bool
    ) {
        self.init(
            outputURL: outputURL,
            width: width,
            height: height,
            fpsNumerator: fpsNumerator,
            fpsDenominator: fpsDenominator,
            quality: quality,
            containerExtension: containerExtension,
            bitrateMbps: bitrateMbps,
            includeDolbyVision: includeDolbyVision,
            advancedOptions: NSDictionary()
        )
    }

    /// Objective-C boundary for the existing public encoder options. Keys are
    /// validated in `makeEncodeOptions()` before a host export is committed.
    @objc public init(
        outputURL: URL,
        width: Int,
        height: Int,
        fpsNumerator: Int,
        fpsDenominator: Int,
        quality: String,
        containerExtension: String,
        bitrateMbps: Double,
        includeDolbyVision: Bool,
        advancedOptions: NSDictionary
    ) {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.fpsNumerator = Int32(max(fpsNumerator, 1))
        self.fpsDenominator = Int32(max(fpsDenominator, 1))
        self.quality = quality
        switch containerExtension.lowercased() {
        case "mp4":
            self.format = .mp4
        case "op1a", "mxf":
            self.format = .op1a
        case "opatom":
            self.format = .opatom
        default:
            self.format = .mov
        }
        self.bitrateMbps = bitrateMbps
        self.includeDolbyVision = includeDolbyVision && quality.lowercased() != "h264"
        self.advancedOptions = advancedOptions.copy() as? NSDictionary ?? NSDictionary()
        super.init()
    }

    @objc public func appendBGRAFrame(_ frame: Data, stride: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            return fail("The frame stream is already closed.")
        }
        if started && compressedCarrier {
            return fail("The host changed picture delivery from ProRes to BGRA.")
        }
        if width <= 0 || height <= 0 || stride < width * 4 {
            return fail("The frame raster or stride is not valid.")
        }
        if frame.count < stride * height {
            return fail("The frame buffer is smaller than stride times height.")
        }
        do {
            if !started && directEncoder == nil && !includeDolbyVision {
                let options = try makeEncodeOptions()
                if BGRAFrameStreamEncoder.supports(options: options, format: format) {
                    directEncoder = try BGRAFrameStreamEncoder(outputURL: outputURL,
                        width: width, height: height, numerator: fpsNumerator, denominator: fpsDenominator,
                        options: options, sourceColor: try makeSourceColorSpace(),
                        cancellationRequested: { [weak self] in self?.isCancellationRequested ?? true })
                }
            }
            if let directEncoder {
                try directEncoder.append(frame, stride: stride)
                frameIndex += 1
                return true
            }
            try startCarrierIfNeeded()
            guard let adaptor, let videoInput else {
                return fail("The frame carrier is not open.")
            }
            guard waitForCarrierInput(videoInput) else { return false }
            guard let pixelBuffer = makePixelBuffer(from: frame, stride: stride) else {
                return fail("A picture buffer could not be allocated.")
            }
            let time = CMTime(value: frameIndex * Int64(fpsDenominator), timescale: fpsNumerator)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                return fail(writer?.error?.localizedDescription ?? "The carrier rejected a frame.")
            }
            frameIndex += 1
            return true
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// Media Composer can deliver a rendered sequence as encoded ProRes frames.
    /// Mux those frames without another encode, then use the existing encoder API.
    @objc public func appendProResFrame(_ frame: Data, sourceCodec: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            return fail("The frame stream is already closed.")
        }
        if started && !compressedCarrier {
            return fail("The host changed picture delivery from BGRA to ProRes.")
        }
        guard frame.count >= 8,
              frame[4] == 0x69, frame[5] == 0x63, frame[6] == 0x70, frame[7] == 0x66 else {
            return fail("The host did not deliver a ProRes picture frame.")
        }
        let declaredLength = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard declaredLength == frame.count else {
            return fail("The host ProRes frame length does not match its header.")
        }
        do {
            try startCompressedCarrierIfNeeded(sourceCodec: sourceCodec)
            guard let videoInput else {
                return fail("The ProRes carrier is not open.")
            }
            guard waitForCarrierInput(videoInput) else { return false }
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: frame.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: frame.count,
                flags: 0,
                blockBufferOut: &block)
            guard status == noErr, let block else {
                return fail("A ProRes sample buffer could not be allocated (\(status)).")
            }
            status = frame.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: frame.count)
            }
            guard status == noErr else {
                return fail("The ProRes sample could not be copied (\(status)).")
            }
            var sample: CMSampleBuffer?
            var sampleSize = frame.count
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: Int64(fpsDenominator), timescale: fpsNumerator),
                presentationTimeStamp: CMTime(value: frameIndex * Int64(fpsDenominator), timescale: fpsNumerator),
                decodeTimeStamp: .invalid)
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: videoInput.sourceFormatHint,
                sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
            guard status == noErr, let sample else {
                return fail("The ProRes sample could not be described (\(status)).")
            }
            guard videoInput.append(sample) else {
                return fail(writer?.error?.localizedDescription ?? "The carrier rejected a ProRes frame.")
            }
            frameIndex += 1
            return true
        } catch {
            return fail(error.localizedDescription)
        }
    }

    @objc public func finish() -> Bool {
        lock.lock()
        let frames = frameIndex
        let carrier = carrierURL
        let direct = directEncoder
        lock.unlock()
        if let direct {
            do {
                try direct.finish()
                lock.lock()
                closed = true
                directEncoder = nil
                lock.unlock()
                return true
            } catch {
                return fail(error.localizedDescription)
            }
        }
        if frames == 0 {
            return fail("No video frames were received.")
        }
        let options: ProResEncodeOptions
        do {
            options = try makeEncodeOptions()
        } catch {
            cancel()
            return fail(error.localizedDescription)
        }
        lock.lock()
        videoInput?.markAsFinished()
        let localWriter = writer
        lock.unlock()
        let group = DispatchGroup()
        group.enter()
        localWriter?.finishWriting {
            group.leave()
        }
        let drainDeadline = ProcessInfo.processInfo.systemUptime + 60
        while group.wait(timeout: .now() + 0.1) == .timedOut {
            if isCancellationRequested || ProcessInfo.processInfo.systemUptime >= drainDeadline {
                localWriter?.cancelWriting()
                return fail(isCancellationRequested ? "Export cancelled." : "The frame carrier timed out finalizing.")
            }
        }
        guard localWriter?.status == .completed else {
            return fail(localWriter?.error?.localizedDescription ?? "The frame carrier did not complete.")
        }
        if let writerError = localWriter?.error {
            return fail(writerError.localizedDescription)
        }
        guard let carrier else {
            return fail("The frame carrier is missing.")
        }
        let deliveredURL = outputURL
        let deliveredFormat = format
        let result = EncodeResult()
        Task.detached {
            do {
                _ = try await ProResEncoder().encode(
                    inputURL: carrier,
                    outputURL: deliveredURL,
                    format: deliveredFormat,
                    options: options
                )
            } catch {
                result.error = error
            }
            result.semaphore.signal()
        }
        result.semaphore.wait()
        let encodeError = result.error
        try? FileManager.default.removeItem(at: carrier)
        lock.lock()
        closed = true
        writer = nil
        videoInput = nil
        adaptor = nil
        carrierURL = nil
        lock.unlock()
        if let encodeError {
            return fail(encodeError.localizedDescription)
        }
        return true
    }

    private func makeEncodeOptions() throws -> ProResEncodeOptions {
        let values = advancedOptions
        var options = ProResEncodeOptions(quality: quality)
        if quality == "h264" || quality == "hevc" || quality == "av1" {
            options.bitrateMbps = bitrateMbps > 0 ? bitrateMbps : 50
        }

        func string(_ key: String) throws -> String? {
            guard let value = values[key] else { return nil }
            guard let text = value as? String else {
                throw ProResEncoderError.invalidOption("Invalid AMA option type: \(key).")
            }
            return text.isEmpty ? nil : text
        }
        func number(_ key: String) throws -> NSNumber? {
            guard let value = values[key] else { return nil }
            guard let result = value as? NSNumber else {
                throw ProResEncoderError.invalidOption("Invalid AMA option type: \(key).")
            }
            return result
        }
        func fileURL(_ key: String) throws -> URL? {
            guard let path = try string(key) else { return nil }
            return URL(fileURLWithPath: path)
        }

        options.extraAudioURL = try fileURL("extraAudioPath")
        options.replaceSourceAudio = try number("replaceSourceAudio")?.boolValue ?? false
        options.deleteSourceAudio = try number("deleteSourceAudio")?.boolValue ?? false
        options.forcedOutputStartTimecode = try string("forcedStartTimecode")
        options.dolbyVisionXMLURL = try fileURL("dolbyVisionXMLPath")
        if let profile = try string("dolbyVisionProfile") {
            guard let value = ProResDolbyVisionProfile(rawValue: profile) else {
                throw ProResEncoderError.invalidOption("Unsupported Dolby Vision profile: \(profile).")
            }
            options.dolbyVisionProfile = value
        }
        if let channels = try number("audioChannelsPerMXFFile") {
            options.audioChannelsPerMXFFile = channels.intValue
        }
        if let masteringNits = try number("cmuMasteringNits") {
            options.cmuMasteringNits = masteringNits.floatValue
        }
        options.includeGeneratedDolbyVisionMetadata = try number("includeGeneratedDolbyVisionMetadata")?.boolValue ?? false
        options.useDolbyVisionCodecTag = try number("useDolbyVisionCodecTag")?.boolValue ?? false
        options.outputVideoRaw = try number("outputVideoRaw")?.boolValue ?? false
        if let multiPass = try number("multiPass") {
            options.multiPass = multiPass.boolValue
        }
        if let bFrames = try number("bFrames") {
            options.bFrames = bFrames.boolValue
        }
        if let aafMode = try string("aafMode") {
            switch aafMode {
            case "none": options.aafMode = .none
            case "sequence": options.aafMode = .sequence
            case "perClip": options.aafMode = .perClip
            default: throw ProResEncoderError.invalidOption("Unsupported AAF mode: \(aafMode).")
            }
        }

        if let colorMode = try string("colorMode"), colorMode != "off" {
            guard let gamutString = try string("colorGamut"),
                  let gamut = ProResColorGamut(rawValue: gamutString),
                  let transferString = try string("colorTransfer"),
                  let transfer = ProResTransferFunction(rawValue: transferString),
                  let peak = try number("colorPeakNits")?.floatValue else {
                throw ProResEncoderError.invalidOption("Color conversion requires gamut, transfer, and peak nits.")
            }
            if colorMode == "direct" {
                options.colorConversion = ProResColorConversion(
                    gamut: gamut, transferFunction: transfer, targetPeakNits: peak)
            } else if colorMode == "lut" {
                guard let lutURL = try fileURL("lutPath") else {
                    throw ProResEncoderError.invalidOption("LUT conversion requires a LUT file path.")
                }
                options.lutColorConversion = ProResLUTColorConversion(
                    lutURL: lutURL, gamut: gamut, transferFunction: transfer, targetPeakNits: peak)
            } else {
                throw ProResEncoderError.invalidOption("Unsupported color mode: \(colorMode).")
            }
        }
        if includeDolbyVision && options.dolbyVisionXMLURL == nil && !options.includeGeneratedDolbyVisionMetadata {
            throw ProResEncoderError.invalidOption(
                "Dolby Vision requires an external XML file or generated CMU metadata settings.")
        }
        // The host already encoded this exact ProRes profile. A plain MOV
        // export only needs the framework's remux path, which avoids a second
        // full-length video encode after Media Composer finishes rendering.
        if compressedCarrier,
           format == .mov,
           quality.lowercased() == compressedSourceCodec,
           options.extraAudioURL == nil,
           options.forcedOutputStartTimecode == nil,
           options.dolbyVisionXMLURL == nil,
           options.colorConversion == nil,
           options.lutColorConversion == nil,
           options.cmuMasteringNits == nil,
           !options.includeGeneratedDolbyVisionMetadata,
           !options.outputVideoRaw,
           !options.useDolbyVisionCodecTag,
           options.aafMode == .none {
            options.quality = "pass"
        }
        return options
    }

    @objc public func cancel() {
        // Signal without taking the append lock; otherwise a blocked writer
        // prevents CancelWrite from waking the frame submission loop.
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        lock.lock()
        directEncoder?.requestCancel()
        directEncoder = nil
        closed = true
        writer?.cancelWriting()
        let carrier = carrierURL
        writer = nil
        videoInput = nil
        adaptor = nil
        carrierURL = nil
        lock.unlock()
        if let carrier {
            try? FileManager.default.removeItem(at: carrier)
        }
    }

    private func startCarrierIfNeeded() throws {
        if started {
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prores-ama-carrier-\(UUID().uuidString).mov")
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if let sourceColor = try makeSourceColorSpace() {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: sourceColor.primaries!,
                AVVideoTransferFunctionKey: sourceColor.transfer!,
                AVVideoYCbCrMatrixKey: sourceColor.matrix!
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard assetWriter.canAdd(input) else {
            throw ProResEncoderError.invalidOption("The frame carrier cannot store video.")
        }
        assetWriter.add(input)
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? ProResEncoderError.invalidOption("The frame carrier did not start.")
        }
        assetWriter.startSession(atSourceTime: .zero)
        writer = assetWriter
        videoInput = input
        adaptor = pixelAdaptor
        carrierURL = url
        started = true
    }

    private func startCompressedCarrierIfNeeded(sourceCodec: String) throws {
        if started { return }
        let codecType: CMVideoCodecType
        switch sourceCodec.lowercased() {
        case "proxy": codecType = kCMVideoCodecType_AppleProRes422Proxy
        case "422lt": codecType = kCMVideoCodecType_AppleProRes422LT
        case "422": codecType = kCMVideoCodecType_AppleProRes422
        case "422hq": codecType = kCMVideoCodecType_AppleProRes422HQ
        case "4444": codecType = kCMVideoCodecType_AppleProRes4444
        case "4444xq": codecType = kCMVideoCodecType_AppleProRes4444XQ
        default: throw ProResEncoderError.invalidOption("Unsupported host ProRes intermediate: \(sourceCodec).")
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codecType,
            width: Int32(width), height: Int32(height),
            extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw ProResEncoderError.invalidOption("The host ProRes format could not be described (\(status)).")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prores-ama-carrier-\(UUID().uuidString).mov")
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        guard assetWriter.canAdd(input) else {
            throw ProResEncoderError.invalidOption("The carrier cannot store host ProRes frames.")
        }
        assetWriter.add(input)
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? ProResEncoderError.invalidOption("The carrier did not start.")
        }
        assetWriter.startSession(atSourceTime: .zero)
        writer = assetWriter
        videoInput = input
        carrierURL = url
        compressedCarrier = true
        compressedSourceCodec = sourceCodec.lowercased()
        started = true
    }

    private func makePixelBuffer(from frame: Data, stride: Int) -> CVPixelBuffer? {
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        frame.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return }
            let rowBytes = min(destinationStride, stride)
            for row in 0..<height {
                memcpy(
                    destination.advanced(by: row * destinationStride),
                    source.advanced(by: row * stride),
                    rowBytes
                )
            }
        }
        return pixelBuffer
    }

    /// Host color remains unknown unless the caller supplies a complete,
    /// verified render-output declaration. BGRA memory layout implies no gamut.
    private func makeSourceColorSpace() throws -> SourceColorSpace? {
        let gamutValue = advancedOptions["inputColorGamut"]
        let transferValue = advancedOptions["inputColorTransfer"]
        if gamutValue == nil && transferValue == nil { return nil }
        guard let gamutText = gamutValue as? String, let transferText = transferValue as? String else {
            throw ProResEncoderError.invalidOption("BGRA input color requires gamut and transfer together.")
        }
        let gamut = try VideoGamut(argument: gamutText)
        let transfer = try VideoOETF(argument: transferText)
        return SourceColorSpace(primaries: gamut.colorPrimaries, transfer: transfer.transferFunction,
            matrix: gamut.yCbCrMatrix, masteringDisplayColorVolume: nil, contentLightLevelInfo: nil,
            mxfPrimaries: gamut.mxfPrimaries, mxfTransfer: transfer.mxfTransfer,
            mxfMatrix: gamut == .rec709 ? MXFColorUL.matrixBT709 : MXFColorUL.matrixBT2020)
    }

    private var isCancellationRequested: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    private func waitForCarrierInput(_ input: AVAssetWriterInput) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !input.isReadyForMoreMediaData {
            if isCancellationRequested { return fail("Export cancelled.") }
            guard writer?.status == .writing else {
                return fail(writer?.error?.localizedDescription ?? "The carrier stopped accepting frames.")
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return fail("The frame carrier timed out accepting a frame.")
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return !isCancellationRequested
    }

    private func fail(_ message: String) -> Bool {
        failure = message
        lastErrorMessage = message
        closed = true
        return false
    }
}
