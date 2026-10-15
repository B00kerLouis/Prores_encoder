import AVFoundation
import CoreMedia
import Foundation

/// Streams supported host pictures through the shared color and codec pipeline.
/// Unsupported option combinations retain the private ProRes carrier and public
/// file-encode fallback. A declared picture layout is fixed for each session.
private final class EncodeResult: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var error: Error?
}

@objc(ProResFrameStreamSession)
public final class ProResFrameStreamSession: NSObject, @unchecked Sendable {
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
    private var hdrEncoder: HDRFrameStreamEncoder?
    private var halfCarrier = false
    private var packedCarrier = false
    private var directEncoder: BGRAFrameStreamEncoder?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var carrierURL: URL?
    private var carrierColorPipeline: MetalColorPipeline?
    private var carrierEncodingGamutPipeline: MetalColorPipeline?
    private var carrierSourcePool: CVPixelBufferPool?
    private var carrierColorSpace: SourceColorSpace?
    private var carrierFinishingColor: ProResColorConversion?
    private enum Delivery { case bgra, rgbaHalf, packed422, proRes }
    private var delivery: Delivery?
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
        if halfCarrier || packedCarrier || (started && compressedCarrier) {
            return fail("The host changed picture delivery from ProRes to BGRA.")
        }
        if width <= 0 || height <= 0 || stride < width * 4 {
            return fail("The frame raster or stride is not valid.")
        }
        if frame.count < stride * height {
            return fail("The frame buffer is smaller than stride times height.")
        }
        guard delivery == nil || delivery == .bgra else {
            return fail("The host changed picture delivery format during export.")
        }
        delivery = .bgra
        do {
            if !started && directEncoder == nil && hdrEncoder == nil,
               advancedOptions["amaSharedColorPipeline"] as? Bool == true {
                let options = try makeEncodeOptions()
                if HDRFrameStreamEncoder.supports(options: options, format: format, sourceColor: try makeSourceColorSpace()) {
                    hdrEncoder = try HDRFrameStreamEncoder(outputURL: outputURL, width: width, height: height,
                        numerator: fpsNumerator, denominator: fpsDenominator, options: options,
                        sourceColor: try makeSourceColorSpace(), sourcePixelFormat: kCVPixelFormatType_32BGRA,
                        alreadyMapped: false, cancellationRequested: { [weak self] in self?.isCancellationRequested ?? true })
                }
            }
            if let hdrEncoder {
                try hdrEncoder.append(frame, stride: stride); frameIndex += 1; return true
            }
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
            guard let pixelBuffer = try makeCarrierPicture(from: frame, stride: stride) else {
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

    /// Private AMA mapped input. PQ must never be rounded back to eight bits.
    @objc public func appendRGBAHalfFrame(_ frame: Data, stride: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !compressedCarrier, directEncoder == nil,
              width > 0, width <= Int.max / 8, height > 0, stride <= Int.max / height, stride >= width * 8,
              frameIndex == 0 || halfCarrier || hdrEncoder != nil,
              frame.count >= stride * height, advancedOptions["amaMappedRGBAHalf"] as? Bool == true else {
            return fail("Invalid AMA PQ half-float frame or declaration.")
        }
        guard delivery == nil || delivery == .rgbaHalf else {
            return fail("The host changed picture delivery format during export.")
        }
        delivery = .rgbaHalf
        do {
            if !started && hdrEncoder == nil {
                let options = try makeEncodeOptions()
                if (advancedOptions["amaRenderedInputColor"] as? NSNumber)?.intValue == 1,
                   HDRFrameStreamEncoder.supports(options: options, format: format, sourceColor: try makeSourceColorSpace()) {
                    hdrEncoder = try HDRFrameStreamEncoder(outputURL: outputURL, width: width, height: height,
                        numerator: fpsNumerator, denominator: fpsDenominator, options: options,
                        cancellationRequested: { [weak self] in self?.isCancellationRequested ?? true })
                } else { halfCarrier = true }
            }
            if let hdrEncoder {
                try hdrEncoder.append(frame, stride: stride); frameIndex += 1; return true
            }
            guard halfCarrier else { return fail("The host changed frame delivery format.") }
            try startCarrierIfNeeded()
            guard let adaptor, let videoInput, waitForCarrierInput(videoInput),
                  let picture = try makeCarrierPicture(from: frame, stride: stride) else {
                return fail("The HDR carrier cannot accept a frame.")
            }
            guard adaptor.append(picture, withPresentationTime: CMTime(value: frameIndex * Int64(fpsDenominator), timescale: fpsNumerator)) else {
                return fail(writer?.error?.localizedDescription ?? "The HDR carrier rejected a frame.")
            }
            frameIndex += 1; return true
        } catch { return fail(error.localizedDescription) }
    }

    /// Host Cb/Y0/Cr/Y1 16-bit 10.6 video-range words. No RGB8 carrier or
    /// separate AMA color curve is introduced; only the shared CLI transform
    /// converts the rendered samples into the declared PQ master.
    @objc public func appendPacked422Frame(_ frame: Data, stride: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !compressedCarrier, directEncoder == nil, !halfCarrier,
              width > 0, width.isMultiple(of: 2), width <= Int.max / 4, height > 0,
              stride >= width * 4, stride <= Int.max / height, frame.count >= stride * height else {
            return fail("Invalid host packed 10.6 picture/stride.")
        }
        guard delivery == nil || delivery == .packed422 else {
            return fail("The host changed picture delivery format during export.")
        }
        delivery = .packed422
        do {
            if !started && hdrEncoder == nil {
                let options = try makeEncodeOptions()
                if HDRFrameStreamEncoder.supports(options: options, format: format, sourceColor: try makeSourceColorSpace()) {
                    hdrEncoder = try HDRFrameStreamEncoder(outputURL: outputURL, width: width, height: height,
                        numerator: fpsNumerator, denominator: fpsDenominator, options: options,
                        sourceColor: try makeSourceColorSpace(), sourcePixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                        packed422: true, alreadyMapped: false,
                        cancellationRequested: { [weak self] in self?.isCancellationRequested ?? true })
                } else { packedCarrier = true }
            }
            if let hdrEncoder { try hdrEncoder.append(frame, stride: stride); frameIndex += 1; return true }
            try startCarrierIfNeeded()
            guard let adaptor, let input = videoInput, waitForCarrierInput(input),
                  let picture = try makeCarrierPicture(from: frame, stride: stride) else { return fail("The packed carrier cannot accept a frame.") }
            guard adaptor.append(picture, withPresentationTime: CMTime(value: frameIndex * Int64(fpsDenominator), timescale: fpsNumerator)) else {
                return fail(writer?.error?.localizedDescription ?? "Packed carrier append failed.")
            }
            frameIndex += 1; return true
        } catch { return fail(error.localizedDescription) }
    }

    /// Media Composer can deliver a rendered sequence as encoded ProRes frames.
    /// Mux those frames without another encode, then use the existing encoder API.
    @objc public func appendProResFrame(_ frame: Data, sourceCodec: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            return fail("The frame stream is already closed.")
        }
        if halfCarrier || hdrEncoder != nil || (started && !compressedCarrier) {
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
        guard delivery == nil || delivery == .proRes else {
            return fail("The host changed picture delivery format during export.")
        }
        delivery = .proRes
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
        let hdr = hdrEncoder
        lock.unlock()
        if let hdr {
            do {
                try hdr.finish()
                lock.lock(); closed = true; hdrEncoder = nil; lock.unlock()
                return true
            } catch { return fail(error.localizedDescription) }
        }
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
        var localWriter = writer
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
        do {
            if let mastering = try (carrierColorSpace ?? makeSourceColorSpace())?.masteringDisplayColorVolume {
                // Only this owned AMA carrier is patched. Its PQ pixels already
                // have the declared peak; public file-encode behavior is intact.
                try patchProResStaticHDRSampleEntryBoxes(in: carrier,
                    masteringDisplayColorVolume: mastering, contentLightLevelInfo: nil,
                    inPlacePrivateCarrier: true)
            }
        } catch {
            cancel()
            return fail(error.localizedDescription)
        }
        // The carrier is closed and its color has been recorded. Release the
        // producing codec and Metal pools before the file pipeline allocates
        // its own decoder, conversion and SVT resources.
        lock.lock()
        writer = nil
        videoInput = nil
        adaptor = nil
        carrierColorPipeline = nil
        carrierEncodingGamutPipeline = nil
        carrierSourcePool = nil
        carrierColorSpace = nil
        carrierFinishingColor = nil
        lock.unlock()
        localWriter = nil
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
        if encodeError != nil, !isCancellationRequested,
           FileManager.default.fileExists(atPath: "/tmp/ProResAMA-enable-frame-trace") {
            print("[AMA carrier] Preserved failed private carrier for local diagnosis: \(carrier.path)")
        } else {
            try? FileManager.default.removeItem(at: carrier)
        }
        lock.lock()
        closed = true
        writer = nil
        videoInput = nil
        adaptor = nil
        carrierURL = nil
        carrierColorPipeline = nil
        carrierEncodingGamutPipeline = nil
        carrierSourcePool = nil
        carrierColorSpace = nil
        carrierFinishingColor = nil
        lock.unlock()
        if let encodeError {
            return fail(encodeError.localizedDescription)
        }
        return true
    }

    private func makeEncodeOptions() throws -> ProResEncodeOptions {
        let values = advancedOptions
        var options = ProResEncodeOptions(quality: quality)
        options.amaMediaTimeScale = fpsNumerator
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
        // The owned carrier holds an actual PQ master. Native profiles retain
        // their required same-peak identity request; HLG profiles retain a real
        // PQ-to-HLG conversion. Never apply the SDR inverse again at Finish.
        if carrierColorPipeline != nil {
            options.colorConversion = carrierFinishingColor
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
        hdrEncoder = nil
        directEncoder?.requestCancel()
        directEncoder = nil
        closed = true
        writer?.cancelWriting()
        let carrier = carrierURL
        writer = nil
        videoInput = nil
        adaptor = nil
        carrierURL = nil
        carrierColorPipeline = nil
        carrierEncodingGamutPipeline = nil
        carrierSourcePool = nil
        carrierColorSpace = nil
        carrierFinishingColor = nil
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
        let sourceFormat = packedCarrier ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            : (halfCarrier ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA)
        let sourceColor = try makeSourceColorSpace()
        let options = try makeEncodeOptions()
        // Every generated profile needs a real PQ analysis master. Preserve the
        // selected gamut here; compatible base layers use actual BT2020 pixels.
        // HLG is encoded from this master later, never relabeled as PQ for CMU.
        if advancedOptions["amaSharedColorPipeline"] as? Bool == true,
           let profile = options.dolbyVisionProfile.flatMap({ DolbyVisionHEVCProfile(argument: $0.rawValue) }),
           (quality == "hevc" && profile.isHEVCProfile || quality == "av1" && profile.isAV1Profile),
           options.includeGeneratedDolbyVisionMetadata, options.dolbyVisionXMLURL == nil,
           let request = try options.makeColorTransformRequest(), !request.hasLUT,
           request.outputOETF == (profile.usesHLGBaseLayer ? .hlg : .pq),
           (request.outputGamut.isRec2020Encoding || request.outputGamut == .p3D65),
           let sourceColor {
            let gamutText = request.outputGamut == .p3D65 ? "p3d65"
                : (request.outputGamut == .rec2020LimitedToP3D65 ? "rec2020lm" : "rec2020")
            let masterRequest = try ColorTransformRequest(gamut: gamutText, oetf: "pq", nits: String(request.targetNits))
            let resolved = try resolveColorTransform(request: masterRequest, sourceColorSpace: sourceColor)
            let pipeline = try MetalColorPipeline(transform: resolved, width: width, height: height,
                pixelFormat: sourceFormat, outputPixelFormat: kCVPixelFormatType_64RGBAHalf)
            var masterColor = Self.masterColor(resolved.outputColorSpace, gamut: request.outputGamut, peak: request.targetNits)
            if request.outputGamut == .p3D65 && !profile.usesNativeIPT {
                // P3 is the selected grading gamut, while HDR10/HLG compatible
                // base layers signal BT2020. Convert RGB primaries, not tags.
                let encodingRequest = try ColorTransformRequest(gamut: "rec2020", oetf: "pq", nits: String(request.targetNits))
                let encodingTransform = try resolveColorTransform(request: encodingRequest, sourceColorSpace: masterColor)
                carrierEncodingGamutPipeline = try MetalColorPipeline(transform: encodingTransform,
                    width: width, height: height, pixelFormat: kCVPixelFormatType_64RGBAHalf,
                    outputPixelFormat: kCVPixelFormatType_64RGBAHalf)
                masterColor = Self.masterColor(encodingTransform.outputColorSpace, gamut: .rec2020, peak: request.targetNits)
            }
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: sourceFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                throw MetalColorPipelineError.pixelBufferPoolFailed(status)
            }
            carrierColorPipeline = pipeline
            carrierSourcePool = pool
            carrierColorSpace = masterColor
            if profile.usesNativeIPT {
                carrierFinishingColor = ProResColorConversion(gamut: request.outputGamut == .p3D65 ? .p3D65 : .rec2020,
                    transferFunction: .pq, targetPeakNits: request.targetNits)
            } else if profile.usesHLGBaseLayer {
                carrierFinishingColor = ProResColorConversion(gamut: .rec2020,
                    transferFunction: .hlg, targetPeakNits: request.targetNits)
            }
            print("[AMA carrier] Profile \(profile.displayName): selected \(resolved.outputGamut.label) PQ RGBAHalf master, peak \(request.targetNits); compatible BT2020 conversion=\(carrierEncodingGamutPipeline != nil), final HLG=\(profile.usesHLGBaseLayer).")
        }
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: (halfCarrier || packedCarrier || carrierColorPipeline != nil) ? AVVideoCodecType(rawValue: "ap4x") : AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if let sourceColor = carrierColorSpace ?? sourceColor {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: sourceColor.primaries!,
                AVVideoTransferFunctionKey: sourceColor.transfer!,
                AVVideoYCbCrMatrixKey: sourceColor.matrix!
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // Keep each host frame exactly denominator ticks long. The default MOV
        // timebase can quantize 30000/1001 into alternating 1/30-second steps;
        // the file pipeline then overestimates frame coverage from min duration.
        input.mediaTimeScale = fpsNumerator
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: carrierColorPipeline == nil ? sourceFormat : kCVPixelFormatType_64RGBAHalf,
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
        input.mediaTimeScale = fpsNumerator
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

    private func makeCarrierPicture(from frame: Data, stride: Int) throws -> CVPixelBuffer? {
        guard let source = makePixelBuffer(from: frame, stride: stride) else { return nil }
        let pts = CMTime(value: frameIndex * Int64(fpsDenominator), timescale: fpsNumerator)
        let master = try carrierColorPipeline?.process(source, pts: pts) ?? source
        return try carrierEncodingGamutPipeline?.process(master, pts: pts) ?? master
    }

    /// Truthful ST2086 for an owned, already-transformed master. Without its
    /// actual peak an identity/PQ-to-HLG request assumes a 10000-nit source.
    private static func masterColor(_ color: SourceColorSpace, gamut: VideoGamut, peak: Float) -> SourceColorSpace {
        var payload = Data()
        let coordinates: [UInt16] = gamut == .rec2020
            ? [8500,39850,6550,2300,35400,14600,15635,16450]
            : [13250,34500,7500,3000,34000,16000,15635,16450]
        for value in coordinates { payload.append(UInt8(value >> 8)); payload.append(UInt8(value & 255)) }
        for value in [UInt32((peak * 10000).rounded()), UInt32(1)] {
            for shift in [24,16,8,0] { payload.append(UInt8((value >> shift) & 255)) }
        }
        return SourceColorSpace(primaries: color.primaries, transfer: color.transfer, matrix: color.matrix,
            masteringDisplayColorVolume: payload, contentLightLevelInfo: nil,
            mxfPrimaries: color.mxfPrimaries, mxfTransfer: color.mxfTransfer, mxfMatrix: color.mxfMatrix)
    }

    private func makePixelBuffer(from frame: Data, stride: Int) -> CVPixelBuffer? {
        guard let pool = carrierSourcePool ?? adaptor?.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if packedCarrier {
            let y = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt16.self)
            let uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt16.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / 2
            let uvs = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / 2
            frame.withUnsafeBytes { raw in
                for row in 0..<height {
                    let source = raw.baseAddress!.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                    for x in Swift.stride(from: 0, to: width, by: 2) {
                        uv[row * uvs + x] = source[x * 2]; y[row * ys + x] = source[x * 2 + 1]
                        uv[row * uvs + x + 1] = source[x * 2 + 2]; y[row * ys + x + 1] = source[x * 2 + 3]
                    }
                }
            }
            return pixelBuffer
        }
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
        // Private AMA wire coding is independent of the rendered RGB gamut.
        // Callers without this explicit packed override retain the gamut's
        // ordinary matrix, including all public file-encode defaults.
        var packedMatrix: Int?
        if let value = advancedOptions["amaPacked422Matrix"] {
            guard (advancedOptions["amaPacked422Input"] as? NSNumber)?.boolValue == true,
                  let number = value as? NSNumber,
                  number.doubleValue == 709 || number.doubleValue == 2020 else {
                throw ProResEncoderError.invalidOption("AMA packed matrix requires packed input and the exact value 709 or 2020.")
            }
            packedMatrix = number.intValue
        }
        let gamutValue = advancedOptions["inputColorGamut"]
        let transferValue = advancedOptions["inputColorTransfer"]
        if gamutValue == nil && transferValue == nil {
            guard packedMatrix == nil else {
                throw ProResEncoderError.invalidOption("AMA packed matrix requires a complete rendered color declaration.")
            }
            return nil
        }
        guard let gamutText = gamutValue as? String, let transferText = transferValue as? String else {
            throw ProResEncoderError.invalidOption("BGRA input color requires gamut and transfer together.")
        }
        let gamut = try VideoGamut(argument: gamutText)
        let transfer = try VideoOETF(argument: transferText)
        let masteringValue = advancedOptions["inputMasteringDisplayColorVolume"]
        let mastering = masteringValue as? Data
        if masteringValue != nil && (mastering?.count != 24 || transfer != .pq) {
            throw ProResEncoderError.invalidOption("AMA mapped HDR mastering data requires PQ and a 24-byte ST 2086 payload.")
        }
        return SourceColorSpace(primaries: gamut.colorPrimaries, transfer: transfer.transferFunction,
            matrix: packedMatrix.map { $0 == 709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String : kCVImageBufferYCbCrMatrix_ITU_R_2020 as String } ?? gamut.yCbCrMatrix,
            masteringDisplayColorVolume: mastering, contentLightLevelInfo: nil,
            mxfPrimaries: gamut.mxfPrimaries, mxfTransfer: transfer.mxfTransfer,
            mxfMatrix: (packedMatrix.map { $0 == 709 } ?? (gamut == .rec709)) ? MXFColorUL.matrixBT709 : MXFColorUL.matrixBT2020)
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
