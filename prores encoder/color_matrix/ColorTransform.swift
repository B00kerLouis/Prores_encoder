import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import simd

enum ColorTransformError: LocalizedError {
    case incompleteArguments
    case invalidGamut(String)
    case invalidOETF(String)
    case invalidTargetNits(String)
    case unsupportedSourcePrimaries(String?)
    case unsupportedSourceTransfer(String?)
    case inconsistentTimelineColor
    case noTimelineVideoSource
    case passthroughNotSupported
    case dolbyVisionNotSupported

    var errorDescription: String? {
        switch self {
        case .incompleteArguments:
            return "--gamunt, --oetf, and --nit must be specified together. Encoding was refused."
        case .invalidGamut(let value):
            return "Unsupported --gamunt '\(value)'. Use rec709, rec2020, rec2020lm, or p3d65."
        case .invalidOETF(let value):
            return "Unsupported --oetf '\(value)'. Use gamma2.4, gamma2.6, pq, or hlg."
        case .invalidTargetNits(let value):
            return "--nit must be a finite number from 1 through 10000; found '\(value)'."
        case .unsupportedSourcePrimaries(let value):
            return "Metal color conversion requires source primaries tagged as Rec.709, Rec.2020, or P3-D65; found \(value ?? "missing metadata")."
        case .unsupportedSourceTransfer(let value):
            return "Metal color conversion requires source transfer metadata for Gamma 2.4/BT.709, Gamma 2.6/ST 428-1, PQ, or HLG; found \(value ?? "missing metadata")."
        case .inconsistentTimelineColor:
            return "Timeline color conversion requires every source video clip to use the same tagged gamut and transfer function."
        case .noTimelineVideoSource:
            return "Timeline color conversion could not find a readable source video clip."
        case .passthroughNotSupported:
            return "Color conversion changes pixels and cannot be combined with -q pass."
        case .dolbyVisionNotSupported:
            return "Color conversion cannot be combined with Dolby Vision metadata/RPU because the source Dolby Vision trim no longer describes the transformed pixels."
        }
    }
}

enum VideoGamut: UInt32, Sendable {
    case rec709 = 0
    case rec2020 = 1
    case p3D65 = 2
    case rec2020LimitedToP3D65 = 3

    init(argument: String) throws {
        switch argument.lowercased().replacingOccurrences(of: "-", with: "") {
        case "rec709", "bt709", "709":
            self = .rec709
        case "rec2020", "bt2020", "2020":
            self = .rec2020
        case "rec2020lm", "bt2020lm", "2020lm":
            self = .rec2020LimitedToP3D65
        case "p3d65", "displayp3":
            self = .p3D65
        default:
            throw ColorTransformError.invalidGamut(argument)
        }
    }

    var label: String {
        switch self {
        case .rec709: return "Rec.709"
        case .rec2020: return "Rec.2020"
        case .p3D65: return "P3-D65"
        case .rec2020LimitedToP3D65: return "Rec.2020 (P3-D65 limited)"
        }
    }

    var colorPrimaries: String {
        switch self {
        case .rec709:
            return kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        case .rec2020, .rec2020LimitedToP3D65:
            return kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        case .p3D65:
            return kCMFormatDescriptionColorPrimaries_P3_D65 as String
        }
    }

    var yCbCrMatrix: String {
        switch self {
        case .rec709:
            return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
        case .rec2020, .rec2020LimitedToP3D65, .p3D65:
            return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String
        }
    }

    var matrixID: UInt32 {
        self == .rec709 ? 0 : 1
    }

    var lumaCoefficients: SIMD4<Float> {
        switch self {
        case .rec709:
            return SIMD4(0.21263901, 0.71516868, 0.07219232, 0)
        case .rec2020, .rec2020LimitedToP3D65:
            return SIMD4(0.26270021, 0.67799807, 0.05930172, 0)
        case .p3D65:
            return SIMD4(0.22897456, 0.69173852, 0.07928691, 0)
        }
    }

    var mxfPrimaries: Data {
        switch self {
        case .rec709: return MXFColorUL.primariesBT709
        case .rec2020, .rec2020LimitedToP3D65: return MXFColorUL.primariesBT2020
        case .p3D65: return MXFColorUL.primariesP3D65
        }
    }

    var av1CICP: Int32 {
        switch self {
        case .rec709: return 1
        case .rec2020, .rec2020LimitedToP3D65: return 9
        case .p3D65: return 12
        }
    }

    var gamutLimitMode: UInt32 {
        self == .rec2020LimitedToP3D65 ? 1 : 0
    }

    var isRec2020Encoding: Bool {
        self == .rec2020 || self == .rec2020LimitedToP3D65
    }
}

enum VideoOETF: UInt32, Sendable {
    case gamma24 = 0
    case gamma26 = 1
    case pq = 2
    case hlg = 3

    init(argument: String) throws {
        let normalized = argument.lowercased().replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "gamma2.4", "gamma24", "g24", "bt1886":
            self = .gamma24
        case "gamma2.6", "gamma26", "g26":
            self = .gamma26
        case "pq", "st2084", "smpte2084":
            self = .pq
        case "hlg", "bt2100hlg":
            self = .hlg
        default:
            throw ColorTransformError.invalidOETF(argument)
        }
    }

    var label: String {
        switch self {
        case .gamma24: return "Gamma 2.4"
        case .gamma26: return "Gamma 2.6"
        case .pq: return "PQ"
        case .hlg: return "HLG"
        }
    }

    var transferFunction: String {
        switch self {
        case .gamma24:
            return kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String
        case .gamma26:
            return kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1 as String
        case .pq:
            return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        case .hlg:
            return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        }
    }

    var mxfTransfer: Data {
        switch self {
        case .gamma24: return MXFColorUL.transferBT709
        case .gamma26: return MXFColorUL.transferST428
        case .pq: return MXFColorUL.transferST2084
        case .hlg: return MXFColorUL.transferHLG
        }
    }

    var av1CICP: Int32 {
        switch self {
        case .gamma24: return 1
        case .gamma26: return 17
        case .pq: return 16
        case .hlg: return 18
        }
    }
}

struct ColorTransformRequest: Sendable {
    let outputGamut: VideoGamut
    let outputOETF: VideoOETF
    let targetNits: Float

    init(gamut: String, oetf: String, nits: String) throws {
        outputGamut = try VideoGamut(argument: gamut)
        outputOETF = try VideoOETF(argument: oetf)
        guard let parsed = Float(nits), parsed.isFinite, parsed >= 1, parsed <= 10_000 else {
            throw ColorTransformError.invalidTargetNits(nits)
        }
        targetNits = parsed
    }

    var label: String {
        "\(outputGamut.label) / \(outputOETF.label) / \(String(format: "%.1f", targetNits)) nits"
    }

    var isDolbyVisionHLGCompatible: Bool {
        outputOETF == .hlg
            && (outputGamut == .rec2020
                || outputGamut == .rec2020LimitedToP3D65
                || outputGamut == .p3D65)
    }
}

struct SourceColorProfile: Sendable, Equatable {
    let gamut: VideoGamut
    let oetf: VideoOETF
    let yCbCrMatrixID: UInt32
    let peakNits: Float
}

struct ResolvedColorTransform: Sendable {
    let input: SourceColorProfile
    let outputGamut: VideoGamut
    let outputOETF: VideoOETF
    let targetNits: Float
    let matrixColumns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    init(input: SourceColorProfile, request: ColorTransformRequest) {
        self.input = input
        outputGamut = request.outputGamut
        outputOETF = request.outputOETF
        targetNits = request.targetNits
        matrixColumns = Self.conversionMatrix(from: input.gamut, to: request.outputGamut)
    }

    var outputColorSpace: SourceColorSpace {
        SourceColorSpace(
            primaries: outputGamut.colorPrimaries,
            transfer: outputOETF.transferFunction,
            matrix: outputGamut.yCbCrMatrix,
            masteringDisplayColorVolume: nil,
            contentLightLevelInfo: nil,
            mxfPrimaries: outputGamut.mxfPrimaries,
            mxfTransfer: outputOETF.mxfTransfer,
            mxfMatrix: outputGamut == .rec709 ? MXFColorUL.matrixBT709 : MXFColorUL.matrixBT2020
        )
    }

    var av1MatrixCICP: Int32 {
        outputGamut == .rec709 ? 1 : 9
    }

    private static func conversionMatrix(
        from source: VideoGamut,
        to destination: VideoGamut
    ) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        let sourceToXYZ = rgbToXYZ(source)
        let destinationToXYZ = rgbToXYZ(destination)
        let matrix = simd_inverse(destinationToXYZ) * sourceToXYZ
        return (
            SIMD4(matrix.columns.0, 0),
            SIMD4(matrix.columns.1, 0),
            SIMD4(matrix.columns.2, 0)
        )
    }

    // Same D65 chromaticities used by OpenColorIO ColorMatrixHelpers.cpp.
    private static func rgbToXYZ(_ gamut: VideoGamut) -> simd_float3x3 {
        switch gamut {
        case .rec709:
            return simd_float3x3(rows: [
                SIMD3(0.41239080, 0.35758434, 0.18048079),
                SIMD3(0.21263901, 0.71516868, 0.07219232),
                SIMD3(0.01933082, 0.11919478, 0.95053215)
            ])
        case .rec2020, .rec2020LimitedToP3D65:
            return simd_float3x3(rows: [
                SIMD3(0.63695805, 0.14461690, 0.16888098),
                SIMD3(0.26270021, 0.67799807, 0.05930172),
                SIMD3(0.00000000, 0.02807269, 1.06098506)
            ])
        case .p3D65:
            return simd_float3x3(rows: [
                SIMD3(0.48657095, 0.26566769, 0.19821729),
                SIMD3(0.22897456, 0.69173852, 0.07928691),
                SIMD3(0.00000000, 0.04511338, 1.04394437)
            ])
        }
    }
}

func resolveSourceColorProfile(from colorSpace: SourceColorSpace) throws -> SourceColorProfile {
    let gamut: VideoGamut
    if colorSpace.primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) {
        gamut = .rec709
    } else if colorSpace.primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
        gamut = .rec2020
    } else if colorSpace.primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) {
        gamut = .p3D65
    } else {
        throw ColorTransformError.unsupportedSourcePrimaries(colorSpace.primaries)
    }

    let oetf: VideoOETF
    if colorSpace.transfer == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String) {
        oetf = .gamma24
    } else if colorSpace.transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1 as String) {
        oetf = .gamma26
    } else if colorSpace.transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
        oetf = .pq
    } else if colorSpace.transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
        oetf = .hlg
    } else {
        throw ColorTransformError.unsupportedSourceTransfer(colorSpace.transfer)
    }

    let matrixID: UInt32
    if colorSpace.matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String) {
        matrixID = 0
    } else if colorSpace.matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) {
        matrixID = 1
    } else {
        matrixID = gamut.matrixID
    }

    return SourceColorProfile(
        gamut: gamut,
        oetf: oetf,
        yCbCrMatrixID: matrixID,
        peakNits: detectedSourcePeakNits(colorSpace: colorSpace, oetf: oetf)
    )
}

func resolveColorTransform(
    request: ColorTransformRequest,
    sourceColorSpace: SourceColorSpace
) throws -> ResolvedColorTransform {
    ResolvedColorTransform(
        input: try resolveSourceColorProfile(from: sourceColorSpace),
        request: request
    )
}

func resolveTimelineColorTransform(
    request: ColorTransformRequest,
    descriptor: TimelineDescriptor
) async throws -> ResolvedColorTransform {
    let sourceURLs = Array(Set(
        descriptor.clips
            .filter { $0.mediaType == .video }
            .map(\.sourceURL)
    ))
    guard !sourceURLs.isEmpty else {
        throw ColorTransformError.noTimelineVideoSource
    }

    var commonProfile: SourceColorProfile?
    var peakNits: Float = 0
    for url in sourceURLs {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ColorTransformError.noTimelineVideoSource
        }
        let profile = try resolveSourceColorProfile(from: await detectColorSpace(from: track))
        if let commonProfile,
           commonProfile.gamut != profile.gamut
            || commonProfile.oetf != profile.oetf
            || commonProfile.yCbCrMatrixID != profile.yCbCrMatrixID {
            throw ColorTransformError.inconsistentTimelineColor
        }
        commonProfile = profile
        peakNits = max(peakNits, profile.peakNits)
    }

    guard let commonProfile else {
        throw ColorTransformError.noTimelineVideoSource
    }
    let merged = SourceColorProfile(
        gamut: commonProfile.gamut,
        oetf: commonProfile.oetf,
        yCbCrMatrixID: commonProfile.yCbCrMatrixID,
        peakNits: peakNits
    )
    return ResolvedColorTransform(input: merged, request: request)
}

func colorPipelinePixelFormat(for quality: String) -> OSType {
    if isCompressedHDRQuality(quality) {
        return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
    if is4444FamilyQuality(quality) {
        return kCVPixelFormatType_32BGRA
    }
    return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
}

private func detectedSourcePeakNits(colorSpace: SourceColorSpace, oetf: VideoOETF) -> Float {
    // The display mastering peak defines the source mastering range used by
    // the EETF. MaxCLL describes measured content and can legitimately exceed
    // that range, so it is only a fallback when mastering metadata is absent.
    if let mastering = colorSpace.masteringDisplayColorVolume,
       mastering.count >= 20 {
        let raw = mastering.withUnsafeBytes { bytes -> UInt32 in
            let p = bytes.bindMemory(to: UInt8.self)
            return (UInt32(p[16]) << 24)
                | (UInt32(p[17]) << 16)
                | (UInt32(p[18]) << 8)
                | UInt32(p[19])
        }
        if raw > 0 {
            return Float(raw) / 10_000.0
        }
    }

    if let contentLight = colorSpace.contentLightLevelInfo,
       contentLight.count >= 2 {
        let maxCLL = contentLight.withUnsafeBytes { bytes -> UInt16 in
            let p = bytes.bindMemory(to: UInt8.self)
            return (UInt16(p[0]) << 8) | UInt16(p[1])
        }
        if maxCLL > 0 {
            return Float(maxCLL)
        }
    }

    switch oetf {
    case .gamma24: return 100
    case .gamma26: return 48
    case .pq, .hlg: return 1_000
    }
}
