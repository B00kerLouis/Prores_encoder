// Encodes ProRes video, extracts MXF audio, propagates color metadata, and
// provides source-media analysis helpers. Samples are processed incrementally.

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox

private let kCMVideoCodecType_AppleProRes4444XQ: CMVideoCodecType = 0x61703478 // 'ap4x'

// MARK: - MXF Color UL Constants (SMPTE 377-1)
// Values mirror the identifiers declared by the MXF encoder interface.

enum MXFColorUL {
    static let primariesBT709:  Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x06,
                                              0x04,0x01,0x01,0x01,0x03,0x03,0x00,0x00])
    static let primariesBT2020: Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,
                                              0x04,0x01,0x01,0x01,0x03,0x03,0x00,0x00])
    static let primariesP3D65:  Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,
                                              0x04,0x01,0x01,0x01,0x03,0x06,0x00,0x00])
    static let transferBT709:   Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x01,
                                              0x04,0x01,0x01,0x01,0x01,0x02,0x00,0x00])
    static let transferST2084:  Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,
                                              0x04,0x01,0x01,0x01,0x01,0x08,0x00,0x00])
    static let transferHLG:     Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,
                                              0x04,0x01,0x01,0x01,0x01,0x0e,0x00,0x00])
    static let transferST428:   Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,
                                              0x04,0x01,0x01,0x01,0x01,0x0b,0x00,0x00])
    static let transferLinear:  Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,
                                              0x04,0x01,0x01,0x01,0x01,0x09,0x00,0x00])
    static let matrixBT709:     Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x01,
                                              0x04,0x01,0x01,0x01,0x02,0x02,0x00,0x00])
    static let matrixBT2020:    Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,
                                              0x04,0x01,0x01,0x01,0x02,0x06,0x00,0x00])
    static let matrixSMPTE240M: Data = .init([0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x0d,
                                              0x04,0x01,0x01,0x01,0x02,0x03,0x00,0x00])
}

// MARK: - SourceColorSpace

struct SourceColorSpace: Sendable {
    /// CoreMedia string keys (for VT session config)
    let primaries: String?
    let transfer:  String?
    let matrix:    String?
    let masteringDisplayColorVolume: Data?
    let contentLightLevelInfo: Data?
    /// 16-byte SMPTE UL data (for MXFBridge)
    let mxfPrimaries: Data?
    let mxfTransfer:  Data?
    let mxfMatrix:    Data?

    /// Returns an HDR10 profile while preserving valid mastering/light metadata.
    static func hevcHDR10(
        basedOn source: SourceColorSpace?,
        masteringDisplayColorVolume fallbackMasteringDisplay: Data? = nil,
        contentLightLevelInfo fallbackContentLight: Data? = nil
    ) -> SourceColorSpace {
        SourceColorSpace(
            primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
            matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String,
            masteringDisplayColorVolume: source?.masteringDisplayColorVolume ?? fallbackMasteringDisplay,
            contentLightLevelInfo: source?.contentLightLevelInfo ?? fallbackContentLight,
            mxfPrimaries: MXFColorUL.primariesBT2020,
            mxfTransfer: MXFColorUL.transferST2084,
            mxfMatrix: MXFColorUL.matrixBT2020
        )
    }
}

/// Supported dynamic HDR profile families and their bitstream signaling values.
enum DolbyVisionHEVCProfile: String, Sendable {
    case profile5 = "5"
    case profile76 = "76"
    case profile81 = "81"
    case profile84 = "84"
    case profile10 = "10"
    case profile101 = "101"
    case profile104 = "104"

    init?(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "5":
            self = .profile5
        case "76":
            self = .profile76
        case "81":
            self = .profile81
        case "84":
            self = .profile84
        case "10":
            self = .profile10
        case "101":
            self = .profile101
        case "104":
            self = .profile104
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .profile5: return "5"
        case .profile76: return "7.6"
        case .profile81: return "8.1"
        case .profile84: return "8.4"
        case .profile10: return "10"
        case .profile101: return "10.1"
        case .profile104: return "10.4"
        }
    }

    var usesProfile84Mapping: Bool {
        self == .profile84 || self == .profile104
    }

    var isProfile76: Bool {
        self == .profile76
    }

    var usesNativeIPT: Bool {
        self == .profile5 || self == .profile10
    }

    var usesDVCConfigurationBox: Bool {
        self == .profile5 || self == .profile76
    }

    var usesHLGBaseLayer: Bool {
        usesProfile84Mapping
    }

    var isHEVCProfile: Bool {
        self == .profile5 || self == .profile76 || self == .profile81 || self == .profile84
    }

    var isAV1Profile: Bool {
        self == .profile10 || self == .profile101 || self == .profile104
    }

    var containerProfile: UInt8 {
        if self == .profile5 {
            return 5
        }
        if isProfile76 {
            return 7
        }
        return isAV1Profile ? 10 : 8
    }

    var compatibilityID: UInt8 {
        if usesNativeIPT {
            return 0
        }
        if isProfile76 {
            return 6
        }
        return usesHLGBaseLayer ? 4 : 1
    }

    var applicationID: UInt8 {
        compatibilityID
    }

    var extendedMappingIDC: UInt8 {
        if usesNativeIPT {
            return 0
        }
        if isProfile76 {
            // Profile 7.6: Application ID / CCID 6, inverse mapping indicator 0.
            return UInt8(6 << 5) // 192
        }

        let inverseMappingIDC: UInt8 = usesHLGBaseLayer ? 0 : 1
        return (applicationID << 5) | inverseMappingIDC
    }
}

enum VideoBitrateMode: String, Sendable {
    case vbr
    case cbr
}

/// H.264/HEVC encoder bitrate, GOP, and optional dynamic HDR profile.
struct HEVCEncodeOptions: Sendable {
    /// Upper bound on VideoToolbox analysis passes. The encoder may stop earlier.
    static let maximumCompressionPasses = 8

    let bitrateMbps: Double
    let dvProfile: DolbyVisionHEVCProfile?
    let keyFrameIntervalSeconds: Int
    let allIntra: Bool
    let bFrames: Bool
    let bitrateMode: VideoBitrateMode
    let multiPass: Bool

    init(
        bitrateMbps: Double,
        dvProfile: DolbyVisionHEVCProfile?,
        keyFrameIntervalSeconds: Int = 2,
        allIntra: Bool = false,
        bFrames: Bool? = nil,
        bitrateMode: VideoBitrateMode = .vbr,
        multiPass: Bool? = nil
    ) {
        self.bitrateMbps = bitrateMbps
        self.dvProfile = dvProfile
        self.keyFrameIntervalSeconds = keyFrameIntervalSeconds
        self.allIntra = allIntra
        self.bFrames = resolvedHEVCBFrames(explicit: bFrames, allIntra: allIntra)
        self.bitrateMode = bitrateMode
        self.multiPass = resolvedHEVCMultiPass(explicit: multiPass, allIntra: allIntra)
    }

    var bitrateBitsPerSecond: Int {
        Int((bitrateMbps * 1_000_000.0).rounded())
    }
}

/// GOP H.264/HEVC uses multi-pass by default; all-intra turns it off unless forced on.
func resolvedHEVCMultiPass(explicit: Bool?, allIntra: Bool) -> Bool {
    explicit ?? !allIntra
}

/// GOP H.264/HEVC uses B-frames by default; all-intra and `--b-frames off` turn them off.
func resolvedHEVCBFrames(explicit: Bool?, allIntra: Bool) -> Bool {
    if allIntra { return false }
    return explicit ?? true
}

/// Returns whether a requested bitrate can be represented by the selected encoder API.
func encodedVideoBitrateIsRepresentable(_ bitrateMbps: Double, usesAV1: Bool) -> Bool {
    guard bitrateMbps.isFinite, bitrateMbps > 0 else { return false }
    let bitsPerSecond = bitrateMbps * 1_000_000.0
    guard bitsPerSecond.isFinite else { return false }
    return usesAV1
        ? bitsPerSecond <= Double(UInt32.max)
        : bitsPerSecond < Double(Int.max)
}

/// Profile 7 layer settings shared by the encoders and elementary-stream HRD.
enum DolbyVisionProfile7EncodingDefaults {
    static let baseLayerBitrateFraction = 0.80
    static let enhancementLayerBitrateFraction = 0.20
    static let keyFrameIntervalSeconds = 1
}

/// Reads video color extensions and maps them to MOV strings and MXF identifiers.
func detectColorSpace(from track: AVAssetTrack) async -> SourceColorSpace {
    guard let fmts = try? await track.load(.formatDescriptions),
          let fd = fmts.first else {
        return SourceColorSpace(primaries: nil, transfer: nil, matrix: nil,
                                masteringDisplayColorVolume: nil,
                                contentLightLevelInfo: nil,
                                mxfPrimaries: nil, mxfTransfer: nil, mxfMatrix: nil)
    }

    let pCF = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
    let tCF = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    let mCF = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
    let masteringDisplay = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume) as? Data
    let contentLight = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) as? Data

    // Map to MXF ULs
    var mP: Data?; var mT: Data?; var mM: Data?
    if let p = pCF {
        let s = p as NSString
        if s == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as NSString    { mP = MXFColorUL.primariesBT709 }
        else if s == kCMFormatDescriptionColorPrimaries_P3_D65 as NSString    { mP = MXFColorUL.primariesP3D65 }
        else if s == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as NSString { mP = MXFColorUL.primariesBT2020 }
    }
    if let t = tCF {
        let s = t as NSString
        if s == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as NSString         { mT = MXFColorUL.transferBT709 }
        else if s == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as NSString { mT = MXFColorUL.transferST2084 }
        else if s == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as NSString   { mT = MXFColorUL.transferHLG }
        else if s == kCMFormatDescriptionTransferFunction_Linear as NSString            { mT = MXFColorUL.transferLinear }
    }
    if let m = mCF {
        let s = m as NSString
        if s == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as NSString        { mM = MXFColorUL.matrixBT709 }
        else if s == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as NSString    { mM = MXFColorUL.matrixBT2020 }
        else if s == kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 as NSString { mM = MXFColorUL.matrixSMPTE240M }
    }

    return SourceColorSpace(primaries: pCF, transfer: tCF, matrix: mCF,
                            masteringDisplayColorVolume: masteringDisplay,
                            contentLightLevelInfo: contentLight,
                            mxfPrimaries: mP, mxfTransfer: mT, mxfMatrix: mM)
}

// MARK: - FramerateInfo

struct FramerateInfo: Sendable {
    let numerator: Int
    let denominator: Int
    let isDropFrame: Bool
    var fps: Double { Double(numerator) / Double(denominator) }
}

/// Converts a nominal frame-rate value into an exact SMPTE edit-rate rational.
///
/// SMPTE fractional rates are all represented as an integral nominal rate
/// multiplied by 1000/1001.  Resolving that family generically preserves the
/// exact rate for every supported SMPTE timecode quanta instead of rounding
/// rates such as 24000/1001 to 24/1.
private func smpteFrameRateRational(for fps: Double) -> (numerator: Int, denominator: Int)? {
    let tolerance = 0.01
    let integralRate = Int(fps.rounded())
    if integralRate > 0, abs(fps - Double(integralRate)) < tolerance {
        return (integralRate, 1)
    }

    let nominalRate = Int((fps * 1001.0 / 1000.0).rounded())
    let fractionalRate = Double(nominalRate * 1000) / 1001.0
    if nominalRate > 0, abs(fps - fractionalRate) < tolerance {
        return (nominalRate * 1000, 1001)
    }
    return nil
}

/// Reads the drop-frame flag from source timecode rather than inferring it
/// from the video rate: 30000/1001 and 60000/1001 are valid in both DF and NDF.
private func sourceUsesDropFrameTimecode(from asset: AVAsset) async -> Bool {
    guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
          let format = try? await track.load(.formatDescriptions).first else {
        return false
    }
    return (CMTimeCodeFormatDescriptionGetTimeCodeFlags(format) & kCMTimeCodeFlag_DropFrame) != 0
}

/// Measures the video timeline from sample timing without decoding pixel data.
///
/// This is deliberately independent of a QuickTime timecode track. It is used
/// only when AVFoundation cannot provide a usable nominal rate, because sample
/// timing is the authoritative fallback while `minFrameDuration` may merely
/// reflect a coarse container timebase.
private func measuredVideoFrameRate(
    asset: AVAsset,
    track: AVAssetTrack
) -> (numerator: Int, denominator: Int)? {
    guard let reader = try? AVAssetReader(asset: asset) else { return nil }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    guard reader.startReading() else { return nil }

    var frameCount: Int64 = 0
    var totalDuration = CMTime.zero
    while let sampleBuffer = output.copyNextSampleBuffer() {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { continue }
        for index in 0..<sampleCount {
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(
                sampleBuffer,
                at: index,
                timingInfoOut: &timing
            ) == noErr,
            timing.duration.isNumeric,
            timing.duration.value > 0 else {
                continue
            }
            totalDuration = CMTimeAdd(totalDuration, timing.duration)
            frameCount += 1
        }
    }

    guard frameCount > 0,
          totalDuration.isNumeric,
          totalDuration.value > 0,
          totalDuration.timescale > 0 else {
        return nil
    }

    let measuredFPS = Double(frameCount) / totalDuration.seconds
    if let exactRate = smpteFrameRateRational(for: measuredFPS) {
        return exactRate
    }

    let numeratorResult = frameCount.multipliedReportingOverflow(
        by: Int64(totalDuration.timescale)
    )
    let denominator = Int64(totalDuration.value)
    guard !numeratorResult.overflow,
          numeratorResult.partialValue > 0,
          denominator > 0,
          numeratorResult.partialValue <= Int64(Int.max),
          denominator <= Int64(Int.max) else {
        return nil
    }
    let divisor = frameRateGCD(
        Int(numeratorResult.partialValue),
        Int(denominator)
    )
    return (
        Int(numeratorResult.partialValue) / divisor,
        Int(denominator) / divisor
    )
}

/// Normalizes video timing to an exact rational and source convention.
func framerateInfo(from asset: AVAsset) async -> FramerateInfo {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
        return FramerateInfo(numerator: 25, denominator: 1, isDropFrame: false)
    }

    // The absence of a timecode track only means NDF numbering is unavailable;
    // it must never change how the video edit rate itself is measured.
    let isDropFrame = await sourceUsesDropFrameTimecode(from: asset)
    if let rate = try? await track.load(.nominalFrameRate) {
        let fps = Double(rate)
        if fps.isFinite, fps > 0, fps < 1000,
           let exactRate = smpteFrameRateRational(for: fps) {
            return FramerateInfo(
                numerator: exactRate.numerator,
                denominator: exactRate.denominator,
                isDropFrame: isDropFrame
            )
        }
    }

    if let measuredRate = measuredVideoFrameRate(asset: asset, track: track) {
        return FramerateInfo(
            numerator: measuredRate.numerator,
            denominator: measuredRate.denominator,
            isDropFrame: isDropFrame
        )
    }

    if let minDuration = try? await track.load(.minFrameDuration),
       minDuration.isNumeric,
       minDuration.value > 0,
       minDuration.timescale > 0 {
        let divisor = frameRateGCD(Int(minDuration.timescale), Int(minDuration.value))
        return FramerateInfo(
            numerator: Int(minDuration.timescale) / divisor,
            denominator: Int(minDuration.value) / divisor,
            isDropFrame: isDropFrame
        )
    }

    // This is reachable only for malformed media with neither a usable
    // declared rate nor readable sample timing. Callers retain their historic
    // default instead of failing an unrelated encode path.
    return FramerateInfo(
        numerator: 25,
        denominator: 1,
        isDropFrame: isDropFrame
    )
}

private func frameRateGCD(_ lhs: Int, _ rhs: Int) -> Int {
    var a = abs(lhs)
    var b = abs(rhs)
    while b != 0 {
        let remainder = a % b
        a = b
        b = remainder
    }
    return max(a, 1)
}

// MARK: - Timecode reader

func readTimecodeString(from asset: AVAsset) async -> String {
    guard let tcTrack = try? await asset.loadTracks(withMediaType: .timecode).first else {
        return "00:00:00:00"
    }
    var fps = 25; var isDF = false
    if let fmts = try? await tcTrack.load(.formatDescriptions), let fd = fmts.first {
        let q = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(fd))
        if q > 0 { fps = q }
        isDF = (CMTimeCodeFormatDescriptionGetTimeCodeFlags(fd) & kCMTimeCodeFlag_DropFrame) != 0
    }
    do {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tcTrack, outputSettings: nil)
        if reader.canAdd(output) { reader.add(output) }
        reader.startReading()
        if let sample = output.copyNextSampleBuffer(),
           let bb = CMSampleBufferGetDataBuffer(sample),
           CMBlockBufferGetDataLength(bb) >= 4 {
            var raw = Int32.zero
            let copyStatus = withUnsafeMutableBytes(of: &raw) { bytes in
                CMBlockBufferCopyDataBytes(
                    bb,
                    atOffset: 0,
                    dataLength: 4,
                    destination: bytes.baseAddress!
                )
            }
            if copyStatus == kCMBlockBufferNoErr {
                let N = Int(Int32(bigEndian: raw))
                var hh = 0, mm = 0, ss = 0, ff = 0
                if isDF && fps % 30 == 0 && fps >= 30 {
                    let D = 2 * fps / 30; let ND = fps * 60 - D
                    let G10 = ND * 9 + fps * 60
                    let g = N / G10; let rem = N % G10
                    let mig: Int; let fim: Int
                    if rem < fps * 60 { mig = 0; fim = rem }
                    else { let r2 = rem - fps * 60; mig = 1 + r2 / ND; fim = r2 % ND + D }
                    let tm = g * 10 + mig
                    hh = tm / 60; mm = tm % 60; ss = fim / fps; ff = fim % fps
                } else {
                    ff = N % fps; ss = (N / fps) % 60; mm = (N / fps / 60) % 60; hh = N / fps / 3600
                }
                let sep = isDF ? ";" : ":"
                return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
            }
        }
    } catch {}
    return "00:00:00:00"
}

// MARK: - Audio channel count

func audioChannelCount(from asset: AVAsset) async -> Int {
    var total = 0
    for track in (try? await asset.loadTracks(withMediaType: .audio)) ?? [] {
        if let fmts = try? await track.load(.formatDescriptions), let fd = fmts.first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd as CMAudioFormatDescription)
            total += Int(asbd?.pointee.mChannelsPerFrame ?? 2)
        } else { total += 2 }
    }
    return max(total, 2)
}

// MARK: - Video dimensions

func videoSize(from asset: AVAsset) async -> (width: Int, height: Int) {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let fmts  = try? await track.load(.formatDescriptions),
          let fd    = fmts.first else { return (1920, 1080) }
    let d = CMVideoFormatDescriptionGetDimensions(fd)
    return (Int(d.width), Int(d.height))
}

// MARK: - ProRes codec type mapping

let supportedProResQualities: Set<String> = [
    "proxy", "422lt", "422", "422hq", "4444", "4444xq", "pass", "h264", "hevc", "av1"
]

/// Normalizes a quality argument for comparisons and switches.
func normalizedProResQuality(_ quality: String) -> String {
    quality.lowercased()
}

/// Returns a diagnostic when a quality argument is not explicitly supported.
func proResQualityValidationError(_ quality: String) -> String? {
    let normalized = normalizedProResQuality(quality)
    if supportedProResQualities.contains(normalized) {
        return nil
    }
    if normalized == "xq" {
        return "Unsupported quality '\(quality)'. Use '4444xq' explicitly."
    }
    return "Unsupported quality '\(quality)'. Expected one of: proxy, 422lt, 422, 422hq, 4444, 4444xq, pass, h264, hevc, av1."
}

/// Returns whether the requested output codec is HEVC.
func isHEVCQuality(_ quality: String) -> Bool {
    normalizedProResQuality(quality) == "hevc"
}

/// Returns whether the output codec is H.264/AVC.
func isH264Quality(_ quality: String) -> Bool {
    normalizedProResQuality(quality) == "h264"
}

/// Returns whether the requested ProRes variant carries 4:4:4 components.
func is4444FamilyQuality(_ quality: String) -> Bool {
    let q = normalizedProResQuality(quality)
    return q == "4444" || q == "4444xq"
}

/// Decoder output attributes that keep IOSurface-backed buffers for VT/Metal.
func videoPixelBufferOutputSettings(_ pixelFormat: OSType) -> [String: Any] {
    [
        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
    ]
}

/// Selects the decoded pixel layout consumed by the chosen encoder path.
func proResReaderOutputSettings(_ quality: String) -> [String: Any] {
    let pixelFormat: OSType
    if isH264Quality(quality) {
        pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    } else if isCompressedHDRQuality(quality) {
        pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    } else if is4444FamilyQuality(quality) {
        pixelFormat = kCVPixelFormatType_32BGRA
    } else {
        pixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    }
    return videoPixelBufferOutputSettings(pixelFormat)
}

/// Requests a 16-bit 4:2:2 decode surface for Profile 7 only, preserving
/// 10/12/16-bit mezzanine precision until the BL and FEL are derived.
func dolbyVisionProfile7ReaderOutputSettings() -> [String: Any] {
    [
        kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
    ]
}

/// Maps a normalized quality argument to its platform codec identifier.
func proResCodecType(_ quality: String) -> CMVideoCodecType {
    switch normalizedProResQuality(quality) {
    case "hevc":    return kCMVideoCodecType_HEVC
    case "h264":    return kCMVideoCodecType_H264
    case "av1":     return kCMVideoCodecType_AV1
    case "proxy":   return kCMVideoCodecType_AppleProRes422Proxy
    case "422lt":   return kCMVideoCodecType_AppleProRes422LT
    case "422":     return kCMVideoCodecType_AppleProRes422
    case "4444":    return kCMVideoCodecType_AppleProRes4444
    case "4444xq":  return kCMVideoCodecType_AppleProRes4444XQ
    default:        return kCMVideoCodecType_AppleProRes422HQ
    }
}

/// Maps ProRes quality to the numeric variant stored by the MXF writer.
func proResVariantInt(_ quality: String) -> Int {
    switch normalizedProResQuality(quality) {
    case "proxy":  return 1; case "422lt": return 2
    case "422":    return 3; case "422hq": return 4
    case "4444":   return 5; case "4444xq": return 6
    default:       return 4
    }
}

/// Bounds in-flight frame count by estimated memory use and active processor count.
func proResPipelineChannelCapacity(width: Int, height: Int, quality: String) -> Int {
    let bytesPerPixel = isCompressedHDRQuality(quality) ? 2 : 4
    let frameBytes = max(width * height * bytesPerPixel, 1)
    let targetBufferedBytes = 128 * 1024 * 1024
    let memoryLimited = max(4, min(targetBufferedBytes / frameBytes, 8))
    let coreLimited = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 8))
    return min(memoryLimited, coreLimited)
}

/// Formats a media subtype for diagnostics.
private func fourCCString(_ code: FourCharCode) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff),
    ].map { ($0 >= 32 && $0 < 127) ? $0 : UInt8(ascii: ".") }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

/// Selects the pixel layout submitted to a codec session.
private func proResSourcePixelFormat(codecType: CMVideoCodecType) -> OSType {
    if codecType == kCMVideoCodecType_HEVC || codecType == kCMVideoCodecType_AV1 {
        return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
    if codecType == kCMVideoCodecType_H264 {
        return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
    switch codecType {
    case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
        return kCVPixelFormatType_32BGRA
    default:
        return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    }
}

/// Builds preferred image-buffer attributes for encoder discovery.
private func proResEncoderImageBufferAttributes(
    width: Int,
    height: Int,
    codecType: CMVideoCodecType,
    pixelFormat: OSType? = nil
) -> CFDictionary {
    [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
            value: pixelFormat ?? proResSourcePixelFormat(codecType: codecType)
        ),
        kCVPixelBufferWidthKey as String: NSNumber(value: width),
        kCVPixelBufferHeightKey as String: NSNumber(value: height),
        kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as Any,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
    ] as CFDictionary
}

/// Requires a hardware implementation for ProRes encoding.
private func proResHardwareEncoderSpecification() -> CFDictionary {
    [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: kCFBooleanTrue as Any
    ] as CFDictionary
}

/// Requests HEVC hardware, making it mandatory only for the new Native path.
private func hevcHardwareEncoderSpecification(requireHardware: Bool) -> CFDictionary {
    let key = requireHardware
        ? kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder
        : kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder
    return [key as String: kCFBooleanTrue as Any] as CFDictionary
}

/// Reads a Boolean codec-session property while preserving ownership semantics.
private func vtSessionBooleanProperty(_ session: VTCompressionSession, key: CFString) -> Bool? {
    var unmanagedValue: Unmanaged<CFTypeRef>?
    let status = withUnsafeMutablePointer(to: &unmanagedValue) { pointer in
        VTSessionCopyProperty(
            session,
            key: key,
            allocator: kCFAllocatorDefault,
            valueOut: UnsafeMutableRawPointer(pointer)
        )
    }
    guard status == noErr, let unmanagedValue else { return nil }
    let value = unmanagedValue.takeRetainedValue()
    guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue((value as! CFBoolean))
}

/// Returns whether the live encoder advertises multi-pass storage support.
private func vtSessionSupportsMultiPass(_ session: VTCompressionSession) -> Bool {
    var dictionary: CFDictionary?
    let status = VTSessionCopySupportedPropertyDictionary(
        session,
        supportedPropertyDictionaryOut: &dictionary
    )
    guard status == noErr, let dictionary else { return false }
    return (dictionary as NSDictionary).object(forKey: kVTCompressionPropertyKey_MultiPassStorage) != nil
}

/// Copies next-pass time ranges out of the session-owned C array.
private func copyTimeRangesForNextPass(from session: VTCompressionSession) throws -> [CMTimeRange] {
    var count: CMItemCount = 0
    var pointer: UnsafePointer<CMTimeRange>?
    let status = VTCompressionSessionGetTimeRangesForNextPass(
        session,
        timeRangeCountOut: &count,
        timeRangeArrayOut: &pointer
    )
    guard status == noErr else {
        throw NSError(
            domain: "ProResSession",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey:
                "VTCompressionSessionGetTimeRangesForNextPass failed: \(status)"
            ]
        )
    }
    guard let pointer, count > 0 else { return [] }
    return Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
}

/// True when `time` is inside any of the encoder-requested ranges, or when all frames are in play.
func vtTime(_ time: CMTime, isCoveredBy ranges: [CMTimeRange]?) -> Bool {
    guard let ranges else { return true }
    return ranges.contains { range in
        CMTIMERANGE_IS_VALID(range) && CMTimeRangeContainsTime(range, time: time)
    }
}

/// Maps a presentation timestamp onto the synthetic encode timeline (frame 0 at t=0).
func vtFrameIndex(for time: CMTime, fps: FramerateInfo) -> Int64 {
    guard CMTIME_IS_NUMERIC(time), fps.numerator > 0, fps.denominator > 0 else { return 0 }
    let scaled = CMTimeConvertScale(
        time,
        timescale: Int32(fps.numerator),
        method: .roundHalfAwayFromZero
    )
    guard CMTIME_IS_NUMERIC(scaled) else { return 0 }
    return max(scaled.value / Int64(fps.denominator), 0)
}

/// Exclusive-end frame count covered by `ranges` on the synthetic encode timeline.
func vtFrameCount(in ranges: [CMTimeRange], fps: FramerateInfo) -> Int {
    ranges.reduce(0) { partial, range in
        guard CMTIMERANGE_IS_VALID(range) else { return partial }
        let start = vtFrameIndex(for: range.start, fps: fps)
        let end = vtFrameIndex(for: CMTimeRangeGetEnd(range), fps: fps)
        return partial + Int(max(end - start, 0))
    }
}

/// True when the merged ranges already cover the whole source timeline.
func vtRangesCoverFullTimeline(
    _ ranges: [CMTimeRange],
    frameCount: Int64,
    fps: FramerateInfo
) -> Bool {
    guard frameCount > 0 else { return false }
    let merged = mergedVTTimeRanges(ranges, [])
    guard merged.count == 1, let range = merged.first else { return false }
    let start = vtFrameIndex(for: range.start, fps: fps)
    let end = vtFrameIndex(for: CMTimeRangeGetEnd(range), fps: fps)
    return start <= 0 && end >= frameCount
}

/// Frame count this pass will submit to VideoToolbox.
func vtPassFrameCount(
    ranges: [CMTimeRange]?,
    estimatedFrames: Int64,
    fps: FramerateInfo
) -> Int {
    guard let ranges, !ranges.isEmpty,
          !vtRangesCoverFullTimeline(ranges, frameCount: estimatedFrames, fps: fps) else {
        return Int(max(estimatedFrames, 0))
    }
    return vtFrameCount(in: ranges, fps: fps)
}

/// Presentation timestamp assigned to source frame `frameIndex`.
func vtSyntheticPTS(frameIndex: Int64, fps: FramerateInfo) -> CMTime {
    CMTime(
        value: CMTimeValue(frameIndex) * CMTimeValue(fps.denominator),
        timescale: CMTimeScale(max(fps.numerator, 1))
    )
}

/// Constant frame duration on the synthetic encode timeline.
func vtSyntheticDuration(fps: FramerateInfo) -> CMTime {
    CMTime(
        value: CMTimeValue(fps.denominator),
        timescale: CMTimeScale(max(fps.numerator, 1))
    )
}

/// Maps a synthetic encode range onto the asset/track timeline used by AVAssetReader.
func assetTimeRange(
    coveringSynthetic synthetic: CMTimeRange,
    trackTimeRange: CMTimeRange
) -> CMTimeRange {
    let trackStart = CMTIMERANGE_IS_VALID(trackTimeRange) ? trackTimeRange.start : .zero
    let start = CMTIME_IS_NUMERIC(trackStart)
        ? CMTimeAdd(trackStart, synthetic.start)
        : synthetic.start
    let mapped = CMTimeRange(start: start, duration: synthetic.duration)
    guard CMTIMERANGE_IS_VALID(trackTimeRange) else { return mapped }
    let clamped = CMTimeRangeGetIntersection(mapped, otherRange: trackTimeRange)
    return CMTIMERANGE_IS_VALID(clamped) && CMTimeCompare(clamped.duration, .zero) > 0
        ? clamped
        : mapped
}

/// Human-readable extra-pass coverage for logs.
func vtTimeRangeDescription(_ range: CMTimeRange, fps: FramerateInfo) -> String {
    let start = vtFrameIndex(for: range.start, fps: fps)
    let end = vtFrameIndex(for: CMTimeRangeGetEnd(range), fps: fps)
    return "frames \(start)..<\(end) (\(max(end - start, 0)) frame(s))"
}

/// Merges two range lists into the non-overlapping, ascending list FrameSilo requires.
func mergedVTTimeRanges(_ lhs: [CMTimeRange], _ rhs: [CMTimeRange]) -> [CMTimeRange] {
    let sorted = (lhs + rhs)
        .filter { CMTIMERANGE_IS_VALID($0) && CMTimeCompare($0.duration, .zero) > 0 }
        .sorted { CMTimeCompare($0.start, $1.start) < 0 }
    var merged: [CMTimeRange] = []
    for range in sorted {
        guard let last = merged.last else {
            merged.append(range)
            continue
        }
        let lastEnd = CMTimeRangeGetEnd(last)
        if CMTimeCompare(range.start, lastEnd) <= 0 {
            let end = CMTimeMaximum(lastEnd, CMTimeRangeGetEnd(range))
            merged[merged.count - 1] = CMTimeRangeFromTimeToTime(start: last.start, end: end)
        } else {
            merged.append(range)
        }
    }
    return merged
}

/// File-backed compressed-sample store used to merge VideoToolbox multi-pass output.
final class VTEncodedFrameSilo: @unchecked Sendable {
    private var silo: VTFrameSilo?

    /// Creates a temporary-file silo covering the encoded timeline.
    init(timeRange: CMTimeRange = .invalid) throws {
        var created: VTFrameSilo?
        let status = VTFrameSiloCreate(
            allocator: kCFAllocatorDefault,
            fileURL: nil,
            timeRange: timeRange,
            options: nil,
            frameSiloOut: &created
        )
        guard status == noErr, let created else {
            throw NSError(
                domain: "ProResSession",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "VTFrameSiloCreate failed: \(status)"
                ]
            )
        }
        silo = created
    }

    /// Appends one compressed sample in strictly increasing decode-timestamp order.
    func add(_ sampleBuffer: CMSampleBuffer) throws {
        guard let silo else { return }
        let status = VTFrameSiloAddSampleBuffer(silo, sampleBuffer: sampleBuffer)
        guard status == noErr else {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
            throw NSError(
                domain: "ProResSession",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "VTFrameSiloAddSampleBuffer failed: \(status) pts=\(pts.seconds) dts=\(dts.seconds)"
                ]
            )
        }
    }

    /// Drops previously stored samples in `ranges` so the next pass can replace them.
    func setTimeRangesForNextPass(_ ranges: [CMTimeRange]) throws {
        guard let silo, !ranges.isEmpty else { return }
        let status = ranges.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return noErr }
            return VTFrameSiloSetTimeRangesForNextPass(
                silo,
                timeRangeCount: CMItemCount(buffer.count),
                timeRangeArray: base
            )
        }
        guard status == noErr else {
            throw NSError(
                domain: "ProResSession",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "VTFrameSiloSetTimeRangesForNextPass failed: \(status)"
                ]
            )
        }
    }

    /// Iterates stored samples in decode order. Each buffer is copied; silo storage is not retained.
    func forEachSample(_ body: (CMSampleBuffer) throws -> Void) throws {
        guard let silo else { return }
        var caught: Error?
        let status = VTFrameSiloCallBlockForEachSampleBuffer(silo, in: .invalid) { sample in
            do {
                var copied: CMSampleBuffer?
                let copyStatus = CMSampleBufferCreateCopy(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: sample,
                    sampleBufferOut: &copied
                )
                guard copyStatus == noErr, let copied else {
                    throw NSError(
                        domain: "ProResSession",
                        code: Int(copyStatus),
                        userInfo: [NSLocalizedDescriptionKey:
                            "CMSampleBufferCreateCopy failed while draining VTFrameSilo: \(copyStatus)"
                        ]
                    )
                }
                try body(copied)
                return noErr
            } catch {
                caught = error
                return -1
            }
        }
        if let caught { throw caught }
        guard status == noErr else {
            throw NSError(
                domain: "ProResSession",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "VTFrameSiloCallBlockForEachSampleBuffer failed: \(status)"
                ]
            )
        }
    }
}

// MARK: - Source ProRes check

func isSourceProRes(_ track: AVAssetTrack) async -> Bool {
    guard let fmts = try? await track.load(.formatDescriptions),
          let fd = fmts.first else { return false }
    let codec = CMFormatDescriptionGetMediaSubType(fd)
    let proRes: Set<FourCharCode> = [
        kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422,       kCMVideoCodecType_AppleProRes422HQ,
        kCMVideoCodecType_AppleProRes4444,      kCMVideoCodecType_AppleProRes4444XQ,
    ]
    return proRes.contains(codec)
}

// MARK: - Frame count estimation

func estimateFrameCount(asset: AVAsset) async -> Int64 {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return 0 }
    let minFD = try? await track.load(.minFrameDuration)
    let dur = try? await asset.load(.duration)
    if let mfd = minFD, CMTIME_IS_VALID(mfd), mfd.value > 0,
       let d = dur, CMTIME_IS_VALID(d) {
        let num = Int64(d.value) * Int64(mfd.timescale)
        let den = Int64(mfd.value) * Int64(d.timescale)
        return den > 0 ? (num + den / 2) / den : 0
    }
    if let d = dur, let fps = try? await track.load(.nominalFrameRate), fps > 0 {
        return Int64(CMTimeGetSeconds(d) * Double(fps) + 0.5)
    }
    return 0
}

/// Maps a compressed sample's presentation timestamp back to a zero-based frame index.
func presentationFrameIndex(for sampleBuffer: CMSampleBuffer, fps: Double) -> Int64 {
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let seconds = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : .nan
    guard seconds.isFinite, fps > 0 else { return 0 }
    return max(0, Int64((seconds * fps).rounded()))
}

// MARK: - AsyncChannel

/// Sendable wrappers for CoreMedia/CoreVideo types that lack conformance on macOS 13.
struct SendableSampleBuffer: @unchecked Sendable { let buf: CMSampleBuffer }
/// Transfers a retained pixel buffer between pipeline tasks.
struct SendablePixelBuffer: @unchecked Sendable { let buf: CVPixelBuffer }

/// Lightweight bounded FIFO channel for Swift async/await pipelines.
/// Producers back-pressure when full; consumers suspend when empty.
final class AsyncChannel<T: Sendable>: @unchecked Sendable {
    /// Producer state retained while the bounded buffer is full.
    private enum PendingProducer {
        case async(T, CheckedContinuation<Void, Never>)
        case blocking(T, DispatchSemaphore)
    }

    private var buffer: [T] = []
    private let capacity: Int
    private var finished = false
    private let lock = NSLock()
    private var waitingConsumers: [CheckedContinuation<T?, Never>] = []
    private var waitingProducers: [PendingProducer] = []

    /// Creates a FIFO with a fixed buffering capacity.
    init(capacity: Int) {
        self.capacity = capacity
        buffer.reserveCapacity(capacity)
    }

    /// Blocking send for use from C callbacks. Back-pressures until space exists.
    func send(_ value: T) {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if let consumer = waitingConsumers.first {
            waitingConsumers.removeFirst()
            lock.unlock()
            consumer.resume(returning: value)
            return
        }
        if buffer.count < capacity {
            buffer.append(value)
            lock.unlock()
            return
        }
        waitingProducers.append(.blocking(value, semaphore))
        lock.unlock()
        semaphore.wait()
    }

    /// Async send for producer tasks; suspends instead of dropping values.
    func sendAsync(_ value: T) async {
        await withCheckedContinuation { cont in
            lock.lock()
            if finished {
                lock.unlock()
                cont.resume()
                return
            }
            if let consumer = waitingConsumers.first {
                waitingConsumers.removeFirst()
                lock.unlock()
                consumer.resume(returning: value)
                cont.resume()
                return
            }
            if buffer.count < capacity {
                buffer.append(value)
                lock.unlock()
                cont.resume()
                return
            }
            waitingProducers.append(.async(value, cont))
            lock.unlock()
        }
    }

    /// Close the channel; pending consumers receive nil.
    func finish() {
        lock.lock()
        finished = true
        let consumers = waitingConsumers
        waitingConsumers = []
        let producers = waitingProducers
        waitingProducers = []
        lock.unlock()
        consumers.forEach { $0.resume(returning: nil) }
        producers.forEach { producer in
            switch producer {
            case .async(_, let cont):
                cont.resume()
            case .blocking(_, let semaphore):
                semaphore.signal()
            }
        }
    }

    /// Async receive. Suspends when empty; returns nil when finished and empty.
    func next() async -> T? {
        await withCheckedContinuation { cont in
            lock.lock()
            if !buffer.isEmpty {
                let value = buffer.removeFirst()
                if let pending = waitingProducers.first {
                    waitingProducers.removeFirst()
                    switch pending {
                    case .async(let pendingValue, let producer):
                        buffer.append(pendingValue)
                        lock.unlock()
                        producer.resume()
                    case .blocking(let pendingValue, let semaphore):
                        buffer.append(pendingValue)
                        lock.unlock()
                        semaphore.signal()
                    }
                } else {
                    lock.unlock()
                }
                cont.resume(returning: value)
            } else if finished {
                lock.unlock()
                cont.resume(returning: nil)
            } else {
                waitingConsumers.append(cont)
                lock.unlock()
            }
        }
    }
}

/// Enables asynchronous iteration until the channel is finished and drained.
extension AsyncChannel: AsyncSequence {
    typealias Element = T
    /// Iterator forwarding reads to its channel.
    struct AsyncIterator: AsyncIteratorProtocol {
        let channel: AsyncChannel<T>
        /// Returns the next buffered value or nil after completion.
        mutating func next() async -> T? { await channel.next() }
    }
    /// Creates an iterator sharing this channel's state.
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(channel: self) }
}

// MARK: - ProResSession (VTCompressionSession wrapper)

/// Refcon for the VT C callback: routes to async channel or sync box.
private final class VTCallbackRefcon: @unchecked Sendable {
    var sample: CMSampleBuffer?
    let syncLock = NSLock()
    var asyncChannel: AsyncChannel<SendableSampleBuffer>?
    var frameSilo: VTEncodedFrameSilo?
    private let asyncStateLock = NSLock()
    private var asyncSubmittedCount: Int64 = 0
    private var asyncCompletedCount: Int64 = 0
    private var asyncDeliveryPendingCount: Int64 = 0
    private var asyncFlushRequested = false
    private var asyncChannelFinished = false
    private var collectEncodedSamples = false
    private var encodedSampleQueue: [CMSampleBuffer] = []
    private var encodedSubmitCount = 0
    private var encodedCallbackCount = 0
    private let encodedSampleLock = NSLock()

    /// Delivers compressed samples directly into a FrameSilo from the codec callback thread.
    func configureFrameSilo(_ silo: VTEncodedFrameSilo) {
        asyncStateLock.lock()
        frameSilo = silo
        asyncChannel = nil
        collectEncodedSamples = false
        asyncStateLock.unlock()
    }

    /// Keeps encoded samples in a FIFO for closed-loop Profile 7 reconstruction.
    func configureEncodedSampleQueue() {
        asyncStateLock.lock()
        collectEncodedSamples = true
        frameSilo = nil
        asyncChannel = nil
        asyncStateLock.unlock()
        encodedSampleLock.lock()
        encodedSampleQueue.removeAll(keepingCapacity: true)
        encodedSubmitCount = 0
        encodedCallbackCount = 0
        encodedSampleLock.unlock()
    }

    var isCollectingEncodedSamples: Bool {
        asyncStateLock.lock()
        defer { asyncStateLock.unlock() }
        return collectEncodedSamples
    }

    func noteEncodedSubmit() {
        encodedSampleLock.lock()
        encodedSubmitCount += 1
        encodedSampleLock.unlock()
    }

    func noteEncodedCallback() {
        encodedSampleLock.lock()
        encodedCallbackCount += 1
        encodedSampleLock.unlock()
    }

    func pendingEncodedCallbacks() -> Int {
        encodedSampleLock.lock()
        defer { encodedSampleLock.unlock() }
        return max(0, encodedSubmitCount - encodedCallbackCount)
    }

    func resetEncodedSampleCounts() {
        encodedSampleLock.lock()
        encodedSubmitCount = 0
        encodedCallbackCount = 0
        encodedSampleQueue.removeAll(keepingCapacity: true)
        encodedSampleLock.unlock()
    }

    func appendEncodedSample(_ sampleBuffer: CMSampleBuffer) {
        encodedSampleLock.lock()
        encodedSampleQueue.append(sampleBuffer)
        encodedSampleLock.unlock()
    }

    func takeEncodedSamples() -> [CMSampleBuffer] {
        encodedSampleLock.lock()
        defer { encodedSampleLock.unlock() }
        let samples = encodedSampleQueue
        encodedSampleQueue.removeAll(keepingCapacity: true)
        return samples
    }

    /// Switches callback delivery from synchronous storage to an asynchronous channel.
    func configureAsyncChannel(_ channel: AsyncChannel<SendableSampleBuffer>) {
        asyncStateLock.lock()
        asyncChannel = channel
        frameSilo = nil
        collectEncodedSamples = false
        asyncSubmittedCount = 0
        asyncCompletedCount = 0
        asyncDeliveryPendingCount = 0
        asyncFlushRequested = false
        asyncChannelFinished = false
        asyncStateLock.unlock()
    }

    /// Increments the count of frames expected to produce callbacks.
    func willSubmitAsyncFrame() {
        asyncStateLock.lock()
        asyncSubmittedCount += 1
        asyncStateLock.unlock()
    }

    /// Reverts a failed submission and checks whether flush can finish the channel.
    func revertAsyncSubmission() -> AsyncChannel<SendableSampleBuffer>? {
        asyncStateLock.lock()
        asyncSubmittedCount = max(0, asyncSubmittedCount - 1)
        let channel = finishChannelIfDrainedLocked()
        asyncStateLock.unlock()
        return channel
    }

    /// Records callback completion and checks whether flush can finish the channel.
    func completeAsyncFrame() -> AsyncChannel<SendableSampleBuffer>? {
        asyncStateLock.lock()
        asyncCompletedCount += 1
        let channel = finishChannelIfDrainedLocked()
        asyncStateLock.unlock()
        return channel
    }

    /// Marks submission complete and returns the channel if no work remains.
    func requestAsyncFlush() -> AsyncChannel<SendableSampleBuffer>? {
        asyncStateLock.lock()
        asyncFlushRequested = true
        let channel = finishChannelIfDrainedLocked()
        asyncStateLock.unlock()
        return channel
    }

    /// True while EncodeFrame callbacks or async silo delivery are still in flight.
    func hasPendingAsyncWork() -> Bool {
        asyncStateLock.lock()
        defer { asyncStateLock.unlock() }
        return asyncCompletedCount < asyncSubmittedCount || asyncDeliveryPendingCount > 0
    }

    /// Delivers callback output without blocking the codec callback thread.
    func dispatchAsyncDelivery(of sampleBuffer: CMSampleBuffer) {
        asyncStateLock.lock()
        guard let channel = asyncChannel else {
            asyncStateLock.unlock()
            return
        }
        asyncDeliveryPendingCount += 1
        asyncStateLock.unlock()

        let wrapped = SendableSampleBuffer(buf: sampleBuffer)
        Task {
            await channel.sendAsync(wrapped)
            self.completeAsyncDelivery()?.finish()
        }
    }

    /// Decrements delivery count and checks whether deferred finish can proceed.
    private func completeAsyncDelivery() -> AsyncChannel<SendableSampleBuffer>? {
        asyncStateLock.lock()
        asyncDeliveryPendingCount = max(0, asyncDeliveryPendingCount - 1)
        let channel = finishChannelIfDrainedLocked()
        asyncStateLock.unlock()
        return channel
    }

    /// Returns the channel once after flush, callbacks, and deliveries all drain.
    private func finishChannelIfDrainedLocked() -> AsyncChannel<SendableSampleBuffer>? {
        guard asyncFlushRequested,
              !asyncChannelFinished,
              asyncCompletedCount >= asyncSubmittedCount,
              asyncDeliveryPendingCount == 0 else {
            return nil
        }
        asyncChannelFinished = true
        return asyncChannel
    }
}

/// C-compatible VTCompressionSession output callback.
private func vtOutputCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ sourceRef: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ flags: VTEncodeInfoFlags,
    _ sampleBuffer: CMSampleBuffer?
) {
    guard let refcon else { return }
    let rc = Unmanaged<VTCallbackRefcon>.fromOpaque(refcon).takeUnretainedValue()
    if rc.frameSilo != nil {
        if status == noErr, let sampleBuffer {
            do {
                try rc.frameSilo?.add(sampleBuffer)
            } catch {
                // Keep encoding; the MOV pipeline reports the silo error after the pass.
            }
        }
        return
    }
    if rc.isCollectingEncodedSamples {
        rc.noteEncodedCallback()
        if status == noErr, let sampleBuffer {
            rc.appendEncodedSample(sampleBuffer)
        }
        return
    }
    if rc.asyncChannel != nil {
        if status == noErr, let sampleBuffer {
            rc.dispatchAsyncDelivery(of: sampleBuffer)
        }
        rc.completeAsyncFrame()?.finish()
    } else {
        guard status == noErr, let sampleBuffer else { return }
        rc.syncLock.lock(); rc.sample = sampleBuffer; rc.syncLock.unlock()
    }
}

/// ProResSession wraps VTCompressionSession.
/// Sync mode (MOV): encode() → returns CMSampleBuffer immediately.
/// Async mode (MXF): enableAsyncMode() → submit() → results in outputChannel.
final class ProResSession: @unchecked Sendable {
    private var session: VTCompressionSession!
    private let rc = VTCallbackRefcon()
    private(set) var outputChannel: AsyncChannel<SendableSampleBuffer>?
    private let isHEVCSession: Bool
    private let hevcColorSpace: SourceColorSpace?
    private let hevcMasteringDisplayColorVolume: Data?
    private let hevcContentLightLevelInfo: Data?
    private var multiPassStorage: VTMultiPassStorage?
    private(set) var isMultiPassEnabled = false

    /// Creates and configures a compression session for ProRes or HEVC output.
    init(width: Int, height: Int, codecType: CMVideoCodecType,
         fpsHint: Int, colorSpace: SourceColorSpace?,
         hevcOptions: HEVCEncodeOptions? = nil,
         sourcePixelFormat: OSType? = nil,
         sourceFrameCount: Int = 0,
         sourceTimeRange: CMTimeRange = .invalid) throws {
        var sess: VTCompressionSession?
        let rcPtr = Unmanaged.passUnretained(rc).toOpaque()
        let isHEVC = (codecType == kCMVideoCodecType_HEVC)
        let isH264 = (codecType == kCMVideoCodecType_H264)
        let isAVCEncoder = isHEVC || isH264
        let requiresNativeHEVCHardware = isHEVC && hevcOptions?.dvProfile?.usesNativeIPT == true
        isHEVCSession = isHEVC
        hevcColorSpace = colorSpace
        hevcMasteringDisplayColorVolume = colorSpace?.masteringDisplayColorVolume
        hevcContentLightLevelInfo = colorSpace?.contentLightLevelInfo
        let encoderSpecification = isAVCEncoder
            ? hevcHardwareEncoderSpecification(requireHardware: requiresNativeHEVCHardware)
            : proResHardwareEncoderSpecification()
        let imageBufferAttributeCandidates: [CFDictionary?] = [
            proResEncoderImageBufferAttributes(
                width: width,
                height: height,
                codecType: codecType,
                pixelFormat: sourcePixelFormat
            ),
            nil
        ]
        var st: OSStatus = noErr

        VTRegisterProfessionalVideoWorkflowVideoEncoders()
        for imageBufferAttributes in imageBufferAttributeCandidates {
            for attempt in 0..<5 {
                st = VTCompressionSessionCreate(
                    allocator: kCFAllocatorDefault,
                    width: Int32(width), height: Int32(height),
                    codecType: codecType,
                    encoderSpecification: encoderSpecification,
                    imageBufferAttributes: imageBufferAttributes,
                    compressedDataAllocator: nil,
                    outputCallback: vtOutputCallback,
                    refcon: rcPtr,
                    compressionSessionOut: &sess)
                if st == noErr, sess != nil { break }
                if st == kVTCouldNotFindVideoEncoderErr || st == kVTVideoEncoderNotAvailableNowErr {
                    usleep(UInt32(150_000 * (attempt + 1)))
                } else {
                    break
                }
            }
            if st == noErr, sess != nil { break }
        }
        guard st == noErr, let sess else {
            throw NSError(domain: "ProResSession", code: Int(st),
                          userInfo: [NSLocalizedDescriptionKey:
                            "VTCompressionSession create failed: \(st) (codec=\(fourCCString(codecType)), size=\(width)x\(height))"])
        }
        session = sess
        func setProperty(_ key: CFString, value: CFTypeRef, required: Bool = false) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if required && status != noErr {
                throw NSError(
                    domain: "ProResSession",
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey:
                        "VideoToolbox rejected required Native Dolby Vision encoder property \(key): \(status)"
                    ]
                )
            }
        }
        try setProperty(
            kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanFalse,
            required: requiresNativeHEVCHardware
        )
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        let n = NSNumber(value: fpsHint)
        try setProperty(
            kVTCompressionPropertyKey_ExpectedFrameRate,
            value: n,
            required: requiresNativeHEVCHardware
        )
        if let p = colorSpace?.primaries {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: p as CFString)
        }
        if let t = colorSpace?.transfer {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: t as CFString)
        }
        if let m = colorSpace?.matrix {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: m as CFString)
        }
        if isAVCEncoder {
            guard let hevcOptions else {
                throw NSError(domain: "ProResSession", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "H.264/HEVC encode requires bitrate options."])
            }
            if let p = colorSpace?.primaries {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                                     value: p as CFString)
            }
            if let t = colorSpace?.transfer {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                                     value: t as CFString)
            }
            if let m = colorSpace?.matrix {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                     value: m as CFString)
            }
            if isHEVC {
                VTSessionSetProperty(session, key: kVTCompressionPropertyKey_HDRMetadataInsertionMode,
                                     value: kVTHDRMetadataInsertionMode_Auto)
                if let masteringDisplay = colorSpace?.masteringDisplayColorVolume {
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MasteringDisplayColorVolume,
                                         value: masteringDisplay as CFData)
                }
                if let contentLight = colorSpace?.contentLightLevelInfo {
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ContentLightLevelInfo,
                                         value: contentLight as CFData)
                }
            }
            try setProperty(
                kVTCompressionPropertyKey_ProfileLevel,
                value: isHEVC
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel
                    : kVTProfileLevel_H264_High_AutoLevel,
                required: requiresNativeHEVCHardware
            )
            try setProperty(
                kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: hevcOptions.bitrateBitsPerSecond),
                required: requiresNativeHEVCHardware
            )
            if hevcOptions.bitrateMode == .cbr, !hevcOptions.multiPass {
                try setProperty(
                    kVTCompressionPropertyKey_ConstantBitRate,
                    value: NSNumber(value: hevcOptions.bitrateBitsPerSecond),
                    required: true
                )
            } else if hevcOptions.bitrateMode == .cbr, hevcOptions.multiPass {
                print("[VT] --cbr is incompatible with VideoToolbox multi-pass EndPass; using VBR analysis at the same target bitrate.")
            }
            if hevcOptions.bitrateMode != .cbr, !hevcOptions.multiPass {
                // DataRateLimits makes VTCompressionSessionEndPass return kVTParameterErr
                // on the hardware H.264/HEVC encoders, which disables multi-pass analysis.
                let bytesPerSecond = max(1, hevcOptions.bitrateBitsPerSecond / 8)
                let dataRateLimits = [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray
                try setProperty(kVTCompressionPropertyKey_DataRateLimits,
                                value: dataRateLimits,
                                required: requiresNativeHEVCHardware)
            }
            // GOP H.264/HEVC uses B-frame reordering by default, including
            // Profile 5. `--b-frames off` and `--all-intra` keep I/P or
            // all-intra. Profile 7.6 forces I/P so BL/EL picture types match.
            var allowFrameReordering = hevcOptions.bFrames
            let reorderStatus = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                value: allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse
            )
            if allowFrameReordering, reorderStatus != noErr {
                print("[VT] Frame reordering was rejected (\(reorderStatus)); encoding without B-frames.")
                allowFrameReordering = false
                try setProperty(
                    kVTCompressionPropertyKey_AllowFrameReordering,
                    value: kCFBooleanFalse,
                    required: requiresNativeHEVCHardware || hevcOptions.allIntra
                )
            } else if reorderStatus != noErr {
                try setProperty(
                    kVTCompressionPropertyKey_AllowFrameReordering,
                    value: kCFBooleanFalse,
                    required: requiresNativeHEVCHardware || hevcOptions.allIntra
                )
            }
            if allowFrameReordering {
                print("[VT] Frame reordering on.")
            } else {
                print("[VT] Frame reordering off.")
            }
            let keyFrameIntervalSeconds = max(hevcOptions.keyFrameIntervalSeconds, 1)
            try setProperty(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: hevcOptions.allIntra ? 1 : max(fpsHint * keyFrameIntervalSeconds, 1)),
                required: requiresNativeHEVCHardware
            )
            if !hevcOptions.allIntra {
                try setProperty(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                value: NSNumber(value: keyFrameIntervalSeconds),
                                required: requiresNativeHEVCHardware)
            }
            if sourceFrameCount > 0 {
                VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_SourceFrameCount,
                    value: NSNumber(value: sourceFrameCount)
                )
            }
            if hevcOptions.multiPass {
                if vtSessionSupportsMultiPass(session) {
                    var storage: VTMultiPassStorage?
                    let storageStatus = VTMultiPassStorageCreate(
                        allocator: kCFAllocatorDefault,
                        fileURL: nil,
                        timeRange: sourceTimeRange,
                        options: nil,
                        multiPassStorageOut: &storage
                    )
                    if storageStatus == noErr, let storage {
                        let attachStatus = VTSessionSetProperty(
                            session,
                            key: kVTCompressionPropertyKey_MultiPassStorage,
                            value: storage
                        )
                        if attachStatus == noErr {
                            multiPassStorage = storage
                            isMultiPassEnabled = true
                        } else {
                            VTMultiPassStorageClose(storage)
                            print("[VT] Multi-pass storage was rejected (\(attachStatus)); using a single pass.")
                        }
                    } else {
                        print("[VT] VTMultiPassStorageCreate failed (\(storageStatus)); using a single pass.")
                    }
                } else {
                    print("[VT] This H.264/HEVC encoder does not advertise multi-pass support; using a single pass.")
                }
            }
        } else {
            try setProperty(
                kVTCompressionPropertyKey_AllowFrameReordering,
                value: kCFBooleanFalse
            )
        }
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if requiresNativeHEVCHardware && prepareStatus != noErr {
            throw NSError(domain: "ProResSession", code: Int(prepareStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "VideoToolbox could not prepare the required Native Dolby Vision hardware HEVC encoder: \(prepareStatus)"])
        }
        let usingHardware = isHEVC
            ? vtSessionBooleanProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder
            )
            : nil
        if requiresNativeHEVCHardware && usingHardware != true {
            throw NSError(domain: "ProResSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "VideoToolbox did not confirm hardware HEVC for Native Dolby Vision Profile 5."])
        }
        if isHEVC, usingHardware == false {
            throw NSError(domain: "ProResSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "VideoToolbox created a software HEVC encoder; hardware HEVC is required."])
        }
    }

    /// Switch to async mode: creates the outputChannel and routes VT callback to it.
    /// Must be called before the first `submit()`. Multi-pass reuses this channel.
    func enableAsyncMode(channelCapacity: Int = 4) {
        let ch = AsyncChannel<SendableSampleBuffer>(capacity: channelCapacity)
        outputChannel = ch
        rc.configureAsyncChannel(ch)
    }

    /// Routes codec callbacks into `silo` on the VideoToolbox thread (no extra copies).
    func attachFrameSilo(_ silo: VTEncodedFrameSilo) {
        outputChannel = nil
        rc.configureFrameSilo(silo)
    }

    /// Collects encoded samples in a FIFO instead of overwriting the sync slot.
    func enableEncodedSampleQueue() {
        outputChannel = nil
        rc.configureEncodedSampleQueue()
    }

    /// Returns samples emitted since the previous drain.
    func drainEncodedSamples() -> [CMSampleBuffer] {
        rc.takeEncodedSamples()
    }

    /// EncodeFrame callbacks still outstanding for the Profile 7 sample queue.
    func pendingEncodedCallbacks() -> Int {
        rc.pendingEncodedCallbacks()
    }

    /// Drops queued samples and submit/callback counters at the start of a pass.
    func resetEncodedSampleQueue() {
        rc.resetEncodedSampleCounts()
    }

    /// Waits until VideoToolbox has delivered every submitted sample, or `timeout`.
    func waitForEncodedCallbacks(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while rc.pendingEncodedCallbacks() > 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Completes encoded frames up to `pts` without ending the compression pass.
    func completeFrames(until pts: CMTime) {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
    }

    /// Updates `SourceFrameCount` for the upcoming pass. Safe to call when multi-pass is off.
    func setSourceFrameCount(_ count: Int) {
        guard count > 0, session != nil else { return }
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_SourceFrameCount,
            value: NSNumber(value: count)
        )
    }

    /// Announces one VideoToolbox analysis/encode pass. No-ops when multi-pass is inactive.
    func beginCompressionPass(isFinal: Bool = false) throws {
        guard isMultiPassEnabled else { return }
        let flags: VTCompressionSessionOptionFlags = isFinal ? .beginFinalPass : []
        var reserved: UInt32 = 0
        let status = VTCompressionSessionBeginPass(session, flags: flags, &reserved)
        guard status == noErr else {
            throw NSError(
                domain: "ProResSession",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "VTCompressionSessionBeginPass failed: \(status)"
                ]
            )
        }
    }

    /// Ends the current pass and reports whether the encoder wants another scan.
    func endCompressionPass(evaluateFurtherPasses: Bool = true) throws -> Bool {
        guard isMultiPassEnabled else { return false }
        var further: DarwinBoolean = false
        var reserved: UInt32 = 0
        var status: OSStatus
        if evaluateFurtherPasses {
            status = VTCompressionSessionEndPass(
                session,
                furtherPassesRequestedOut: &further,
                &reserved
            )
            if status == kVTParameterErr {
                reserved = 0
                status = VTCompressionSessionEndPass(
                    session,
                    furtherPassesRequestedOut: nil,
                    &reserved
                )
                further = false
                if status == noErr {
                    print("[VT] Encoder declined further-pass evaluation; keeping this pass.")
                }
            }
        } else {
            status = VTCompressionSessionEndPass(
                session,
                furtherPassesRequestedOut: nil,
                &reserved
            )
        }
        if status == kVTParameterErr {
            print("[VT] VTCompressionSessionEndPass is not supported by this encoder; keeping the current pass.")
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            isMultiPassEnabled = false
            return false
        }
        guard status == noErr else {
            throw NSError(
                domain: "ProResSession",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "VTCompressionSessionEndPass failed: \(status)"
                ]
            )
        }
        return evaluateFurtherPasses && further.boolValue
    }

    /// Emits compressed frames with PTS up to `pts` without closing the session.
    func completePendingFrames(until pts: CMTime) {
        let completeUntil = CMTIME_IS_NUMERIC(pts) ? pts : .invalid
        VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: completeUntil
        )
    }

    /// Waits until VT callbacks and async sample delivery have caught up with submissions.
    func waitForAsyncDelivery() async {
        while rc.hasPendingAsyncWork() {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Closes the async output channel after the last pass has drained.
    func finishAsyncOutput() {
        rc.requestAsyncFlush()?.finish()
    }

    /// Time ranges the encoder still wants re-encoded. Empty means keep the last pass.
    func timeRangesForNextPass() throws -> [CMTimeRange] {
        guard isMultiPassEnabled else { return [] }
        return try copyTimeRangesForNextPass(from: session)
    }

    // MARK: Sync path (used by VideoFrameSource → MOV pipeline)

    /// Encode one pixel buffer synchronously. Returns compressed CMSampleBuffer.
    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        attachHEVCMetadataIfNeeded(to: pixelBuffer)
        rc.syncLock.lock(); rc.sample = nil; rc.syncLock.unlock()
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: duration,
            frameProperties: nil, sourceFrameRefcon: nil,
            infoFlagsOut: nil)
        guard st == noErr else { return nil }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: CMTimeAdd(pts, duration))
        rc.syncLock.lock(); let r = rc.sample; rc.sample = nil; rc.syncLock.unlock()
        return r
    }

    // MARK: Async path (used by MXF 3-stage pipeline)

    /// Submit a frame to VT without waiting. VT delivers the result to `outputChannel`.
    @discardableResult
    func submit(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) -> Bool {
        attachHEVCMetadataIfNeeded(to: pixelBuffer)
        if outputChannel != nil {
            rc.willSubmitAsyncFrame()
        }
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: duration,
            frameProperties: nil, sourceFrameRefcon: nil,
            infoFlagsOut: nil)
        if st != noErr, outputChannel != nil {
            rc.revertAsyncSubmission()?.finish()
        }
        if st == noErr, rc.isCollectingEncodedSamples {
            rc.noteEncodedSubmit()
        }
        return st == noErr
    }

    /// Flush remaining frames, then close the outputChannel.
    func flushAsync() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        finishAsyncOutput()
    }

    /// Completes all submitted frames for synchronous callers.
    func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Invalidates the codec session and prevents further submission.
    func invalidate() {
        if let storage = multiPassStorage {
            VTMultiPassStorageClose(storage)
            multiPassStorage = nil
            isMultiPassEnabled = false
        }
        if session != nil { VTCompressionSessionInvalidate(session); session = nil }
    }

    /// Propagates static HDR and color attachments to HEVC input frames.
    private func attachHEVCMetadataIfNeeded(to pixelBuffer: CVPixelBuffer) {
        guard isHEVCSession else { return }
        if let p = hevcColorSpace?.primaries {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                p as CFString,
                .shouldPropagate)
        }
        if let t = hevcColorSpace?.transfer {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                t as CFString,
                .shouldPropagate)
        }
        if let m = hevcColorSpace?.matrix {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                m as CFString,
                .shouldPropagate)
        }
        if let hevcMasteringDisplayColorVolume {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                hevcMasteringDisplayColorVolume as CFData,
                .shouldPropagate)
        }
        if let hevcContentLightLevelInfo {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                hevcContentLightLevelInfo as CFData,
                .shouldPropagate)
        }
    }
    /// Releases the codec session if the owner did not invalidate it explicitly.
    deinit { invalidate() }
}

// MARK: - VideoFrameSource

/// Produces compressed ProRes CMSampleBuffers on demand.
/// For passthrough: returns compressed samples from source.
/// For re-encode:  decodes → VT → compressed.
final class VideoFrameSource: @unchecked Sendable {
    private let output: AVAssetReaderTrackOutput
    private let vtSession: ProResSession?
    private let fpsDen: Int32
    private let fpsNum: Int32
    private var frameIndex: Int64 = 0

    /// Creates a passthrough or re-encoding frame source with exact rate timing.
    init(output: AVAssetReaderTrackOutput, vtSession: ProResSession?,
         fpsNum: Int, fpsDen: Int) {
        self.output = output; self.vtSession = vtSession
        self.fpsNum = Int32(fpsNum); self.fpsDen = Int32(fpsDen)
    }

    /// Returns the next compressed ProRes CMSampleBuffer, or nil when exhausted.
    func next() -> CMSampleBuffer? {
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        defer { frameIndex += 1 }
        guard let vt = vtSession else { return sample } // passthrough
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let pts = CMTime(value: CMTimeValue(frameIndex) * CMTimeValue(fpsDen),
                         timescale: fpsNum)
        let dur = CMTime(value: CMTimeValue(fpsDen), timescale: fpsNum)
        return vt.encode(pixelBuffer: pb, pts: pts, duration: dur)
    }

    /// Flushes and invalidates the optional re-encoding session.
    func finish() { vtSession?.flush(); vtSession?.invalidate() }
}

// MARK: - MXFAudioContext (PCM extraction for MXF)

/// Reads audio from source as float32 PCM and converts to MXF-compatible PCM per edit-unit cadence.
/// Ring-buffer approach: ~32 KB resident memory regardless of file length.
/// Allows the bridge handle to move between MXF pipeline tasks.
extension MXFBridge: @unchecked Sendable {}
/// Allows immutable bridge configuration to move between pipeline tasks.
extension MXFBridgeConfig: @unchecked Sendable {}

/// Streams decoded float PCM through a bounded ring and emits MXF sample groups.
final class MXFAudioContext: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var ring: [Float] = []
    private let sourceCh: Int
    private let outCh: Int
    private let ch0: Int
    private let bitDepth: Int
    private var exhausted = false

    /// Configures float PCM decoding and selects a contiguous output channel range.
    init(asset: AVAsset, audioTrack: AVAssetTrack,
         sourceCh: Int, ch0: Int, outCh: Int,
         sampleRate: Int, bitDepth: Int) throws {
        self.sourceCh = sourceCh; self.outCh = outCh
        self.ch0 = ch0; self.bitDepth = bitDepth
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: sourceCh,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        output.alwaysCopiesSampleData = false
        reader.add(output); reader.startReading()
    }

    /// Returns PCM data for `sampleCount` samples (24-bit/16-bit, interleaved, little-endian for MXF).
    func consumeFrame(sampleCount: Int) -> Data {
        // Refill
        while !exhausted && ring.count < sampleCount * sourceCh {
            guard let sb = output.copyNextSampleBuffer(),
                  let bb = CMSampleBufferGetDataBuffer(sb) else { exhausted = true; break }
            let len = CMBlockBufferGetDataLength(bb)
            let floatCount = len / MemoryLayout<Float>.size
            let prev = ring.count
            ring.append(contentsOf: repeatElement(Float(0), count: floatCount))
            _ = ring.withUnsafeMutableBufferPointer { ptr in
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len,
                    destination: UnsafeMutableRawPointer(ptr.baseAddress! + prev))
            }
        }
        // MXF PCM payloads are written as little-endian s16/s24 interleaved samples.
        let bps = (bitDepth + 7) / 8
        var pcm = Data(count: sampleCount * outCh * bps)
        let avail = ring.count / sourceCh
        let count = min(sampleCount, avail)
        pcm.withUnsafeMutableBytes { raw in
            let dst = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var off = 0
            for i in 0..<count {
                for c in 0..<outCh {
                    var s = ring[i * sourceCh + ch0 + c]
                    s = max(-1.0, min(1.0, s))
                    if bitDepth == 24 {
                        let v = s >= 0 ? Int32(s * 8388607.0) : Int32(s * 8388608.0)
                        dst[off]   = UInt8(truncatingIfNeeded: v)
                        dst[off+1] = UInt8(truncatingIfNeeded: v >> 8)
                        dst[off+2] = UInt8(truncatingIfNeeded: v >> 16)
                        off += 3
                    } else {
                        let v = Int16(s * 32767.0)
                        dst[off]   = UInt8(truncatingIfNeeded: v)
                        dst[off+1] = UInt8(truncatingIfNeeded: v >> 8)
                        off += 2
                    }
                }
            }
        }
        if count > 0 { ring.removeFirst(count * sourceCh) }
        return pcm
    }
}

/// Splits an interleaved PCM frame into consecutive channel groups.
private func splitInterleavedPCM(
    _ pcm: Data,
    sourceChannels: Int,
    groupChannelCounts: [Int],
    bitDepth: Int
) -> [Data] {
    let bps = (bitDepth + 7) / 8
    guard sourceChannels > 0, bps > 0, !groupChannelCounts.isEmpty else { return [] }
    if groupChannelCounts.count == 1, groupChannelCounts[0] == sourceChannels {
        return [pcm]
    }

    let sampleCount = pcm.count / max(sourceChannels * bps, 1)
    var result = groupChannelCounts.map { Data(count: sampleCount * $0 * bps) }
    pcm.withUnsafeBytes { srcRaw in
        guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        var sourceChannelStart = 0
        for groupIndex in result.indices {
            let groupChannels = groupChannelCounts[groupIndex]
            result[groupIndex].withUnsafeMutableBytes { dstRaw in
                guard let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var dstOffset = 0
                for sample in 0..<sampleCount {
                    let srcOffset = (sample * sourceChannels + sourceChannelStart) * bps
                    let availableChannels = max(0, min(groupChannels, sourceChannels - sourceChannelStart))
                    let byteCount = availableChannels * bps
                    if byteCount > 0 {
                        memcpy(dst + dstOffset, src + srcOffset, byteCount)
                    }
                    dstOffset += groupChannels * bps
                }
            }
            sourceChannelStart += groupChannels
        }
    }
    return result
}

// MARK: - CMSampleBuffer extension

extension CMSampleBuffer {
    /// Extract compressed data bytes (for MXF writing).
    var compressedData: Data? {
        guard let bb = CMSampleBufferGetDataBuffer(self) else { return nil }
        let len = CMBlockBufferGetDataLength(bb)
        var data = Data(count: len)
        _ = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len,
                                       destination: ptr.baseAddress!)
        }
        return data
    }
}

// MARK: - MXF Encode Pipeline

struct MXFEncodeResult: Sendable {
    let success: Bool
    let paths: [String]
    let framesEncoded: Int64
    let fps: Double
    let error: String?
    let sourceAudioChannels: Int
    let videoMXFUMID: Data          // 32 bytes Source Package UMID from video MXF
    let audioMXFUMIDs: [Data]       // 32 bytes each, per audio MXF (OP-Atom only)
}

/// Runs video encode, audio extraction, MXF writing, and OP-Atom audio fan-out.
func encodeMXF(
    asset: AVAsset,
    sourceURL: URL,
    outputDir: String,
    basename: String,
    quality: String,
    exportFormat: String,
    audioCHperFile: Int,
    audioOverrideURL: URL?,
    deleteSourceAudio: Bool,
    colorTransform: ColorTransformRequest?,
    outputVideoRaw: Bool = false
) async -> MXFEncodeResult {

    let emptyUMID = Data(repeating: 0, count: 32)
    guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
        return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                               error: "No video track", sourceAudioChannels: 0,
                               videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
    }
    let audioSourceAsset: AVAsset
    if let audioOverrideURL {
        audioSourceAsset = AVURLAsset(url: audioOverrideURL)
    } else {
        audioSourceAsset = asset
    }
    let audioTracks = (deleteSourceAudio && audioOverrideURL == nil)
        ? []
        : ((try? await audioSourceAsset.loadTracks(withMediaType: .audio)) ?? [])
    if audioOverrideURL != nil && audioTracks.isEmpty {
        return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                               error: "Replacement audio file has no audio track",
                               sourceAudioChannels: 0,
                               videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
    }

    let colorSpace = await detectColorSpace(from: videoTrack)
    let resolvedColorTransform: ResolvedColorTransform?
    do {
        resolvedColorTransform = try colorTransform.map {
            try resolveColorTransform(request: $0, sourceColorSpace: colorSpace)
        }
    } catch {
        return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                               error: error.localizedDescription, sourceAudioChannels: 0,
                               videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
    }
    let outputColorSpace = resolvedColorTransform?.outputColorSpace ?? colorSpace
    let fpsInfo    = await framerateInfo(from: asset)
    let (width, height) = await videoSize(from: asset)
    let totalFrames = await estimateFrameCount(asset: asset)
    let timecode    = await readTimecodeString(from: asset)
    let passthrough = (normalizedProResQuality(quality) == "pass")

    // Audio channel count from source
    var sourceAudioCh = 0
    if let aTrack = audioTracks.first,
       let fmts = try? await aTrack.load(.formatDescriptions), let fd = fmts.first {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd as CMAudioFormatDescription)
        sourceAudioCh = Int(asbd?.pointee.mChannelsPerFrame ?? 0)
    }
    if audioOverrideURL != nil && sourceAudioCh <= 0 {
        return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                               error: "Replacement audio channel count could not be determined",
                               sourceAudioChannels: 0,
                               videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
    }

    // Build MXFBridgeConfig
    let cfg = MXFBridgeConfig()
    cfg.proResVariant = Int32(proResVariantInt(quality))
    cfg.opFormat = (exportFormat == "opatom") ? 1 : 0
    cfg.width = Int32(width); cfg.height = Int32(height)
    cfg.fpsNum = Int32(fpsInfo.numerator); cfg.fpsDen = Int32(fpsInfo.denominator)
    cfg.isDropFrame = fpsInfo.isDropFrame
    cfg.startTimecode = timecode
    cfg.totalFrames = totalFrames
    cfg.audioBitDepth = 24; cfg.audioSampleRate = 48000
    cfg.colorPrimaries = outputColorSpace.mxfPrimaries
    cfg.transferFunction = outputColorSpace.mxfTransfer
    cfg.codingEquations = outputColorSpace.mxfMatrix

    let audioChannels = sourceAudioCh > 0 ? sourceAudioCh : 0
    let audioChannelsPerFile = max(audioCHperFile, 1)
    let isOP1a = (exportFormat != "opatom")

    if audioChannels > 0 {
        if !isOP1a {
            var chs: [NSNumber] = []; var ch = 0
            while ch < audioChannels {
                let cnt = min(audioChannelsPerFile, audioChannels - ch)
                chs.append(NSNumber(value: cnt)); ch += cnt
            }
            cfg.audioChannelCounts = chs
        } else {
            cfg.audioChannelCounts = [NSNumber(value: audioChannels)]
        }
    } else { cfg.audioChannelCounts = [] }

    // Output path
    let outPath: String
    if isOP1a { outPath = outputDir + "/" + basename + ".mxf" }
    else      { outPath = outputDir + "/" + basename + "_v.mxf" }

    let rawVideoWriter: EncodedVideoRawWriter?
    if outputVideoRaw {
        do {
            rawVideoWriter = try EncodedVideoRawWriter(
                encodedOutputURL: URL(fileURLWithPath: outPath),
                quality: quality
            )
        } catch {
            return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                                   error: error.localizedDescription, sourceAudioChannels: 0,
                                   videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
        }
    } else {
        rawVideoWriter = nil
    }

    // Open MXFBridge
    let bridge = MXFBridge()
    guard bridge.open(withPath: outPath, config: cfg) else {
        return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                               error: bridge.lastError ?? "open failed", sourceAudioChannels: 0,
                               videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
    }

    // Progress bar (matches MOV style)
    let progress = totalFrames > 0 ? ProgressBar(total: Int(totalFrames)) : nil

    // Setup video reader
    do {
        let reader = try AVAssetReader(asset: asset)
        let vidSettings: [String: Any]? = passthrough ? nil : proResReaderOutputSettings(quality)
        let vidOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: vidSettings)
        vidOutput.alwaysCopiesSampleData = false
        reader.add(vidOutput)

        // VT session
        var vtSession: ProResSession? = nil
        if !passthrough {
            vtSession = try ProResSession(
                width: width, height: height,
                codecType: proResCodecType(quality),
                fpsHint: Int(fpsInfo.fps.rounded()),
                colorSpace: outputColorSpace)
        }
        let metalColorPipeline = try resolvedColorTransform.map {
            try MetalColorPipeline(
                transform: $0,
                width: width,
                height: height,
                pixelFormat: colorPipelinePixelFormat(for: quality)
            )
        }
        let metalColorPipelineRef = metalColorPipeline.map(SendableRef.init)

        // Audio contexts (OP-1a only; OP-Atom audio is separate files)
        var audioCtxs: [MXFAudioContext] = []
        if isOP1a && audioChannels > 0, let aTrack = audioTracks.first {
            var ch0 = 0
            for chNum in cfg.audioChannelCounts {
                let outCh = chNum.intValue
                let ctx = try MXFAudioContext(
                    asset: audioSourceAsset, audioTrack: aTrack,
                    sourceCh: sourceAudioCh > 0 ? sourceAudioCh : 2,
                    ch0: min(ch0, max(sourceAudioCh - 1, 0)),
                    outCh: outCh, sampleRate: 48000, bitDepth: 24)
                audioCtxs.append(ctx)
                ch0 += outCh
            }
        }

        reader.startReading()

        // ── 3-Stage async pipeline ──────────────────────────────────────────
        //
        // Stage 1 (readerTask):    reader output → pixelChannel  (or compressed → compressedChannel for passthrough)
        // Stage 2 (encoderTask):   pixelChannel  → VT submit + audio FIFO
        // Stage 2b (drainTask):    VT output + audio FIFO → compressedChannel
        // Stage 3 (writerTask):    compressedChannel → MXFBridge.writeFrameVideo
        //
        // Back-pressure: capacity=4 keeps at most ~32 MB of pixel buffers and ~16 MB of
        // compressed frames in flight simultaneously.

        let channelCapacity = proResPipelineChannelCapacity(width: width, height: height, quality: quality)
        let pixelChannel      = AsyncChannel<SendablePixelBuffer>(capacity: channelCapacity)
        let compressedChannel = AsyncChannel<(SendableSampleBuffer, [Data])>(capacity: channelCapacity)
        let audioChannel = AsyncChannel<[Data]>(capacity: channelCapacity)
        let vtRef = vtSession.map(SendableRef.init)
        if !passthrough {
            vtRef?.value.enableAsyncMode(channelCapacity: channelCapacity)
        }

        // Stage 1 — read
        let readerTask = Task<Void, Error> {
            if passthrough {
                var frameIndex: Int64 = 0
                while true {
                    guard let sample: SendableSampleBuffer = autoreleasepool(invoking: {
                        guard let sample = vidOutput.copyNextSampleBuffer() else { return nil }
                        return SendableSampleBuffer(buf: sample)
                    }) else { break }
                    var chunks: [Data] = []
                    for context in audioCtxs {
                        let sampleCount = mxf_samples_for_frame(
                            frameIndex,
                            Int32(fpsInfo.numerator),
                            Int32(fpsInfo.denominator),
                            48_000
                        )
                        chunks.append(context.consumeFrame(sampleCount: Int(sampleCount)))
                    }
                    await compressedChannel.sendAsync((sample, chunks))
                    frameIndex += 1
                }
                compressedChannel.finish()
            } else {
                while true {
                    let wrapped: SendablePixelBuffer? = autoreleasepool {
                        guard let sample = vidOutput.copyNextSampleBuffer(),
                              let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
                        return SendablePixelBuffer(buf: pb)
                    }
                    guard let wrapped else { break }
                    await pixelChannel.sendAsync(wrapped)
                }
                pixelChannel.finish()
            }
        }

        // Stage 2b — forward VT output as soon as it is produced
        let drainTask = Task<Void, Error> {
            guard !passthrough else { return }
            if let outCh = vtRef?.value.outputChannel {
                for await wrapped in outCh {
                    let audio = await audioChannel.next() ?? []
                    await compressedChannel.sendAsync((wrapped, audio))
                }
            }
            compressedChannel.finish()
        }

        // Stage 2 — VT encode
        let encoderTask = Task<Void, Error> {
            guard !passthrough else { return }

            var frameIdx: Int64 = 0

            for await spb in pixelChannel {
                let pts = CMTime(value: CMTimeValue(frameIdx) * CMTimeValue(fpsInfo.denominator),
                                 timescale: CMTimeScale(fpsInfo.numerator))
                let dur = CMTime(value: CMTimeValue(fpsInfo.denominator),
                                 timescale: CMTimeScale(fpsInfo.numerator))
                let pb: CVPixelBuffer
                do {
                    pb = try metalColorPipelineRef?.value.process(spb.buf, pts: pts) ?? spb.buf
                } catch {
                    pixelChannel.finish()
                    audioChannel.finish()
                    compressedChannel.finish()
                    vtRef?.value.flushAsync()
                    throw error
                }
                guard vtRef?.value.submit(pixelBuffer: pb, pts: pts, duration: dur) == true else {
                    pixelChannel.finish()
                    audioChannel.finish()
                    compressedChannel.finish()
                    vtRef?.value.flushAsync()
                    throw NSError(
                        domain: "encodeMXF",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "VT submit failed"]
                    )
                }

                var chunks: [Data] = []
                for ctx in audioCtxs {
                    let n = mxf_samples_for_frame(frameIdx, Int32(fpsInfo.numerator),
                                                  Int32(fpsInfo.denominator), 48000)
                    chunks.append(ctx.consumeFrame(sampleCount: Int(n)))
                }
                await audioChannel.sendAsync(chunks)
                frameIdx += 1
            }

            audioChannel.finish()
            vtRef?.value.flushAsync()
        }

        // Stage 3 — write
        let writerTask = Task<(Int64, Double), Error> {
            let t0 = CFAbsoluteTimeGetCurrent()
            var written: Int64 = 0
            for await (sampleBuffer, audioChunks) in compressedChannel {
                let ok = bridge.writeFrameSampleBuffer(sampleBuffer.buf, audio: audioChunks)
                if !ok {
                    throw NSError(
                        domain: "encodeMXF",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Video MXF write failed: \(bridge.lastError ?? "unknown")"]
                    )
                }
                try rawVideoWriter?.write(sampleBuffer.buf)
                written += 1
                progress?.increment()
            }
            progress?.finish()
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            return (written, elapsed > 0 ? Double(written) / elapsed : 0)
        }

        // Wait for all stages
        try await readerTask.value
        try await encoderTask.value
        try await drainTask.value
        vtRef?.value.invalidate()
        let (written, fps) = try await writerTask.value
        _ = written
        try rawVideoWriter?.finish()

        guard bridge.close() else {
            return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                                   error: bridge.lastError ?? "close failed",
                                   sourceAudioChannels: audioChannels,
                                   videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
        }

        let encoded = bridge.frameCount
        let videoUMID = bridge.sourcePackageUMID ?? emptyUMID

        // ── OP-Atom: encode audio to separate MXF files ──
        var allPaths = [outPath]
        if let rawVideoWriter {
            allPaths.append(rawVideoWriter.outputURL.path)
        }
        var audioUMIDs: [Data] = []
        if !isOP1a && audioChannels > 0, let aTrack = audioTracks.first {
            let groupCounts = cfg.audioChannelCounts.map { $0.intValue }
            let contextSourceChannels = sourceAudioCh > 0 ? sourceAudioCh : audioChannels
            let ctx = try MXFAudioContext(
                asset: audioSourceAsset, audioTrack: aTrack,
                sourceCh: contextSourceChannels,
                ch0: 0, outCh: contextSourceChannels,
                sampleRate: 48000, bitDepth: 24)

            var audioBridges: [MXFBridge] = []
            var audioPaths: [String] = []
            for (trackIdx, outCh) in groupCounts.enumerated() {
                let audioPath = outputDir + "/" + basename + "_a\(trackIdx + 1).mxf"

                let audioCfg = MXFBridgeConfig()
                audioCfg.proResVariant = 0
                audioCfg.opFormat = 1  // OPAtom
                audioCfg.width = 0; audioCfg.height = 0  // audio-only flag
                audioCfg.fpsNum = Int32(fpsInfo.numerator)
                audioCfg.fpsDen = Int32(fpsInfo.denominator)
                audioCfg.isDropFrame = fpsInfo.isDropFrame
                audioCfg.startTimecode = timecode
                audioCfg.totalFrames = encoded
                audioCfg.audioBitDepth = 24; audioCfg.audioSampleRate = 48000
                audioCfg.audioChannelCounts = [NSNumber(value: outCh)]

                let audioBridge = MXFBridge()
                guard audioBridge.open(withPath: audioPath, config: audioCfg) else {
                    return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                                           error: "Audio MXF open failed: \(audioBridge.lastError ?? "")",
                                           sourceAudioChannels: audioChannels,
                                           videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
                }
                audioBridges.append(audioBridge)
                audioPaths.append(audioPath)
            }

            for frame in 0..<encoded {
                let n = mxf_samples_for_frame(frame, Int32(fpsInfo.numerator),
                                              Int32(fpsInfo.denominator), 48000)
                let audioData = ctx.consumeFrame(sampleCount: Int(n))
                let chunks = splitInterleavedPCM(
                    audioData,
                    sourceChannels: contextSourceChannels,
                    groupChannelCounts: groupCounts,
                    bitDepth: 24)
                for i in audioBridges.indices {
                    let chunk = i < chunks.count ? chunks[i] : Data()
                    guard audioBridges[i].writeFrameVideo(nil, videoSize: 0, audio: [chunk]) else {
                        return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                                               error: "Audio MXF write failed: \(audioBridges[i].lastError ?? "")",
                                               sourceAudioChannels: audioChannels,
                                               videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
                    }
                }
            }

            for i in audioBridges.indices {
                guard audioBridges[i].close() else {
                    return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                                           error: "Audio MXF close failed: \(audioBridges[i].lastError ?? "")",
                                           sourceAudioChannels: audioChannels,
                                           videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
                }
                audioUMIDs.append(audioBridges[i].sourcePackageUMID ?? emptyUMID)
                allPaths.append(audioPaths[i])
            }
        }

        return MXFEncodeResult(success: true, paths: allPaths,
                               framesEncoded: encoded, fps: fps, error: nil,
                               sourceAudioChannels: audioChannels,
                               videoMXFUMID: videoUMID, audioMXFUMIDs: audioUMIDs)
    } catch {
        return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                               error: error.localizedDescription, sourceAudioChannels: 0,
                               videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
    }
}
