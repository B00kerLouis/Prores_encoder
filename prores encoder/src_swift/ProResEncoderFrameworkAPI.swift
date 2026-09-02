// Exposes file, folder, and timeline encoding workflows as a Swift API.

import Foundation
@preconcurrency import AVFoundation
import Metal
import VideoToolbox

/// Container layouts available to framework clients.
public enum ProResOutputFormat: String, Sendable {
    case mov
    case mp4
    case op1a
    case opatom
}

/// Controls whether MXF encoding also creates linked AAF output.
public enum ProResAAFMode: Sendable {
    case none
    case sequence
    case perClip
}

/// Supported timeline document formats for conversion.
public enum ProResTimelineFormat: String, Sendable {
    case aaf
    case xml
}

/// Target color gamuts accepted by direct and LUT output declarations.
public enum ProResColorGamut: String, Sendable {
    case rec709
    case rec2020
    case rec2020LimitedToP3D65 = "rec2020lm"
    case p3D65 = "p3d65"
}

/// Target transfer functions accepted by the Metal color pipeline.
public enum ProResTransferFunction: String, Sendable {
    case gamma24 = "gamma2.4"
    case gamma26 = "gamma2.6"
    case pq
    case hlg
}

/// Dynamic HDR profiles supported by compressed-output workflows.
public enum ProResDolbyVisionProfile: String, Sendable {
    case profile5 = "5"
    case profile76 = "76"
    case profile81 = "81"
    case profile84 = "84"
    case profile10 = "10"
    case profile101 = "101"
    case profile104 = "104"
}

/// Independently encoded elementary-stream formats available only through the Framework API.
public enum ProResElementaryStreamFormat: String, CaseIterable, Hashable, Sendable {
    case proResProxy = "prores_proxy"
    case proRes422LT = "prores_422lt"
    case proRes422 = "prores_422"
    case proRes422HQ = "prores_422hq"
    case proRes4444 = "prores_4444"
    case proRes4444XQ = "prores_4444xq"
    case hevc
    case av1
    case dolbyVisionProfile5 = "dolby_vision_p5"
    case dolbyVisionProfile76 = "dolby_vision_p7_6"
    case dolbyVisionProfile81 = "dolby_vision_p8_1"
    case dolbyVisionProfile84 = "dolby_vision_p8_4"
    case dolbyVisionProfile10 = "dolby_vision_p10"
    case dolbyVisionProfile101 = "dolby_vision_p10_1"
    case dolbyVisionProfile104 = "dolby_vision_p10_4"

    /// Every Dolby Vision elementary-stream format supported by the encoder.
    public static let allDolbyVision: [ProResElementaryStreamFormat] = [
        .dolbyVisionProfile5,
        .dolbyVisionProfile76,
        .dolbyVisionProfile81,
        .dolbyVisionProfile84,
        .dolbyVisionProfile10,
        .dolbyVisionProfile101,
        .dolbyVisionProfile104
    ]

    /// Every format that does not require a Dolby Vision metadata source.
    public static let allStandard: [ProResElementaryStreamFormat] = [
        .proResProxy,
        .proRes422LT,
        .proRes422,
        .proRes422HQ,
        .proRes4444,
        .proRes4444XQ,
        .hevc,
        .av1
    ]

    fileprivate var quality: String {
        switch self {
        case .proResProxy: return "proxy"
        case .proRes422LT: return "422lt"
        case .proRes422: return "422"
        case .proRes422HQ: return "422hq"
        case .proRes4444: return "4444"
        case .proRes4444XQ: return "4444xq"
        case .hevc,
             .dolbyVisionProfile5,
             .dolbyVisionProfile76,
             .dolbyVisionProfile81,
             .dolbyVisionProfile84:
            return "hevc"
        case .av1,
             .dolbyVisionProfile10,
             .dolbyVisionProfile101,
             .dolbyVisionProfile104:
            return "av1"
        }
    }

    fileprivate var dolbyVisionProfile: ProResDolbyVisionProfile? {
        switch self {
        case .dolbyVisionProfile5: return .profile5
        case .dolbyVisionProfile76: return .profile76
        case .dolbyVisionProfile81: return .profile81
        case .dolbyVisionProfile84: return .profile84
        case .dolbyVisionProfile10: return .profile10
        case .dolbyVisionProfile101: return .profile101
        case .dolbyVisionProfile104: return .profile104
        default: return nil
        }
    }

    fileprivate var rawFileExtension: String {
        switch quality {
        case "hevc": return "hevc"
        case "av1": return "obu"
        default: return "prores"
        }
    }
}

/// Identifies the stream represented by one elementary-stream artifact.
public enum ProResElementaryStreamLayer: String, Sendable {
    case primary
    case baseLayer
    case enhancementLayer
}

/// One raw file produced by a Framework elementary-stream batch.
public struct ProResElementaryStreamArtifact: Sendable {
    public let format: ProResElementaryStreamFormat
    public let layer: ProResElementaryStreamLayer
    public let url: URL

    public init(
        format: ProResElementaryStreamFormat,
        layer: ProResElementaryStreamLayer,
        url: URL
    ) {
        self.format = format
        self.layer = layer
        self.url = url
    }
}

/// Options for Framework-only multi-format, raw-only video fan-out.
public struct ProResElementaryStreamOptions: Sendable {
    public var formats: [ProResElementaryStreamFormat]
    public var dolbyVisionXMLURL: URL?
    public var hevcBitrateMbps: Double
    public var profile76BitrateMbps: Double
    public var av1BitrateMbps: Double
    public var dolbyVisionGamut: ProResColorGamut
    public var targetPeakNits: Float
    public var baseColorConversion: ProResColorConversion?
    public var fileNamePrefix: String?
    public var overwriteExisting: Bool

    public init(
        formats: [ProResElementaryStreamFormat] = ProResElementaryStreamFormat.allStandard,
        dolbyVisionXMLURL: URL? = nil,
        hevcBitrateMbps: Double = 50,
        profile76BitrateMbps: Double = 80,
        av1BitrateMbps: Double = 50,
        dolbyVisionGamut: ProResColorGamut = .rec2020,
        targetPeakNits: Float = 1_000,
        baseColorConversion: ProResColorConversion? = nil,
        fileNamePrefix: String? = nil,
        overwriteExisting: Bool = false
    ) {
        self.formats = formats
        self.dolbyVisionXMLURL = dolbyVisionXMLURL
        self.hevcBitrateMbps = hevcBitrateMbps
        self.profile76BitrateMbps = profile76BitrateMbps
        self.av1BitrateMbps = av1BitrateMbps
        self.dolbyVisionGamut = dolbyVisionGamut
        self.targetPeakNits = targetPeakNits
        self.baseColorConversion = baseColorConversion
        self.fileNamePrefix = fileNamePrefix
        self.overwriteExisting = overwriteExisting
    }
}

/// Raw-only artifacts returned after every requested format has encoded successfully.
public struct ProResElementaryStreamResult: Sendable {
    public let artifacts: [ProResElementaryStreamArtifact]

    public init(artifacts: [ProResElementaryStreamArtifact]) {
        self.artifacts = artifacts
    }
}

/// Direct gamut, transfer, and peak-luminance mapping request.
public struct ProResColorConversion: Sendable {
    public var gamut: ProResColorGamut
    public var transferFunction: ProResTransferFunction
    public var targetPeakNits: Float

    /// Creates a direct color-conversion declaration.
    public init(
        gamut: ProResColorGamut,
        transferFunction: ProResTransferFunction,
        targetPeakNits: Float
    ) {
        self.gamut = gamut
        self.transferFunction = transferFunction
        self.targetPeakNits = targetPeakNits
    }

    /// Converts public values to the validated internal request model.
    fileprivate func makeRequest() throws -> ColorTransformRequest {
        try ColorTransformRequest(
            gamut: gamut.rawValue,
            oetf: transferFunction.rawValue,
            nits: String(targetPeakNits)
        )
    }
}

/// LUT file plus the color space and peak luminance produced by that table.
public struct ProResLUTColorConversion: Sendable {
    public var lutURL: URL
    public var gamut: ProResColorGamut
    public var transferFunction: ProResTransferFunction
    public var targetPeakNits: Float

    /// Creates a LUT burn-in declaration and its post-LUT output metadata.
    public init(
        lutURL: URL,
        gamut: ProResColorGamut,
        transferFunction: ProResTransferFunction,
        targetPeakNits: Float
    ) {
        self.lutURL = lutURL
        self.gamut = gamut
        self.transferFunction = transferFunction
        self.targetPeakNits = targetPeakNits
    }

    /// Loads and validates the LUT through the internal request model.
    fileprivate func makeRequest() throws -> ColorTransformRequest {
        try ColorTransformRequest(
            gamut: gamut.rawValue,
            oetf: transferFunction.rawValue,
            nits: String(targetPeakNits),
            lutURL: lutURL
        )
    }
}

/// Options shared by single-file, folder, and timeline encoding.
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
    public var lutColorConversion: ProResLUTColorConversion?
    public var cmuMasteringNits: Float?
    public var includeGeneratedDolbyVisionMetadata: Bool
    public var useDolbyVisionCodecTag: Bool
    /// Also emits the encoded video as a raw elementary stream beside the container.
    /// Profile 7.6 writes separate BL and EL HEVC streams.
    public var outputVideoRaw: Bool
    /// H.264/HEVC VideoToolbox multi-pass. Nil uses the GOP-on / all-intra-off default.
    public var multiPass: Bool?
    /// H.264/HEVC B-frame reordering. Nil uses on for GOP encodes and off for all-intra.
    /// Profile 7.6 ignores this and always encodes I/P.
    public var bFrames: Bool?
    public var aafMode: ProResAAFMode

    /// Creates an option set with MOV 422 HQ defaults and optional advanced features.
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
        lutColorConversion: ProResLUTColorConversion? = nil,
        cmuMasteringNits: Float? = nil,
        includeGeneratedDolbyVisionMetadata: Bool = false,
        useDolbyVisionCodecTag: Bool = false,
        outputVideoRaw: Bool = false,
        multiPass: Bool? = nil,
        bFrames: Bool? = nil,
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
        self.lutColorConversion = lutColorConversion
        self.cmuMasteringNits = cmuMasteringNits
        self.includeGeneratedDolbyVisionMetadata = includeGeneratedDolbyVisionMetadata
        self.useDolbyVisionCodecTag = useDolbyVisionCodecTag
        self.outputVideoRaw = outputVideoRaw
        self.multiPass = multiPass
        self.bFrames = bFrames
        self.aafMode = aafMode
    }

    /// Enforces mutual exclusion between direct conversion and LUT burn-in.
    fileprivate func makeColorTransformRequest() throws -> ColorTransformRequest? {
        guard colorConversion == nil || lutColorConversion == nil else {
            throw ColorTransformError.conflictingColorModes
        }
        if let lutColorConversion {
            return try lutColorConversion.makeRequest()
        }
        return try colorConversion?.makeRequest()
    }
}

/// Files and media properties produced by one encoded input.
public struct ProResEncodeResult: Sendable {
    public let outputURLs: [URL]
    public let framesEncoded: Int64?
    public let framesPerSecond: Double?
    public let cmuXMLURL: URL?
    public let aafURL: URL?
    fileprivate let frameworkAAFClipInfo: AAFClipInfo?

    /// Creates a result for clients that already know all generated file URLs.
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

    /// Creates a result from the internal output bundle used by encoder workflows.
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

/// Per-clip results and optional sequence-level AAF from a folder workflow.
public struct ProResBatchEncodeResult: Sendable {
    public let clips: [ProResEncodeResult]
    public let sequenceAAFURL: URL?

    /// Creates a batch result in input processing order.
    public init(clips: [ProResEncodeResult], sequenceAAFURL: URL? = nil) {
        self.clips = clips
        self.sequenceAAFURL = sequenceAAFURL
    }
}

/// Public validation, missing-file, and encoding failures.
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

/// Stateless entry point for media encoding and timeline conversion.
public final class ProResEncoder: Sendable {
    public static let version = "1.2.5"

    /// Initializes GPU discovery and registers platform codec components.
    public init() {
        // Initialize GPU and codec discovery on the caller's thread before
        // asynchronous work begins.
        _ = MTLCreateSystemDefaultDevice()
        VTRegisterProfessionalVideoWorkflowVideoEncoders()
    }

    /// Encodes one media file and returns every generated output URL.
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
        if let lutURL = options.lutColorConversion?.lutURL,
           !fileManager.fileExists(atPath: lutURL.path) {
            throw ProResEncoderError.auxiliaryFileNotFound(lutURL.path)
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
        if options.includeGeneratedDolbyVisionMetadata
            && format != .mov
            && format != .mp4 {
            throw ProResEncoderError.invalidOption(
                "includeGeneratedDolbyVisionMetadata is supported only in MOV or MP4 compressed output."
            )
        }
        if (format == .mov || format == .mp4) && options.aafMode != .none {
            throw ProResEncoderError.invalidOption(
                "AAF generation is available only for OP-1a or OP-Atom MXF output."
            )
        }

        let colorTransform = try options.makeColorTransformRequest()
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
            && internalProfile?.usesHLGBaseLayer != true
            && internalProfile?.usesNativeIPT != true {
            throw ProResEncoderError.invalidOption(
                ColorTransformError.dolbyVisionNotSupported.localizedDescription
            )
        }
        if let internalProfile,
           internalProfile.usesNativeIPT,
           colorTransform?.isDolbyVisionNativeCompatible != true {
            throw ProResEncoderError.invalidOption(
                "Dolby Vision Profile \(internalProfile.displayName) requires a direct Rec.2020, rec2020lm, or P3-D65 PQ color conversion; LUT processing is not allowed."
            )
        }
        if colorTransform?.hasLUT == true,
           options.dolbyVisionXMLURL != nil || options.includeGeneratedDolbyVisionMetadata {
            throw ProResEncoderError.invalidOption(
                "LUT burn-in cannot be combined with Dolby Vision XML or generated Dolby Vision metadata. Generate metadata from the graded output in a separate workflow."
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
        let wantsH264 = isH264Quality(quality)
        let wantsAV1 = isAV1Quality(quality)
        let wantsVideoBitrateOptions = wantsH264 || wantsHEVC || wantsAV1
        let hasDolbyVisionMetadataSource =
            options.dolbyVisionXMLURL != nil
            || options.includeGeneratedDolbyVisionMetadata
        if wantsVideoBitrateOptions {
            guard format == .mov || format == .mp4 else {
                throw ProResEncoderError.invalidOption(
                    "\(quality) output is supported only in MOV or MP4."
                )
            }
            guard let bitrate = options.bitrateMbps,
                  encodedVideoBitrateIsRepresentable(bitrate, usesAV1: wantsAV1) else {
                throw ProResEncoderError.invalidOption(
                    "\(quality) output requires a finite, representable bitrateMbps value."
                )
            }
            if wantsH264 && hasDolbyVisionMetadataSource {
                throw ProResEncoderError.invalidOption(
                    "Dolby Vision metadata requires HEVC or AV1; H.264 has no supported Dolby Vision bitstream profile."
                )
            }
            if options.multiPass != nil && !(wantsH264 || wantsHEVC) {
                throw ProResEncoderError.invalidOption(
                    "multiPass is available only for H.264 or HEVC output."
                )
            }
            if options.bFrames != nil && !(wantsH264 || wantsHEVC) {
                throw ProResEncoderError.invalidOption(
                    "bFrames is available only for H.264 or HEVC output."
                )
            }
            if options.dolbyVisionProfile != nil && !hasDolbyVisionMetadataSource {
                throw ProResEncoderError.invalidOption(
                    "dolbyVisionProfile requires either dolbyVisionXMLURL or internally generated CMU metadata."
                )
            }
            if wantsHEVC,
               let profile = options.dolbyVisionProfile,
               profile != .profile5,
               profile != .profile76,
               profile != .profile81,
               profile != .profile84 {
                throw ProResEncoderError.invalidOption(
                    "HEVC supports Dolby Vision Profiles 5, 7.6, 8.1, and 8.4."
                )
            }
            if wantsAV1,
               let profile = options.dolbyVisionProfile,
               profile != .profile10,
               profile != .profile101,
               profile != .profile104 {
                throw ProResEncoderError.invalidOption(
                    "AV1 supports Dolby Vision Profiles 10, 10.1, and 10.4."
                )
            }
            if hasDolbyVisionMetadataSource && options.dolbyVisionProfile == nil {
                throw ProResEncoderError.invalidOption(
                    "\(quality) with Dolby Vision metadata requires dolbyVisionProfile."
                )
            }
        } else {
            if options.bitrateMbps != nil {
                throw ProResEncoderError.invalidOption(
                    "bitrateMbps is available only for H.264, HEVC, or AV1 output."
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
            if options.multiPass != nil {
                throw ProResEncoderError.invalidOption(
                    "multiPass is available only for H.264 or HEVC output."
                )
            }
            if options.bFrames != nil {
                throw ProResEncoderError.invalidOption(
                    "bFrames is available only for H.264 or HEVC output."
                )
            }
            if options.outputVideoRaw && quality == "pass" {
                throw ProResEncoderError.invalidOption(
                    "outputVideoRaw requires a re-encoded video quality, not pass-through."
                )
            }
        }
        if format == .mp4 && !(wantsH264 || wantsHEVC || wantsAV1) && quality != "pass" {
            throw ProResEncoderError.invalidOption(
                "MP4 output supports H.264, HEVC, AV1, or pass-through."
            )
        }
        if format == .mp4, options.forcedOutputStartTimecode != nil {
            throw ProResEncoderError.invalidOption(
                "forcedOutputStartTimecode is supported only in MOV."
            )
        }

        switch format {
        case .mov:
            if outputURL.pathExtension.lowercased() != "mov" {
                throw ProResEncoderError.invalidOption(
                    "QuickTime MOV output requires a .mov outputURL."
                )
            }
            return try await encodeMOVFile(
                inputURL: inputURL,
                outputURL: outputURL,
                quality: quality,
                options: options,
                colorTransform: colorTransform
            )
        case .mp4:
            if outputURL.pathExtension.lowercased() != "mp4" {
                throw ProResEncoderError.invalidOption(
                    "MP4 output requires a .mp4 outputURL."
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

    /// Independently encodes every requested video format and commits only raw streams.
    /// Temporary MOV containers are private staging artifacts and are removed before return.
    public func encodeVideoElementaryStreams(
        inputURL: URL,
        outputDirectoryURL: URL,
        options: ProResElementaryStreamOptions = ProResElementaryStreamOptions()
    ) async throws -> ProResElementaryStreamResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw ProResEncoderError.inputNotFound(inputURL.path)
        }
        guard !options.formats.isEmpty else {
            throw ProResEncoderError.invalidOption(
                "Elementary-stream encoding requires at least one format."
            )
        }
        guard Set(options.formats).count == options.formats.count else {
            throw ProResEncoderError.invalidOption(
                "Elementary-stream formats must not contain duplicates."
            )
        }

        let requestedDolbyVision = options.formats.contains {
            $0.dolbyVisionProfile != nil
        }
        if requestedDolbyVision {
            guard let xmlURL = options.dolbyVisionXMLURL else {
                throw ProResEncoderError.invalidOption(
                    "Dolby Vision elementary streams require dolbyVisionXMLURL."
                )
            }
            guard fileManager.fileExists(atPath: xmlURL.path) else {
                throw ProResEncoderError.auxiliaryFileNotFound(xmlURL.path)
            }
            guard options.targetPeakNits.isFinite,
                  options.targetPeakNits >= 1,
                  options.targetPeakNits <= 10_000 else {
                throw ProResEncoderError.invalidOption(
                    "targetPeakNits must be a finite value from 1 through 10000."
                )
            }
        }

        let requestsProfile76 = options.formats.contains(.dolbyVisionProfile76)
        let requestsOtherHEVC = options.formats.contains {
            $0.quality == "hevc" && $0 != .dolbyVisionProfile76
        }
        let requestsAV1 = options.formats.contains { $0.quality == "av1" }
        if requestsOtherHEVC,
           !encodedVideoBitrateIsRepresentable(
                options.hevcBitrateMbps,
                usesAV1: false
           ) {
            throw ProResEncoderError.invalidOption(
                "hevcBitrateMbps must be a finite, representable positive value."
            )
        }
        if requestsProfile76,
           !encodedVideoBitrateIsRepresentable(
                options.profile76BitrateMbps,
                usesAV1: false
           ) {
            throw ProResEncoderError.invalidOption(
                "profile76BitrateMbps must be a finite, representable positive value."
            )
        }
        if requestsAV1,
           !encodedVideoBitrateIsRepresentable(options.av1BitrateMbps, usesAV1: true) {
            throw ProResEncoderError.invalidOption(
                "av1BitrateMbps must be a finite, representable positive value."
            )
        }

        var isOutputDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: outputDirectoryURL.path,
            isDirectory: &isOutputDirectory
        ), !isOutputDirectory.boolValue {
            throw ProResEncoderError.invalidOption(
                "Elementary-stream output path is not a directory: \(outputDirectoryURL.path)"
            )
        }
        try fileManager.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let defaultPrefix = inputURL.deletingPathExtension().lastPathComponent
        let prefix = options.fileNamePrefix?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultPrefix
        guard !prefix.isEmpty,
              prefix != ".",
              prefix != "..",
              !prefix.contains("/"),
              prefix == URL(fileURLWithPath: prefix).lastPathComponent else {
            throw ProResEncoderError.invalidOption(
                "fileNamePrefix must be a non-empty file name without path separators."
            )
        }

        typealias ArtifactPlan = (
            format: ProResElementaryStreamFormat,
            layer: ProResElementaryStreamLayer,
            finalURL: URL
        )
        var artifactPlans: [ArtifactPlan] = []
        for format in options.formats {
            if format == .dolbyVisionProfile76 {
                artifactPlans.append((
                    format,
                    .baseLayer,
                    outputDirectoryURL.appendingPathComponent(
                        "\(prefix)_\(format.rawValue)_bl.\(format.rawFileExtension)"
                    )
                ))
                artifactPlans.append((
                    format,
                    .enhancementLayer,
                    outputDirectoryURL.appendingPathComponent(
                        "\(prefix)_\(format.rawValue)_el.\(format.rawFileExtension)"
                    )
                ))
            } else {
                artifactPlans.append((
                    format,
                    .primary,
                    outputDirectoryURL.appendingPathComponent(
                        "\(prefix)_\(format.rawValue).\(format.rawFileExtension)"
                    )
                ))
            }
        }

        if !options.overwriteExisting,
           let existing = artifactPlans.first(where: {
               fileManager.fileExists(atPath: $0.finalURL.path)
           }) {
            throw ProResEncoderError.invalidOption(
                "Elementary-stream output already exists: \(existing.finalURL.path)"
            )
        }

        let stagingRoot = outputDirectoryURL.appendingPathComponent(
            ".prores-elementary-\(UUID().uuidString)",
            isDirectory: true
        )
        let readyDirectory = stagingRoot.appendingPathComponent("ready", isDirectory: true)
        let backupDirectory = stagingRoot.appendingPathComponent("backup", isDirectory: true)
        try fileManager.createDirectory(
            at: readyDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }

        var stagedArtifacts: [(
            artifact: ProResElementaryStreamArtifact,
            stagedURL: URL
        )] = []
        for (index, format) in options.formats.enumerated() {
            let temporaryContainerURL = stagingRoot.appendingPathComponent(
                String(format: "%02d_%@.mov", index, format.rawValue)
            )
            let bitrate: Double?
            switch format.quality {
            case "hevc":
                bitrate = format == .dolbyVisionProfile76
                    ? options.profile76BitrateMbps
                    : options.hevcBitrateMbps
            case "av1":
                bitrate = options.av1BitrateMbps
            default:
                bitrate = nil
            }

            let colorConversion: ProResColorConversion?
            switch format {
            case .dolbyVisionProfile5, .dolbyVisionProfile10:
                colorConversion = ProResColorConversion(
                    gamut: options.dolbyVisionGamut,
                    transferFunction: .pq,
                    targetPeakNits: options.targetPeakNits
                )
            case .dolbyVisionProfile84, .dolbyVisionProfile104:
                colorConversion = ProResColorConversion(
                    gamut: options.dolbyVisionGamut,
                    transferFunction: .hlg,
                    targetPeakNits: options.targetPeakNits
                )
            case .dolbyVisionProfile76,
                 .dolbyVisionProfile81,
                 .dolbyVisionProfile101:
                colorConversion = nil
            default:
                colorConversion = options.baseColorConversion
            }

            print(
                "[Framework Raw Batch] Encoding \(format.rawValue) (\(index + 1)/\(options.formats.count))."
            )
            let encodeOptions = ProResEncodeOptions(
                quality: format.quality,
                deleteSourceAudio: true,
                dolbyVisionXMLURL: format.dolbyVisionProfile == nil
                    ? nil
                    : options.dolbyVisionXMLURL,
                bitrateMbps: bitrate,
                dolbyVisionProfile: format.dolbyVisionProfile,
                colorConversion: colorConversion,
                useDolbyVisionCodecTag: format.dolbyVisionProfile != nil,
                outputVideoRaw: true
            )
            _ = try await encode(
                inputURL: inputURL,
                outputURL: temporaryContainerURL,
                format: .mov,
                options: encodeOptions
            )

            let internalProfile = format.dolbyVisionProfile.flatMap {
                DolbyVisionHEVCProfile(argument: $0.rawValue)
            }
            let rawURLs = EncodedVideoRawOutput.outputURLs(
                for: temporaryContainerURL,
                quality: format.quality,
                profile: internalProfile
            )
            let matchingPlans = artifactPlans.filter { $0.format == format }
            guard rawURLs.count == matchingPlans.count else {
                throw ProResEncoderError.encodingFailed(
                    "Raw artifact count mismatch for \(format.rawValue)."
                )
            }
            for (rawURL, plan) in zip(rawURLs, matchingPlans) {
                guard fileManager.fileExists(atPath: rawURL.path),
                      (try rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0
                else {
                    throw ProResEncoderError.encodingFailed(
                        "Encoder did not produce a non-empty raw stream for \(format.rawValue)."
                    )
                }
                let stagedURL = readyDirectory.appendingPathComponent(
                    plan.finalURL.lastPathComponent
                )
                try fileManager.moveItem(at: rawURL, to: stagedURL)
                stagedArtifacts.append((
                    ProResElementaryStreamArtifact(
                        format: plan.format,
                        layer: plan.layer,
                        url: plan.finalURL
                    ),
                    stagedURL
                ))
            }
            try? fileManager.removeItem(at: temporaryContainerURL)
        }

        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        var committedURLs: [URL] = []
        var backups: [(original: URL, backup: URL)] = []
        do {
            for staged in stagedArtifacts {
                let finalURL = staged.artifact.url
                if fileManager.fileExists(atPath: finalURL.path) {
                    let backupURL = backupDirectory.appendingPathComponent(
                        finalURL.lastPathComponent
                    )
                    try fileManager.moveItem(at: finalURL, to: backupURL)
                    backups.append((finalURL, backupURL))
                }
                try fileManager.moveItem(at: staged.stagedURL, to: finalURL)
                committedURLs.append(finalURL)
            }
        } catch {
            for url in committedURLs.reversed() {
                try? fileManager.removeItem(at: url)
            }
            for backup in backups.reversed() {
                if !fileManager.fileExists(atPath: backup.original.path) {
                    try? fileManager.moveItem(
                        at: backup.backup,
                        to: backup.original
                    )
                }
            }
            throw ProResEncoderError.encodingFailed(
                "Could not commit the elementary-stream batch: \(error.localizedDescription)"
            )
        }

        return ProResElementaryStreamResult(
            artifacts: stagedArtifacts.map(\.artifact)
        )
    }

    /// Encodes supported media files in a folder and optionally writes a sequence AAF.
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
            if format == .mov || format == .mp4 {
                outputURL = outputDirectoryURL.appendingPathComponent(
                    inputURL.deletingPathExtension().lastPathComponent + ".\(format.rawValue)"
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
            guard format != .mov && format != .mp4 else {
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

    /// Parses and encodes a linked AAF or XML timeline to a MOV output.
    public func encodeTimeline(
        inputTimelineURL: URL,
        outputURL: URL,
        mediaSearchURLs: [URL] = [],
        options: ProResEncodeOptions = ProResEncodeOptions()
    ) async throws -> ProResEncodeResult {
        guard FileManager.default.fileExists(atPath: inputTimelineURL.path) else {
            throw ProResEncoderError.inputNotFound(inputTimelineURL.path)
        }
        if let lutURL = options.lutColorConversion?.lutURL,
           !FileManager.default.fileExists(atPath: lutURL.path) {
            throw ProResEncoderError.auxiliaryFileNotFound(lutURL.path)
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
        let colorTransform = try options.makeColorTransformRequest()
        if colorTransform?.hasLUT == true, options.includeGeneratedDolbyVisionMetadata {
            throw ProResEncoderError.invalidOption(
                "LUT burn-in cannot be combined with generated Dolby Vision metadata. Generate metadata from the graded output in a separate workflow."
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

    /// Converts a timeline document without encoding its linked media.
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

    /// Parses the requested timeline format into the common descriptor model.
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

    /// Runs the MOV pipeline and post-encode metadata workflow for one asset.
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
                dolbyVisionProfile: options.dolbyVisionProfile.flatMap {
                    DolbyVisionHEVCProfile(argument: $0.rawValue)
                },
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
        let hevcOptions = (isHEVCQuality(quality) || isH264Quality(quality))
            ? HEVCEncodeOptions(
                bitrateMbps: options.bitrateMbps ?? 0,
                dvProfile: isH264Quality(quality) ? nil : internalProfile,
                bFrames: options.bFrames,
                multiPass: options.multiPass
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
                dolbyVisionProfile: internalProfile,
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
            dolbyVisionLevel4Measurements: generatedCMUArtifacts?.level4Measurements,
            hevcOptions: hevcOptions,
            av1Options: av1Options,
            colorSpace: sourceColorSpace,
            fpsInfo: await framerateInfo(from: asset),
            colorTransform: colorTransform,
            useDolbyVisionCodecTag: options.useDolbyVisionCodecTag,
            container: outputURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov,
            outputVideoRaw: options.outputVideoRaw
        )
        guard success else {
            throw ProResEncoderError.encodingFailed(
                "Container encoding failed for \(inputURL.lastPathComponent)."
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
        if options.outputVideoRaw {
            outputURLs.append(contentsOf: EncodedVideoRawOutput.outputURLs(
                for: outputURL,
                quality: quality,
                profile: internalProfile
            ))
        }
        return ProResEncodeResult(
            outputURLs: outputURLs,
            cmuXMLURL: isCompressedOutput ? nil : generatedCMUArtifacts?.xmlURL
        )
    }

    /// Runs OP-1a or OP-Atom encoding and creates requested linked AAF files.
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
            colorTransform: colorTransform,
            outputVideoRaw: options.outputVideoRaw
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

    /// Maps encoded MXF outputs and source media properties to an AAF clip record.
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
