// BitstreamProcess.swift — VTCompressionSession ProRes encoder + audio/color pipeline
// Handles:
//  - VTCompressionSession creation & per-frame encode (ProRes)
//  - Rigorous color-space detection & propagation (BT.709/BT.2020/P3/PQ/HLG)
//  - Audio PCM extraction (24-bit 48 kHz LE) for MXF
//  - SMPTE audio cadence
//  - MXF encode pipeline (VT → mxf::Encoder via MXFBridge)
//  - Source media analysis helpers (framerate, timecode, channel count, dimensions)
//
// Memory model: strictly one-frame-at-a-time in the encode loop.
// For 4 h+ files only ~2 MB resides in memory at any moment.

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox

private let kCMVideoCodecType_AppleProRes4444XQ: CMVideoCodecType = 0x61703478 // 'ap4x'

// MARK: - MXF Color UL Constants (SMPTE 377-1)
// Must match mxf_enc.cpp exactly.

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

enum DolbyVisionHEVCProfile: String, Sendable {
    case profile81 = "81"

    init?(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "81", "8.1":
            self = .profile81
        default:
            return nil
        }
    }

    var doviToolProfileArgument: String {
        switch self {
        case .profile81: return "8.1"
        }
    }

    var displayName: String {
        switch self {
        case .profile81: return "8.1"
        }
    }
}

struct HEVCEncodeOptions: Sendable {
    let bitrateMbps: Double
    let dvProfile: DolbyVisionHEVCProfile?

    var bitrateBitsPerSecond: Int {
        Int((bitrateMbps * 1_000_000.0).rounded())
    }
}

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

func framerateInfo(from asset: AVAsset) async -> FramerateInfo {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first,
          let rate  = try? await track.load(.nominalFrameRate) else {
        return FramerateInfo(numerator: 25, denominator: 1, isDropFrame: false)
    }
    let fps = Double(rate)
    guard fps.isFinite, fps > 0, fps < 1000 else {
        return FramerateInfo(numerator: 25, denominator: 1, isDropFrame: false)
    }
    let known: [(Double, Int, Int, Bool)] = [
        (23.976, 24000, 1001, false), (24.0, 24, 1, false),
        (25.0, 25, 1, false),         (29.97, 30000, 1001, true),
        (30.0, 30, 1, false),          (50.0, 50, 1, false),
        (59.94, 60000, 1001, true),    (60.0, 60, 1, false),
    ]
    for (ref, num, den, df) in known {
        if abs(fps - ref) < 0.02 { return FramerateInfo(numerator: num, denominator: den, isDropFrame: df) }
    }
    return FramerateInfo(numerator: max(Int(fps.rounded()), 1), denominator: 1, isDropFrame: false)
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
           let bb = CMSampleBufferGetDataBuffer(sample) {
            var length = 0; var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &ptr)
            if length >= 4, let p = ptr {
                let N = Int(Int32(bigEndian: p.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }))
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
    "proxy", "422lt", "422", "422hq", "4444", "4444xq", "pass", "hevc"
]

func normalizedProResQuality(_ quality: String) -> String {
    quality.lowercased()
}

func proResQualityValidationError(_ quality: String) -> String? {
    let normalized = normalizedProResQuality(quality)
    if supportedProResQualities.contains(normalized) {
        return nil
    }
    if normalized == "xq" {
        return "Unsupported quality '\(quality)'. Use '4444xq' explicitly."
    }
    return "Unsupported quality '\(quality)'. Expected one of: proxy, 422lt, 422, 422hq, 4444, 4444xq, pass, hevc."
}

func isHEVCQuality(_ quality: String) -> Bool {
    normalizedProResQuality(quality) == "hevc"
}

func is4444FamilyQuality(_ quality: String) -> Bool {
    let q = normalizedProResQuality(quality)
    return q == "4444" || q == "4444xq"
}

func proResReaderOutputSettings(_ quality: String) -> [String: Any] {
    let pixelFormat: OSType
    if isHEVCQuality(quality) {
        pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    } else if is4444FamilyQuality(quality) {
        pixelFormat = kCVPixelFormatType_32BGRA
    } else {
        pixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    }
    return [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
}

func proResCodecType(_ quality: String) -> CMVideoCodecType {
    switch normalizedProResQuality(quality) {
    case "hevc":    return kCMVideoCodecType_HEVC
    case "proxy":   return kCMVideoCodecType_AppleProRes422Proxy
    case "422lt":   return kCMVideoCodecType_AppleProRes422LT
    case "422":     return kCMVideoCodecType_AppleProRes422
    case "4444":    return kCMVideoCodecType_AppleProRes4444
    case "4444xq":  return kCMVideoCodecType_AppleProRes4444XQ
    default:        return kCMVideoCodecType_AppleProRes422HQ
    }
}

func proResVariantInt(_ quality: String) -> Int {
    switch normalizedProResQuality(quality) {
    case "proxy":  return 1; case "422lt": return 2
    case "422":    return 3; case "422hq": return 4
    case "4444":   return 5; case "4444xq": return 6
    default:       return 4
    }
}

func proResPipelineChannelCapacity(width: Int, height: Int, quality: String) -> Int {
    let bytesPerPixel = isHEVCQuality(quality) ? 2 : 4
    let frameBytes = max(width * height * bytesPerPixel, 1)
    let targetBufferedBytes = 128 * 1024 * 1024
    let memoryLimited = max(4, min(targetBufferedBytes / frameBytes, 8))
    let coreLimited = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 8))
    return min(memoryLimited, coreLimited)
}

private func fourCCString(_ code: FourCharCode) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff),
    ].map { ($0 >= 32 && $0 < 127) ? $0 : UInt8(ascii: ".") }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

private func proResSourcePixelFormat(codecType: CMVideoCodecType) -> OSType {
    if codecType == kCMVideoCodecType_HEVC {
        return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
    switch codecType {
    case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
        return kCVPixelFormatType_32BGRA
    default:
        return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    }
}

private func proResEncoderImageBufferAttributes(width: Int, height: Int, codecType: CMVideoCodecType) -> CFDictionary {
    [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: proResSourcePixelFormat(codecType: codecType)),
        kCVPixelBufferWidthKey as String: NSNumber(value: width),
        kCVPixelBufferHeightKey as String: NSNumber(value: height),
    ] as CFDictionary
}

private func proResHardwareEncoderSpecification() -> CFDictionary {
    [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: kCFBooleanTrue as Any
    ] as CFDictionary
}

private func hevcHardwareEncoderSpecification() -> CFDictionary {
    [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: kCFBooleanTrue as Any
    ] as CFDictionary
}

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

// MARK: - AsyncChannel

/// Sendable wrappers for CoreMedia/CoreVideo types that lack conformance on macOS 13.
struct SendableSampleBuffer: @unchecked Sendable { let buf: CMSampleBuffer }
struct SendablePixelBuffer: @unchecked Sendable { let buf: CVPixelBuffer }

/// Lightweight bounded FIFO channel for Swift async/await pipelines.
/// Producers back-pressure when full; consumers suspend when empty.
final class AsyncChannel<T: Sendable>: @unchecked Sendable {
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

extension AsyncChannel: AsyncSequence {
    typealias Element = T
    struct AsyncIterator: AsyncIteratorProtocol {
        let channel: AsyncChannel<T>
        mutating func next() async -> T? { await channel.next() }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(channel: self) }
}

// MARK: - ProResSession (VTCompressionSession wrapper)

/// Refcon for the VT C callback: routes to async channel or sync box.
private final class VTCallbackRefcon: @unchecked Sendable {
    var sample: CMSampleBuffer?
    let syncLock = NSLock()
    var asyncChannel: AsyncChannel<SendableSampleBuffer>?
    private let asyncStateLock = NSLock()
    private var asyncSubmittedCount: Int64 = 0
    private var asyncCompletedCount: Int64 = 0
    private var asyncDeliveryPendingCount: Int64 = 0
    private var asyncFlushRequested = false
    private var asyncChannelFinished = false

    func configureAsyncChannel(_ channel: AsyncChannel<SendableSampleBuffer>) {
        asyncStateLock.lock()
        asyncChannel = channel
        asyncSubmittedCount = 0
        asyncCompletedCount = 0
        asyncDeliveryPendingCount = 0
        asyncFlushRequested = false
        asyncChannelFinished = false
        asyncStateLock.unlock()
    }

    func willSubmitAsyncFrame() {
        asyncStateLock.lock()
        asyncSubmittedCount += 1
        asyncStateLock.unlock()
    }

    func revertAsyncSubmission() -> AsyncChannel<SendableSampleBuffer>? {
        asyncStateLock.lock()
        asyncSubmittedCount = max(0, asyncSubmittedCount - 1)
        let channel = finishChannelIfDrainedLocked()
        asyncStateLock.unlock()
        return channel
    }

    func completeAsyncFrame() -> AsyncChannel<SendableSampleBuffer>? {
        asyncStateLock.lock()
        asyncCompletedCount += 1
        let channel = finishChannelIfDrainedLocked()
        asyncStateLock.unlock()
        return channel
    }

    func requestAsyncFlush() -> AsyncChannel<SendableSampleBuffer>? {
        asyncStateLock.lock()
        asyncFlushRequested = true
        let channel = finishChannelIfDrainedLocked()
        asyncStateLock.unlock()
        return channel
    }

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

    private func completeAsyncDelivery() -> AsyncChannel<SendableSampleBuffer>? {
        asyncStateLock.lock()
        asyncDeliveryPendingCount = max(0, asyncDeliveryPendingCount - 1)
        let channel = finishChannelIfDrainedLocked()
        asyncStateLock.unlock()
        return channel
    }

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
    private let hevcMasteringDisplayColorVolume: Data?
    private let hevcContentLightLevelInfo: Data?

    init(width: Int, height: Int, codecType: CMVideoCodecType,
         fpsHint: Int, colorSpace: SourceColorSpace?,
         hevcOptions: HEVCEncodeOptions? = nil) throws {
        var sess: VTCompressionSession?
        let rcPtr = Unmanaged.passUnretained(rc).toOpaque()
        let isHEVC = (codecType == kCMVideoCodecType_HEVC)
        isHEVCSession = isHEVC
        hevcMasteringDisplayColorVolume = colorSpace?.masteringDisplayColorVolume
        hevcContentLightLevelInfo = colorSpace?.contentLightLevelInfo
        let encoderSpecification = isHEVC
            ? hevcHardwareEncoderSpecification()
            : proResHardwareEncoderSpecification()
        let imageBufferAttributeCandidates: [CFDictionary?] = [
            proResEncoderImageBufferAttributes(width: width, height: height, codecType: codecType),
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        let n = NSNumber(value: fpsHint)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: n)
        if let p = colorSpace?.primaries {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: p as CFString)
        }
        if let t = colorSpace?.transfer {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: t as CFString)
        }
        if let m = colorSpace?.matrix {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: m as CFString)
        }
        if isHEVC {
            guard let hevcOptions else {
                throw NSError(domain: "ProResSession", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "HEVC encode requires bitrate options."])
            }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                                 value: kCMFormatDescriptionColorPrimaries_ITU_R_2020)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                                 value: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                 value: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
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
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_HEVC_Main10_AutoLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: NSNumber(value: hevcOptions.bitrateBitsPerSecond))
            let bytesPerSecond = max(1, hevcOptions.bitrateBitsPerSecond / 8)
            let dataRateLimits = [
                NSNumber(value: bytesPerSecond),
                NSNumber(value: 1)
            ] as CFArray
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: dataRateLimits)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: NSNumber(value: max(fpsHint * 2, 1)))
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                 value: NSNumber(value: 2))
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        if isHEVC,
           let usingHardware = vtSessionBooleanProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder
           ),
           !usingHardware {
            throw NSError(domain: "ProResSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "VideoToolbox created a software HEVC encoder; hardware HEVC is required."])
        }
    }

    /// Switch to async mode: creates the outputChannel and routes VT callback to it.
    /// Must be called before the first `submit()`.
    func enableAsyncMode(channelCapacity: Int = 4) {
        let ch = AsyncChannel<SendableSampleBuffer>(capacity: channelCapacity)
        outputChannel = ch
        rc.configureAsyncChannel(ch)
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
        return st == noErr
    }

    /// Flush remaining frames, then close the outputChannel.
    func flushAsync() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        rc.requestAsyncFlush()?.finish()
    }

    func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        if session != nil { VTCompressionSessionInvalidate(session); session = nil }
    }

    private func attachHEVCMetadataIfNeeded(to pixelBuffer: CVPixelBuffer) {
        guard isHEVCSession else { return }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate)
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

    func finish() { vtSession?.flush(); vtSession?.invalidate() }
}

// MARK: - MXFAudioContext (PCM extraction for MXF)

/// Reads audio from source as float32 PCM and converts to MXF-compatible PCM per edit-unit cadence.
/// Ring-buffer approach: ~32 KB resident memory regardless of file length.
extension MXFBridge: @unchecked Sendable {}
extension MXFBridgeConfig: @unchecked Sendable {}

final class MXFAudioContext: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var ring: [Float] = []
    private let sourceCh: Int
    private let outCh: Int
    private let ch0: Int
    private let bitDepth: Int
    private var exhausted = false

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

func encodeMXF(
    asset: AVAsset,
    sourceURL: URL,
    outputDir: String,
    basename: String,
    quality: String,
    exportFormat: String,
    audioCHperFile: Int,
    audioOverrideURL: URL?
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
    let audioTracks = (try? await audioSourceAsset.loadTracks(withMediaType: .audio)) ?? []
    if audioOverrideURL != nil && audioTracks.isEmpty {
        return MXFEncodeResult(success: false, paths: [], framesEncoded: 0, fps: 0,
                               error: "Replacement audio file has no audio track",
                               sourceAudioChannels: 0,
                               videoMXFUMID: emptyUMID, audioMXFUMIDs: [])
    }

    let colorSpace = await detectColorSpace(from: videoTrack)
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
    cfg.colorPrimaries = colorSpace.mxfPrimaries
    cfg.transferFunction = colorSpace.mxfTransfer
    cfg.codingEquations = colorSpace.mxfMatrix

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
                colorSpace: colorSpace)
        }

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
        // Stage 1 (readerTask):    AVAssetReader → pixelChannel  (or compressed → compressedChannel for passthrough)
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
                while true {
                    let payload: (SendableSampleBuffer, [Data])? = autoreleasepool {
                        guard let sample = vidOutput.copyNextSampleBuffer() else { return nil }
                        return (SendableSampleBuffer(buf: sample), [])
                    }
                    guard let payload else { break }
                    await compressedChannel.sendAsync(payload)
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
                let pb = spb.buf
                let pts = CMTime(value: CMTimeValue(frameIdx) * CMTimeValue(fpsInfo.denominator),
                                 timescale: CMTimeScale(fpsInfo.numerator))
                let dur = CMTime(value: CMTimeValue(fpsInfo.denominator),
                                 timescale: CMTimeScale(fpsInfo.numerator))
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
