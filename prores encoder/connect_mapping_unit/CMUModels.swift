import Foundation
@preconcurrency import AVFoundation
import CoreMedia

enum CMUError: LocalizedError {
    case invalidMasteringBrightness(String)
    case noVideoTrack(URL)
    case unreadableFormatDescription(URL)
    case unsupportedColorSpace(String)
    case metalUnavailable
    case commandQueueUnavailable
    case metalLibraryUnavailable
    case metalFunctionUnavailable(String)
    case bufferAllocationFailed
    case readerOutputUnavailable
    case readerStartFailed(String)
    case readerFailed(String)
    case noDecodedFrames
    case unsupportedPixelBuffer(OSType)
    case textureCreationFailed(String, CVReturn)
    case commandEncodingFailed
    case commandExecutionFailed(String)
    case invalidTimecode(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidMasteringBrightness(let value):
            return "--cmu must be followed by a finite mastering brightness from 1 through 10000 nits; found '\(value)'."
        case .noVideoTrack(let url):
            return "CMU analysis found no video track in \(url.path)."
        case .unreadableFormatDescription(let url):
            return "CMU analysis could not read the video format description in \(url.path)."
        case .unsupportedColorSpace(let detail):
            return "CMU analysis supports only P3-D65 PQ or Rec.2020 PQ. \(detail)"
        case .metalUnavailable:
            return "CMU analysis requires Metal, but no Metal device is available. CPU fallback is prohibited."
        case .commandQueueUnavailable:
            return "CMU analysis could not create a Metal command queue."
        case .metalLibraryUnavailable:
            return "CMU analysis could not load the compiled CMU Metal kernels."
        case .metalFunctionUnavailable(let name):
            return "CMU Metal kernel '\(name)' is missing."
        case .bufferAllocationFailed:
            return "CMU analysis could not allocate its Metal statistics buffers."
        case .readerOutputUnavailable:
            return "CMU analysis could not add a Metal-compatible 10-bit video output to AVAssetReader."
        case .readerStartFailed(let detail):
            return "CMU AVAssetReader could not start: \(detail)"
        case .readerFailed(let detail):
            return "CMU AVAssetReader failed: \(detail)"
        case .noDecodedFrames:
            return "CMU analysis decoded no video frames."
        case .unsupportedPixelBuffer(let format):
            return "CMU analysis requires a Metal-compatible 10-bit bi-planar pixel buffer; found \(cmuFourCC(format))."
        case .textureCreationFailed(let plane, let status):
            return "CMU analysis could not bind the \(plane) plane to Metal: \(status). CPU fallback is prohibited."
        case .commandEncodingFailed:
            return "CMU analysis could not encode a Metal command buffer."
        case .commandExecutionFailed(let detail):
            return "CMU Metal analysis failed: \(detail)"
        case .invalidTimecode(let value):
            return "CMU could not parse timecode '\(value)'."
        case .exportFailed(let detail):
            return "CMU metadata export failed: \(detail)"
        }
    }
}

enum CMUPrimaries: String, Codable, Sendable {
    case p3D65 = "p3d65"
    case rec2020 = "rec2020"

    var displayName: String {
        switch self {
        case .p3D65: return "P3-D65"
        case .rec2020: return "BT.2020"
        }
    }

    var gamut: VideoGamut {
        switch self {
        case .p3D65: return .p3D65
        case .rec2020: return .rec2020
        }
    }

    var red: String {
        switch self {
        case .p3D65: return "0.68 0.32"
        case .rec2020: return "0.708 0.292"
        }
    }

    var green: String {
        switch self {
        case .p3D65: return "0.265 0.69"
        case .rec2020: return "0.17 0.797"
        }
    }

    var blue: String {
        switch self {
        case .p3D65: return "0.15 0.06"
        case .rec2020: return "0.131 0.046"
        }
    }

    var primaryList: String {
        "\(red) \(green) \(blue) 0.3127 0.329"
    }
}

enum CMUSignalRange: String, Codable, Sendable {
    case full
    case video

    var xmlValue: String {
        self == .full ? "computer" : "video"
    }

    var pixelFormat: OSType {
        self == .full
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
}

enum CMUAnalysisSource: String, Codable, Sendable {
    case input
    case output
}

struct CMURational: Codable, Sendable {
    let numerator: Int
    let denominator: Int

    var fps: Double {
        Double(numerator) / Double(denominator)
    }

    var xmlValue: String {
        "\(numerator) \(denominator)"
    }
}

struct CMUAssetDescriptor: Codable, Sendable {
    let path: String
    let fileName: String
    let width: Int
    let height: Int
    let editRate: CMURational
    let codec: String
    let primaries: CMUPrimaries
    let signalRange: CMUSignalRange
    let matrix: String
    let taggedDurationSeconds: Double

    var isEligible: Bool { true }

    static func inspect(url: URL) async throws -> CMUAssetDescriptor {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CMUError.noVideoTrack(url)
        }
        guard let format = try await track.load(.formatDescriptions).first else {
            throw CMUError.unreadableFormatDescription(url)
        }

        let primariesTag = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        ) as? String
        let transferTag = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String
        let matrixTag = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix
        ) as? String

        guard transferTag == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) else {
            throw CMUError.unsupportedColorSpace(
                "\(url.lastPathComponent) transfer is \(transferTag ?? "untagged"), not PQ/ST 2084."
            )
        }

        let primaries: CMUPrimaries
        if primariesTag == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) {
            primaries = .p3D65
        } else if primariesTag == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
            primaries = .rec2020
        } else {
            throw CMUError.unsupportedColorSpace(
                "\(url.lastPathComponent) primaries are \(primariesTag ?? "untagged")."
            )
        }

        let fullRangeValue = CMFormatDescriptionGetExtension(
            format,
            extensionKey: kCMFormatDescriptionExtension_FullRangeVideo
        )
        let isFullRange: Bool
        if let number = fullRangeValue as? NSNumber {
            isFullRange = number.boolValue
        } else {
            isFullRange = matrixTag == nil
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let duration = try await asset.load(.duration)
        let frameRate = await cmuEditRate(asset: asset, track: track)
        let codec = cmuFourCC(CMFormatDescriptionGetMediaSubType(format))

        return CMUAssetDescriptor(
            path: url.path,
            fileName: url.lastPathComponent,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            editRate: frameRate,
            codec: codec,
            primaries: primaries,
            signalRange: isFullRange ? .full : .video,
            matrix: matrixTag ?? "rgb",
            taggedDurationSeconds: duration.isNumeric ? duration.seconds : 0
        )
    }
}

struct CMUFrameStats: Codable, Sendable {
    let frameIndex: Int64
    let ptsSeconds: Double
    let maxRGBNits: Float
    let maxLumaNits: Float
    let minLumaNits: Float
    let avgLumaNits: Float
    let percentile01: Float
    let percentile10: Float
    let percentile50: Float
    let percentile90: Float
    let percentile99: Float
    let percentile999: Float
    let avgR: Float
    let avgG: Float
    let avgB: Float
    let avgSaturation: Float
}

struct CMULevel1Like: Codable, Sendable {
    let min: Float
    let mid: Float
    let max: Float
}

struct CMUTimecodeReference: Codable, Sendable {
    enum Origin: String, Codable, Sendable {
        case quickTime = "quicktime"
        case ffoa
        case zero
    }

    let startFrame: Int64
    let stringValue: String
    let isDropFrame: Bool
    let origin: Origin
}

struct CMUAnalysisDocument: Codable, Sendable {
    let schemaVersion: String
    let generatedAtUTC: String
    let author: String
    let software: String
    let softwareVersion: String
    let analysisSource: CMUAnalysisSource
    let media: CMUAssetDescriptor
    let masteringPeakNits: Float
    let timecode: CMUTimecodeReference
    let durationFrames: Int64
    let durationSeconds: Double
    let recordIn: Int64
    let recordOut: Int64
    let maxCLL: Int
    let maxFALL: Int
    let level1Like: CMULevel1Like
    let outputID: UUID
    let trackID: UUID
    let shotID: UUID
    let frames: [CMUFrameStats]
}

struct CMUOutputArtifacts: Sendable {
    let xmlURL: URL
}

func cmuParseMasteringBrightness(_ value: String) throws -> Float {
    guard let parsed = Float(value),
          parsed.isFinite,
          parsed >= 1,
          parsed <= 10_000 else {
        throw CMUError.invalidMasteringBrightness(value)
    }
    return parsed
}

func cmuFourCC(_ code: OSType) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

private func cmuEditRate(asset: AVAsset, track: AVAssetTrack) async -> CMURational {
    if let minDuration = try? await track.load(.minFrameDuration),
       minDuration.isNumeric,
       minDuration.value > 0,
       minDuration.timescale > 0 {
        let divisor = cmuGCD(Int(minDuration.timescale), Int(minDuration.value))
        return CMURational(
            numerator: Int(minDuration.timescale) / divisor,
            denominator: Int(minDuration.value) / divisor
        )
    }

    let fallback = await framerateInfo(from: asset)
    return CMURational(numerator: fallback.numerator, denominator: fallback.denominator)
}

private func cmuGCD(_ lhs: Int, _ rhs: Int) -> Int {
    var a = abs(lhs)
    var b = abs(rhs)
    while b != 0 {
        let remainder = a % b
        a = b
        b = remainder
    }
    return max(a, 1)
}
