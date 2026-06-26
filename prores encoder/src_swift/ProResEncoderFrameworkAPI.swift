import Foundation
@preconcurrency import AVFoundation
import Metal
import VideoToolbox

public enum ProResOutputFormat: String, Sendable {
    case mov
    case op1a
    case opatom
}

public enum ProResAAFMode: Sendable {
    case none
    case sequence
    case perClip
}

public enum ProResTimelineFormat: String, Sendable {
    case aaf
    case xml
}

public enum ProResColorGamut: String, Sendable {
    case rec709
    case rec2020
    case rec2020LimitedToP3D65 = "rec2020lm"
    case p3D65 = "p3d65"
}

public enum ProResTransferFunction: String, Sendable {
    case gamma24 = "gamma2.4"
    case gamma26 = "gamma2.6"
    case pq
    case hlg
}

public enum ProResDolbyVisionProfile: String, Sendable {
    case profile76 = "76"
    case profile81 = "81"
    case profile84 = "84"
    case profile101 = "101"
    case profile104 = "104"
}

public struct ProResColorConversion: Sendable {
    public var gamut: ProResColorGamut
    public var transferFunction: ProResTransferFunction
    public var targetPeakNits: Float

    public init(
        gamut: ProResColorGamut,
        transferFunction: ProResTransferFunction,
        targetPeakNits: Float
    ) {
        self.gamut = gamut
        self.transferFunction = transferFunction
        self.targetPeakNits = targetPeakNits
    }

    fileprivate func makeRequest() throws -> ColorTransformRequest {
        try ColorTransformRequest(
            gamut: gamut.rawValue,
            oetf: transferFunction.rawValue,
            nits: String(targetPeakNits)
        )
    }
}

public struct ProResEncodeOptions: Sendable {
    public var quality: String
    public var extraAudioURL: URL?
    public var replaceSourceAudio: Bool
    public var deleteSourceAudio: Bool
    public var forcedOutputStartTimecode: String?
    public var dolbyVisionXMLURL: URL?
    public var bitrateMbps: Double?
    public var dolbyVisionProfile: ProResDolbyVisionProfile?
    public var audioChannelsPerMXFFile: Int
    public var colorConversion: ProResColorConversion?
    public var cmuMasteringNits: Float?
    public var includeGeneratedDolbyVisionMetadata: Bool
    public var useDolbyVisionCodecTag: Bool
    public var dolbyVisionDualOutput: Bool
    public var aafMode: ProResAAFMode

    public init(
        quality: String = "422hq",
        extraAudioURL: URL? = nil,
        replaceSourceAudio: Bool = false,
        deleteSourceAudio: Bool = false,
        forcedOutputStartTimecode: String? = nil,
        dolbyVisionXMLURL: URL? = nil,
        bitrateMbps: Double? = nil,
        dolbyVisionProfile: ProResDolbyVisionProfile? = nil,
        audioChannelsPerMXFFile: Int = 1,
        colorConversion: ProResColorConversion? = nil,
        cmuMasteringNits: Float? = nil,
        includeGeneratedDolbyVisionMetadata: Bool = false,
        useDolbyVisionCodecTag: Bool = false,
        dolbyVisionDualOutput: Bool = false,
        aafMode: ProResAAFMode = .none
    ) {
        self.quality = quality
        self.extraAudioURL = extraAudioURL
        self.replaceSourceAudio = replaceSourceAudio
        self.deleteSourceAudio = deleteSourceAudio
        self.forcedOutputStartTimecode = forcedOutputStartTimecode
        self.dolbyVisionXMLURL = dolbyVisionXMLURL
        self.bitrateMbps = bitrateMbps
        self.dolbyVisionProfile = dolbyVisionProfile
        self.audioChannelsPerMXFFile = audioChannelsPerMXFFile
        self.colorConversion = colorConversion
        self.cmuMasteringNits = cmuMasteringNits
        self.includeGeneratedDolbyVisionMetadata = includeGeneratedDolbyVisionMetadata
        self.useDolbyVisionCodecTag = useDolbyVisionCodecTag
        self.dolbyVisionDualOutput = dolbyVisionDualOutput
        self.aafMode = aafMode
    }
}

public struct ProResEncodeResult: Sendable {
    public let outputURLs: [URL]
    public let framesEncoded: Int64?
    public let framesPerSecond: Double?
    public let cmuXMLURL: URL?
    public let aafURL: URL?
    fileprivate let frameworkAAFClipInfo: AAFClipInfo?

    public init(
        outputURLs: [URL],
        framesEncoded: Int64? = nil,
        framesPerSecond: Double? = nil,
        cmuXMLURL: URL? = nil,
        aafURL: URL? = nil
    ) {
        self.outputURLs = outputURLs
        self.framesEncoded = framesEncoded
        self.framesPerSecond = framesPerSecond
        self.cmuXMLURL = cmuXMLURL
        self.aafURL = aafURL
        frameworkAAFClipInfo = nil
    }

    fileprivate init(
        outputURLs: [URL],
        framesEncoded: Int64?,
        framesPerSecond: Double?,
        cmuXMLURL: URL?,
        aafURL: URL?,
        frameworkAAFClipInfo: AAFClipInfo?
    ) {
        self.outputURLs = outputURLs
        self.framesEncoded = framesEncoded
        self.framesPerSecond = framesPerSecond
        self.cmuXMLURL = cmuXMLURL
        self.aafURL = aafURL
        self.frameworkAAFClipInfo = frameworkAAFClipInfo
    }
}

public struct ProResBatchEncodeResult: Sendable {
    public let clips: [ProResEncodeResult]
    public let sequenceAAFURL: URL?

    public init(clips: [ProResEncodeResult], sequenceAAFURL: URL? = nil) {
        self.clips = clips
        self.sequenceAAFURL = sequenceAAFURL
    }
}

public enum ProResEncoderError: LocalizedError, Sendable {
    case inputNotFound(String)
    case auxiliaryFileNotFound(String)
    case invalidOption(String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .inputNotFound(let path):
            return "Input file not found: \(path)"
        case .auxiliaryFileNotFound(let path):
            return "Auxiliary file not found: \(path)"
        case .invalidOption(let detail):
            return detail
        case .encodingFailed(let detail):
            return detail
        }
    }
}

public final class ProResEncoder: Sendable {
    public static let version = "1.2.0"

    public init() {
        // Match the CLI startup path before any asynchronous work leaves the
        // caller's thread. Professional ProRes encoders can otherwise remain
        // undiscoverable when a framework client creates its first session.
        _ = MTLCreateSystemDefaultDevice()
        VTRegisterProfessionalVideoWorkflowVideoEncoders()
    }

    public func encode(
        inputURL: URL,
        outputURL: URL,
        format: ProResOutputFormat = .mov,
        options: ProResEncodeOptions = ProResEncodeOptions()
    ) async throws -> ProResEncodeResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw ProResEncoderError.inputNotFound(inputURL.path)
        }
        if let extraAudioURL = options.extraAudioURL,
           !fileManager.fileExists(atPath: extraAudioURL.path) {
            throw ProResEncoderError.auxiliaryFileNotFound(extraAudioURL.path)
        }
        if let dolbyVisionXMLURL = options.dolbyVisionXMLURL,
           !fileManager.fileExists(atPath: dolbyVisionXMLURL.path) {
            throw ProResEncoderError.auxiliaryFileNotFound(dolbyVisionXMLURL.path)
        }

        let quality = normalizedProResQuality(options.quality)
        if let validationError = proResQualityValidationError(quality) {
            throw ProResEncoderError.invalidOption(validationError)
        }
        guard options.audioChannelsPerMXFFile > 0 else {
            throw ProResEncoderError.invalidOption(
                "audioChannelsPerMXFFile must be a positive integer."
            )
        }
        guard !options.replaceSourceAudio || options.extraAudioURL != nil else {
            throw ProResEncoderError.invalidOption(
                "replaceSourceAudio requires extraAudioURL."
            )
        }
        if let cmuMasteringNits = options.cmuMasteringNits {
            guard cmuMasteringNits.isFinite,
                  cmuMasteringNits >= 1,
                  cmuMasteringNits <= 10_000 else {
                throw ProResEncoderError.invalidOption(
                    "cmuMasteringNits must be a finite value from 1 through 10000."
                )
            }
        }
        if options.cmuMasteringNits != nil && options.dolbyVisionXMLURL != nil {
            throw ProResEncoderError.invalidOption(
                "cmuMasteringNits and dolbyVisionXMLURL are mutually exclusive."
            )
        }
        if options.includeGeneratedDolbyVisionMetadata && options.cmuMasteringNits == nil {
            throw ProResEncoderError.invalidOption(
                "includeGeneratedDolbyVisionMetadata requires cmuMasteringNits."
            )
        }
        if options.includeGeneratedDolbyVisionMetadata && format != .mov {
            throw ProResEncoderError.invalidOption(
                "includeGeneratedDolbyVisionMetadata is supported only in MOV."
            )
        }
        if format == .mov && options.aafMode != .none {
            throw ProResEncoderError.invalidOption(
                "AAF generation is available only for OP-1a or OP-Atom MXF output."
            )
        }

        let colorTransform = try options.colorConversion?.makeRequest()
        if colorTransform != nil && quality == "pass" {
            throw ProResEncoderError.invalidOption(
                ColorTransformError.passthroughNotSupported.localizedDescription
            )
        }
        let internalProfile = options.dolbyVisionProfile.flatMap {
            DolbyVisionHEVCProfile(argument: $0.rawValue)
        }
        if colorTransform != nil
            && options.dolbyVisionXMLURL != nil
            && internalProfile?.usesHLGBaseLayer != true {
            throw ProResEncoderError.invalidOption(
                ColorTransformError.dolbyVisionNotSupported.localizedDescription
            )
        }
        if let internalProfile,
           internalProfile.usesHLGBaseLayer,
           colorTransform?.isDolbyVisionHLGCompatible != true {
            throw ProResEncoderError.invalidOption(
                "Dolby Vision Profile \(internalProfile.displayName) requires Rec.2020, rec2020lm, or P3-D65 HLG color conversion."
            )
        }
        if let internalProfile,
           !internalProfile.usesHLGBaseLayer,
           colorTransform?.outputOETF == .hlg {
            throw ProResEncoderError.invalidOption(
                "Dolby Vision Profile \(internalProfile.displayName) requires a PQ base layer; use Profile 8.4 for HEVC HLG or 10.4 for AV1 HLG."
            )
        }

        let wantsHEVC = isHEVCQuality(quality)
        let wantsAV1 = isAV1Quality(quality)
        let hasDolbyVisionMetadataSource =
            options.dolbyVisionXMLURL != nil
            || options.includeGeneratedDolbyVisionMetadata
        if wantsHEVC || wantsAV1 {
            guard format == .mov else {
                throw ProResEncoderError.invalidOption(
                    "\(quality) output is supported only in MOV."
                )
            }
            guard let bitrate = options.bitrateMbps, bitrate > 0 else {
                throw ProResEncoderError.invalidOption(
                    "\(quality) output requires a positive bitrateMbps value."
                )
            }
            if options.dolbyVisionProfile != nil && !hasDolbyVisionMetadataSource {
                throw ProResEncoderError.invalidOption(
                    "dolbyVisionProfile requires either dolbyVisionXMLURL or internally generated CMU metadata."
                )
            }
            if wantsHEVC,
               let profile = options.dolbyVisionProfile,
               profile != .profile76,
               profile != .profile81,
               profile != .profile84 {
                throw ProResEncoderError.invalidOption(
                    "HEVC supports Dolby Vision Profiles 7.6, 8.1, and 8.4."
                )
            }
            if wantsAV1,
               let profile = options.dolbyVisionProfile,
               profile != .profile101,
               profile != .profile104 {
                throw ProResEncoderError.invalidOption(
                    "AV1 supports Dolby Vision Profiles 10.1 and 10.4."
                )
            }
            if hasDolbyVisionMetadataSource && options.dolbyVisionProfile == nil {
                throw ProResEncoderError.invalidOption(
                    "\(quality) with Dolby Vision metadata requires dolbyVisionProfile."
                )
            }
            if options.dolbyVisionDualOutput
                && !(wantsHEVC && options.dolbyVisionProfile == .profile76) {
                throw ProResEncoderError.invalidOption(
                    "dolbyVisionDualOutput requires HEVC Dolby Vision Profile 7.6."
                )
            }
        } else {
            if options.bitrateMbps != nil {
                throw ProResEncoderError.invalidOption(
                    "bitrateMbps is available only for HEVC or AV1 output."
                )
            }
            if options.dolbyVisionProfile != nil {
                throw ProResEncoderError.invalidOption(
                    "dolbyVisionProfile is available only for HEVC or AV1 output."
                )
            }
            if options.useDolbyVisionCodecTag {
                throw ProResEncoderError.invalidOption(
                    "useDolbyVisionCodecTag is available only for HEVC or AV1 output."
                )
            }
            if options.dolbyVisionDualOutput {
                throw ProResEncoderError.invalidOption(
                    "dolbyVisionDualOutput is available only for HEVC Dolby Vision Profile 7.6 output."
                )
            }
        }

        switch format {
        case .mov:
            if outputURL.pathExtension.lowercased() != "mov" {
                throw ProResEncoderError.invalidOption(
                    "QuickTime MOV output requires a .mov outputURL; MP4 output is not supported."
                )
            }
            return try await encodeMOVFile(
                inputURL: inputURL,
                outputURL: outputURL,
                quality: quality,
                options: options,
                colorTransform: colorTransform
            )
        case .op1a, .opatom:
            return try await encodeMXFFiles(
                inputURL: inputURL,
                outputDirectoryURL: outputURL,
                format: format,
                quality: quality,
                options: options,
                colorTransform: colorTransform
            )
        }
    }

    public func encodeFolder(
        inputFolderURL: URL,
        outputDirectoryURL: URL,
        format: ProResOutputFormat = .mov,
        options: ProResEncodeOptions = ProResEncodeOptions()
    ) async throws -> ProResBatchEncodeResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: inputFolderURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ProResEncoderError.inputNotFound(inputFolderURL.path)
        }
        guard options.extraAudioURL == nil else {
            throw ProResEncoderError.invalidOption(
                "Folder encoding does not support extraAudioURL."
            )
        }
        try fileManager.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )
        let validExtensions: Set<String> = [
            "mp4", "mov", "m4v", "mxf", "avi", "mkv"
        ]
        let inputs = try fileManager.contentsOfDirectory(
            at: inputFolderURL,
            includingPropertiesForKeys: nil
        )
        .filter { validExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !inputs.isEmpty else {
            throw ProResEncoderError.invalidOption(
                "No supported media files were found in \(inputFolderURL.path)."
            )
        }

        var perClipOptions = options
        if options.aafMode == .sequence {
            perClipOptions.aafMode = .none
        }
        var results: [ProResEncodeResult] = []
        for inputURL in inputs {
            let outputURL: URL
            if format == .mov {
                outputURL = outputDirectoryURL.appendingPathComponent(
                    inputURL.deletingPathExtension().lastPathComponent + ".mov"
                )
            } else {
                outputURL = outputDirectoryURL
            }
            results.append(try await encode(
                inputURL: inputURL,
                outputURL: outputURL,
                format: format,
                options: perClipOptions
            ))
        }

        var sequenceAAFURL: URL?
        if options.aafMode == .sequence {
            guard format != .mov else {
                throw ProResEncoderError.invalidOption(
                    "Sequence AAF generation requires OP-1a or OP-Atom MXF output."
                )
            }
            let clips = results.compactMap(\.frameworkAAFClipInfo)
            guard clips.count == results.count else {
                throw ProResEncoderError.encodingFailed(
                    "Sequence AAF generation could not recover all encoded clip metadata."
                )
            }
            let sequenceName = inputFolderURL.lastPathComponent.isEmpty
                ? "ProRes Sequence"
                : inputFolderURL.lastPathComponent
            let candidate = outputDirectoryURL.appendingPathComponent(sequenceName + ".aaf")
            guard generateAAFWithSwiftAAF(
                clips: clips,
                outputPath: candidate.path,
                sequenceName: sequenceName
            ) else {
                throw ProResEncoderError.encodingFailed(
                    "Sequence AAF generation failed."
                )
            }
            sequenceAAFURL = candidate
        }
        return ProResBatchEncodeResult(
            clips: results,
            sequenceAAFURL: sequenceAAFURL
        )
    }

    public func encodeTimeline(
        inputTimelineURL: URL,
        outputURL: URL,
        mediaSearchURLs: [URL] = [],
        options: ProResEncodeOptions = ProResEncodeOptions()
    ) async throws -> ProResEncodeResult {
        guard FileManager.default.fileExists(atPath: inputTimelineURL.path) else {
            throw ProResEncoderError.inputNotFound(inputTimelineURL.path)
        }
        let quality = normalizedProResQuality(options.quality)
        guard !isHEVCQuality(quality), !isAV1Quality(quality) else {
            throw ProResEncoderError.invalidOption(
                "Timeline bounce supports ProRes output only."
            )
        }
        guard options.extraAudioURL == nil,
              options.dolbyVisionXMLURL == nil,
              options.bitrateMbps == nil,
              options.dolbyVisionProfile == nil,
              !options.useDolbyVisionCodecTag,
              options.aafMode == .none else {
            throw ProResEncoderError.invalidOption(
                "Timeline bounce does not support extra audio, external Dolby Vision XML, compressed-codec options, or AAF export."
            )
        }
        if options.includeGeneratedDolbyVisionMetadata && options.cmuMasteringNits == nil {
            throw ProResEncoderError.invalidOption(
                "includeGeneratedDolbyVisionMetadata requires cmuMasteringNits."
            )
        }
        let descriptor = try timelineDescriptor(
            from: inputTimelineURL,
            mediaSearchURLs: mediaSearchURLs
        )
        let composition = try await CompositionBuilder().buildAsync(from: descriptor)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let colorTransform = try options.colorConversion?.makeRequest()
        guard await encodeTimelineMOV(
            composition: composition,
            descriptor: descriptor,
            outputURL: outputURL,
            quality: quality,
            forcedOutputStartTimecode: options.forcedOutputStartTimecode,
            deleteSourceAudio: options.deleteSourceAudio,
            colorTransform: colorTransform
        ) else {
            throw ProResEncoderError.encodingFailed(
                "Timeline bounce failed for \(inputTimelineURL.lastPathComponent)."
            )
        }

        var cmuArtifacts: CMUOutputArtifacts?
        if let masteringPeakNits = options.cmuMasteringNits {
            cmuArtifacts = try await runCMUAnalysisOnOutput(
                outputURL: outputURL,
                masteringPeakNits: masteringPeakNits,
                forcedStartTimecode: options.forcedOutputStartTimecode
            )
        }
        if options.includeGeneratedDolbyVisionMetadata,
           let xmlURL = cmuArtifacts?.xmlURL {
            guard await includeGeneratedCMUXMLInProResMOV(
                outputURL: outputURL,
                xmlURL: xmlURL
            ) else {
                throw ProResEncoderError.encodingFailed(
                    "Could not include generated CMU XML in timeline output."
                )
            }
        }
        return ProResEncodeResult(
            outputURLs: [outputURL],
            cmuXMLURL: cmuArtifacts?.xmlURL
        )
    }

    public func transformTimeline(
        inputURL: URL,
        outputURL: URL,
        to format: ProResTimelineFormat,
        mediaSearchURLs: [URL] = []
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ProResEncoderError.inputNotFound(inputURL.path)
        }
        let descriptor = try timelineDescriptor(
            from: inputURL,
            mediaSearchURLs: mediaSearchURLs
        )
        let finalURL = outputURL.pathExtension.isEmpty
            ? outputURL.appendingPathExtension(format.rawValue)
            : outputURL
        let success: Bool
        switch format {
        case .aaf:
            success = generateLinkedAAFWithSwiftAAF(
                descriptor: descriptor,
                outputPath: finalURL.path,
                sequenceName: descriptor.name
            )
        case .xml:
            success = FCP7XMLTimelineWriter().write(descriptor, to: finalURL)
        }
        guard success else {
            throw ProResEncoderError.encodingFailed(
                "Timeline transform to \(format.rawValue.uppercased()) failed."
            )
        }
        return finalURL
    }

    private func timelineDescriptor(
        from inputURL: URL,
        mediaSearchURLs: [URL]
    ) throws -> TimelineDescriptor {
        switch inputURL.pathExtension.lowercased() {
        case "xml", "fcpxml":
            guard let descriptor = XMLTimelineParser().parse(url: inputURL) else {
                throw ProResEncoderError.encodingFailed(
                    "Failed to parse XML timeline."
                )
            }
            return descriptor
        case "aaf":
            let searchURLs = mediaSearchURLs + [inputURL.deletingLastPathComponent()]
            guard let descriptor = AAFTimelineParser().parse(
                url: inputURL,
                mediaSearchPaths: searchURLs
            ) else {
                throw ProResEncoderError.encodingFailed(
                    "Failed to parse AAF timeline."
                )
            }
            return descriptor
        default:
            throw ProResEncoderError.invalidOption(
                "Unsupported timeline input extension: .\(inputURL.pathExtension)"
            )
        }
    }

    private func encodeMOVFile(
        inputURL: URL,
        outputURL: URL,
        quality: String,
        options: ProResEncodeOptions,
        colorTransform: ColorTransformRequest?
    ) async throws -> ProResEncodeResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: inputURL)
        if let masteringPeakNits = options.cmuMasteringNits {
            try await cmuPreflight(
                inputAsset: asset,
                quality: quality,
                colorTransform: colorTransform,
                masteringPeakNits: masteringPeakNits
            )
        }
        let sourceColorSpace: SourceColorSpace?
        if quality != "pass",
           let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            sourceColorSpace = await detectColorSpace(from: videoTrack)
        } else {
            sourceColorSpace = nil
        }

        let internalProfile = options.dolbyVisionProfile.flatMap {
            DolbyVisionHEVCProfile(argument: $0.rawValue)
        }
        let hevcOptions = isHEVCQuality(quality)
            ? HEVCEncodeOptions(
                bitrateMbps: options.bitrateMbps ?? 0,
                dvProfile: internalProfile
            )
            : nil
        let av1Options = isAV1Quality(quality)
            ? AV1EncodeOptions(
                bitrateMbps: options.bitrateMbps ?? 0,
                dvProfile: internalProfile
            )
            : nil

        var generatedCMUArtifacts: CMUOutputArtifacts?
        var dolbyVisionXMLURL = options.dolbyVisionXMLURL
        let isCompressedOutput = isHEVCQuality(quality) || isAV1Quality(quality)
        let temporaryCMUSidecarBaseURL = isCompressedOutput
            ? FileManager.default.temporaryDirectory.appendingPathComponent(
                "prores-encoder-cmu-\(UUID().uuidString)"
            )
            : outputURL
        defer {
            if isCompressedOutput {
                try? fileManager.removeItem(
                    at: temporaryCMUSidecarBaseURL.appendingPathExtension("xml")
                )
            }
        }
        if options.includeGeneratedDolbyVisionMetadata,
           let masteringPeakNits = options.cmuMasteringNits,
           isCompressedOutput {
            generatedCMUArtifacts = try await runCMUAnalysisBeforeCompressedEncode(
                inputAsset: asset,
                sidecarBaseURL: temporaryCMUSidecarBaseURL,
                quality: quality,
                colorTransform: colorTransform,
                masteringPeakNits: masteringPeakNits,
                forcedStartTimecode: options.forcedOutputStartTimecode
            )
            dolbyVisionXMLURL = generatedCMUArtifacts?.xmlURL
        }

        let success = await encodeMOV(
            asset: asset,
            outputURL: outputURL,
            quality: quality,
            extraAudioURL: options.extraAudioURL,
            audioReplace: options.replaceSourceAudio,
            deleteSourceAudio: options.deleteSourceAudio,
            forcedOutputStartTimecode: options.forcedOutputStartTimecode,
            dolbyVisionXMLURL: dolbyVisionXMLURL,
            hevcOptions: hevcOptions,
            av1Options: av1Options,
            colorSpace: sourceColorSpace,
            fpsInfo: await framerateInfo(from: asset),
            colorTransform: colorTransform,
            useDolbyVisionCodecTag: options.useDolbyVisionCodecTag,
            dolbyVisionDualOutput: options.dolbyVisionDualOutput
        )
        guard success else {
            throw ProResEncoderError.encodingFailed(
                "MOV encoding failed for \(inputURL.lastPathComponent)."
            )
        }
        if let masteringPeakNits = options.cmuMasteringNits,
           generatedCMUArtifacts == nil {
            generatedCMUArtifacts = try await runCMUAnalysisAfterEncode(
                inputAsset: asset,
                encodedOutputURL: outputURL,
                sidecarBaseURL: temporaryCMUSidecarBaseURL,
                quality: quality,
                masteringPeakNits: masteringPeakNits,
                forcedStartTimecode: options.forcedOutputStartTimecode
            )
        }
        if options.includeGeneratedDolbyVisionMetadata,
           !isHEVCQuality(quality),
           !isAV1Quality(quality),
           let xmlURL = generatedCMUArtifacts?.xmlURL {
            guard await includeGeneratedCMUXMLInProResMOV(
                outputURL: outputURL,
                xmlURL: xmlURL
            ) else {
                throw ProResEncoderError.encodingFailed(
                    "Could not include generated CMU XML in \(outputURL.lastPathComponent)."
                )
            }
        }
        var outputURLs = [outputURL]
        if options.dolbyVisionDualOutput {
            let dualURLs = DolbyVisionProfile7DualWriter.outputURLs(for: outputURL)
            outputURLs.append(dualURLs.baseLayerURL)
            outputURLs.append(dualURLs.enhancementLayerURL)
        }
        return ProResEncodeResult(
            outputURLs: outputURLs,
            cmuXMLURL: isCompressedOutput ? nil : generatedCMUArtifacts?.xmlURL
        )
    }

    private func encodeMXFFiles(
        inputURL: URL,
        outputDirectoryURL: URL,
        format: ProResOutputFormat,
        quality: String,
        options: ProResEncodeOptions,
        colorTransform: ColorTransformRequest?
    ) async throws -> ProResEncodeResult {
        guard !isHEVCQuality(quality), !isAV1Quality(quality) else {
            throw ProResEncoderError.invalidOption(
                "MXF output supports ProRes qualities only."
            )
        }
        guard options.dolbyVisionXMLURL == nil else {
            throw ProResEncoderError.invalidOption(
                "Dolby Vision XML is supported only in MOV."
            )
        }
        guard options.forcedOutputStartTimecode == nil else {
            throw ProResEncoderError.invalidOption(
                "forcedOutputStartTimecode is supported only in MOV."
            )
        }
        if options.extraAudioURL != nil
            && !options.replaceSourceAudio
            && !options.deleteSourceAudio {
            throw ProResEncoderError.invalidOption(
                "MXF extraAudioURL requires replaceSourceAudio or deleteSourceAudio."
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )
        let asset = AVURLAsset(url: inputURL)
        if let masteringPeakNits = options.cmuMasteringNits {
            try await cmuPreflight(
                inputAsset: asset,
                quality: quality,
                colorTransform: colorTransform,
                masteringPeakNits: masteringPeakNits
            )
        }
        let basename = inputURL.deletingPathExtension().lastPathComponent
        let result = await encodeMXF(
            asset: asset,
            sourceURL: inputURL,
            outputDir: outputDirectoryURL.path,
            basename: basename,
            quality: quality,
            exportFormat: format.rawValue,
            audioCHperFile: options.audioChannelsPerMXFFile,
            audioOverrideURL: (options.replaceSourceAudio || options.deleteSourceAudio)
                ? options.extraAudioURL
                : nil,
            deleteSourceAudio: options.deleteSourceAudio,
            colorTransform: colorTransform
        )
        guard result.success else {
            throw ProResEncoderError.encodingFailed(
                result.error ?? "MXF encoding failed for \(inputURL.lastPathComponent)."
            )
        }

        var cmuXMLURL: URL?
        if let masteringPeakNits = options.cmuMasteringNits,
           let videoPath = result.paths.first(where: { $0.hasSuffix("_v.mxf") })
                ?? result.paths.first(where: { $0.hasSuffix(".mxf") }) {
            cmuXMLURL = try await runCMUAnalysisAfterEncode(
                inputAsset: asset,
                encodedOutputURL: URL(fileURLWithPath: videoPath),
                sidecarBaseURL: outputDirectoryURL.appendingPathComponent(basename),
                quality: quality,
                masteringPeakNits: masteringPeakNits,
                forcedStartTimecode: nil
            ).xmlURL
        }

        let aafClipInfo = await makeAAFClipInfo(
            asset: asset,
            result: result,
            format: format,
            quality: quality,
            channelsPerFile: options.audioChannelsPerMXFFile
        )
        var aafURL: URL?
        if options.aafMode != .none {
            let candidate = outputDirectoryURL.appendingPathComponent(basename + ".aaf")
            guard generateAAFWithSwiftAAF(
                clips: [aafClipInfo],
                outputPath: candidate.path,
                sequenceName: basename
            ) else {
                throw ProResEncoderError.encodingFailed(
                    "AAF generation failed for \(inputURL.lastPathComponent)."
                )
            }
            aafURL = candidate
        }
        return ProResEncodeResult(
            outputURLs: result.paths.map(URL.init(fileURLWithPath:)),
            framesEncoded: result.framesEncoded,
            framesPerSecond: result.fps,
            cmuXMLURL: cmuXMLURL,
            aafURL: aafURL,
            frameworkAAFClipInfo: aafClipInfo
        )
    }

    private func makeAAFClipInfo(
        asset: AVAsset,
        result: MXFEncodeResult,
        format: ProResOutputFormat,
        quality: String,
        channelsPerFile: Int
    ) async -> AAFClipInfo {
        let isOPAtom = format == .opatom
        let videoMXF = isOPAtom
            ? (result.paths.first { $0.hasSuffix("_v.mxf") } ?? result.paths[0])
            : result.paths[0]
        let audioMXFs = isOPAtom
            ? result.paths.filter { $0.hasSuffix(".mxf") && !$0.hasSuffix("_v.mxf") }.sorted()
            : []
        let audioChannelCounts: [Int]
        if isOPAtom {
            let safeChannelsPerFile = max(channelsPerFile, 1)
            audioChannelCounts = (0..<audioMXFs.count).map { index in
                let consumed = index * safeChannelsPerFile
                return max(1, min(safeChannelsPerFile, result.sourceAudioChannels - consumed))
            }
        } else {
            audioChannelCounts = result.sourceAudioChannels > 0
                ? [result.sourceAudioChannels]
                : []
        }
        let fpsInfo = await framerateInfo(from: asset)
        let (width, height) = await videoSize(from: asset)
        let totalAudioSamples: Int64 = {
            let sampleRate = Int64(48_000)
            let numerator = Int64(fpsInfo.numerator)
            let denominator = Int64(fpsInfo.denominator)
            return (result.framesEncoded * sampleRate * denominator + numerator / 2) / numerator
        }()
        return AAFClipInfo(
            videoMXFPath: videoMXF,
            audioMXFPaths: audioMXFs,
            width: width,
            height: height,
            duration: result.framesEncoded,
            fpsNumerator: Int32(fpsInfo.numerator),
            fpsDenominator: Int32(fpsInfo.denominator),
            isDropFrame: fpsInfo.isDropFrame,
            timecode: await readTimecodeString(from: asset),
            audioBits: 24,
            audioSampleRate: 48_000,
            audioChannels: audioChannelCounts.first ?? max(channelsPerFile, 1),
            audioChannelCounts: audioChannelCounts,
            audioTrackCount: isOPAtom
                ? audioMXFs.count
                : (result.sourceAudioChannels > 0 ? 1 : 0),
            isOPAtom: isOPAtom,
            codecVariant: quality,
            videoMXFUMID: result.videoMXFUMID,
            audioMXFUMIDs: result.audioMXFUMIDs,
            totalAudioSamples: totalAudioSamples
        )
    }
}
