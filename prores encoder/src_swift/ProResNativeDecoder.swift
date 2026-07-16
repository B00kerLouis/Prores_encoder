// Decodes compressed ProRes samples and normalizes supported decoder outputs to
// 10-bit 4:2:0 bi-planar pixel buffers for compressed-output encoders.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Synchronizes one asynchronous decompression callback with its submitting thread.
private final class NativeDecodeWaiter {
    let semaphore = DispatchSemaphore(value: 0)
    var status: OSStatus = noErr
    var pixelBuffer: CVPixelBuffer?
}

/// Pixel layouts accepted from the platform decompression session.
private enum ProResNativeDecodeMode {
    case p010
    case x422
    case y416
}

/// Owns the compressed reader, decompression session, and format-conversion pool.
final class ProResNativeDecodeSession: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let pixelBufferPool: CVPixelBufferPool
    private let width: Int
    private let height: Int
    private var session: VTDecompressionSession?
    private var decodeMode: ProResNativeDecodeMode?
    private var pendingPixelBuffer: CVPixelBuffer?

    /// Opens compressed track output and probes decoder formats using the first sample.
    init(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        formatDescription: CMFormatDescription,
        width: Int,
        height: Int
    ) throws {
        guard width > 0, height > 0 else {
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Native ProRes decode requires positive frame dimensions."]
            )
        }
        guard CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video else {
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Native ProRes decode requires a video format description."]
            )
        }

        self.width = width
        self.height = height
        self.reader = try AVAssetReader(asset: asset)
        self.output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        self.output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetReader cannot add a compressed ProRes output for native decode."]
            )
        }
        reader.add(output)

        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 2
            ] as CFDictionary,
            [
                kCVPixelBufferPixelFormatTypeKey as String:
                    NSNumber(value: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                kCVPixelBufferWidthKey as String: NSNumber(value: width),
                kCVPixelBufferHeightKey as String: NSNumber(value: height)
            ] as CFDictionary,
            &pool
        )
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw NSError(
                domain: "AV1Encode",
                code: Int(poolStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not create the native ProRes decoder pixel buffer pool: \(poolStatus)."
                ]
            )
        }
        self.pixelBufferPool = pool

        guard reader.startReading() else {
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Native ProRes reader could not start: \(reader.error?.localizedDescription ?? "unknown reader error")."
                ]
            )
        }

        guard let firstSample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw NSError(
                    domain: "AV1Encode",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Native ProRes decode could not read the first compressed sample: \(reader.error?.localizedDescription ?? "unknown reader error")."
                    ]
                )
            }
            return
        }

        try configureSessionAndDecodeFirstFrame(
            firstSample: firstSample,
            formatDescription: formatDescription
        )
    }

    /// Cancels pending reads and invalidates the decompression session.
    deinit {
        reader.cancelReading()
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Returns the next decoded P010 frame, or nil after the compressed track ends.
    func nextPixelBuffer() throws -> CVPixelBuffer? {
        if let pendingPixelBuffer {
            self.pendingPixelBuffer = nil
            return pendingPixelBuffer
        }

        guard let session, decodeMode != nil else {
            if reader.status == .failed {
                throw NSError(
                    domain: "AV1Encode",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Native ProRes decode failed before creating the decompression session: \(reader.error?.localizedDescription ?? "unknown reader error")."
                    ]
                )
            }
            return nil
        }

        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw NSError(
                    domain: "AV1Encode",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Native ProRes reader failed: \(reader.error?.localizedDescription ?? "unknown reader error")."
                    ]
                )
            }
            return nil
        }

        let decoded = try decode(sampleBuffer: sample, with: session)
        return try convertToP010(decoded)
    }

    /// Tries supported output layouts in preference order and retains the first result.
    private func configureSessionAndDecodeFirstFrame(
        firstSample: CMSampleBuffer,
        formatDescription: CMFormatDescription
    ) throws {
        let candidateFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_4444AYpCbCr16
        ]

        var lastError: Error?
        for candidate in candidateFormats {
            do {
                let createdSession = try makeSession(
                    formatDescription: formatDescription,
                    pixelFormat: candidate
                )
                let firstDecoded = try decode(sampleBuffer: firstSample, with: createdSession)
                self.session = createdSession
                self.decodeMode = try mode(for: CVPixelBufferGetPixelFormatType(firstDecoded))
                self.pendingPixelBuffer = try convertToP010(firstDecoded)
                return
            } catch {
                lastError = error
                if let session {
                    VTDecompressionSessionInvalidate(session)
                    self.session = nil
                }
            }
        }

        throw lastError ?? NSError(
            domain: "AV1Encode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Native ProRes decode could not create a usable VTDecompressionSession."
            ]
        )
    }

    /// Creates a decompression session configured for one candidate pixel layout.
    private func makeSession(
        formatDescription: CMFormatDescription,
        pixelFormat: OSType
    ) throws -> VTDecompressionSession {
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { _, sourceFrameRefCon, status, _, imageBuffer, _, _ in
                guard let sourceFrameRefCon else { return }
                let waiter = Unmanaged<NativeDecodeWaiter>
                    .fromOpaque(sourceFrameRefCon)
                    .takeUnretainedValue()
                waiter.status = status
                waiter.pixelBuffer = imageBuffer
                waiter.semaphore.signal()
            },
            decompressionOutputRefCon: nil
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
                kCVPixelBufferWidthKey as String: NSNumber(value: width),
                kCVPixelBufferHeightKey as String: NSNumber(value: height)
            ] as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(
                domain: "AV1Encode",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not create a VTDecompressionSession for pixel format \(proResDecodeFourCCString(pixelFormat)): \(status)."
                ]
            )
        }
        return session
    }

    /// Submits one sample and waits for its callback with bounded timeout handling.
    private func decode(
        sampleBuffer: CMSampleBuffer,
        with session: VTDecompressionSession
    ) throws -> CVPixelBuffer {
        let waiter = NativeDecodeWaiter()
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: Unmanaged.passUnretained(waiter).toOpaque(),
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            throw NSError(
                domain: "AV1Encode",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "Native ProRes decode submission failed: \(status)."
                ]
            )
        }

        if waiter.semaphore.wait(timeout: .now() + 5) == .timedOut {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if waiter.semaphore.wait(timeout: .now() + 1) == .timedOut {
                throw NSError(
                    domain: "AV1Encode",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Native ProRes decode timed out waiting for VT output."]
                )
            }
        }

        guard waiter.status == noErr, let pixelBuffer = waiter.pixelBuffer else {
            throw NSError(
                domain: "AV1Encode",
                code: Int(waiter.status),
                userInfo: [NSLocalizedDescriptionKey:
                    "Native ProRes decode failed while producing a pixel buffer: \(waiter.status)."
                ]
            )
        }
        return pixelBuffer
    }

    /// Maps a decoder pixel-format code to the corresponding conversion path.
    private func mode(for pixelFormat: OSType) throws -> ProResNativeDecodeMode {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return .p010
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
            return .x422
        case kCVPixelFormatType_4444AYpCbCr16:
            return .y416
        default:
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Native ProRes decoder returned unsupported pixel format \(proResDecodeFourCCString(pixelFormat))."
                ]
            )
        }
    }

    /// Passes through P010 or converts 4:2:2 and 4:4:4 decoder output to P010.
    private func convertToP010(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        switch try mode(for: CVPixelBufferGetPixelFormatType(source)) {
        case .p010:
            return source
        case .x422:
            return try downsampleX422ToP010(source)
        case .y416:
            return try convertY416ToP010(source)
        }
    }

    /// Allocates a destination from the pool, flushing excess buffers before fallback.
    private func makeDestinationP010PixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &pixelBuffer
        )
        if status != kCVReturnSuccess || pixelBuffer == nil {
            CVPixelBufferPoolFlush(pixelBufferPool, .excessBuffers)
            status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pixelBufferPool,
                &pixelBuffer
            )
        }
        if status != kCVReturnSuccess || pixelBuffer == nil {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                nil,
                &pixelBuffer
            )
        }
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(
                domain: "AV1Encode",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not allocate a P010 pixel buffer for native ProRes decode: \(status)."
                ]
            )
        }
        return pixelBuffer
    }

    /// Copies 10-bit luma and vertically averages 4:2:2 chroma into 4:2:0.
    private func downsampleX422ToP010(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let destination = try makeDestinationP010PixelBuffer()

        let sourceLockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLockStatus == kCVReturnSuccess else {
            throw NSError(
                domain: "AV1Encode",
                code: Int(sourceLockStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not lock the native x422 ProRes source buffer: \(sourceLockStatus)."
                ]
            )
        }
        let destinationLockStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLockStatus == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            throw NSError(
                domain: "AV1Encode",
                code: Int(destinationLockStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not lock the native ProRes P010 destination buffer: \(destinationLockStatus)."
                ]
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard CVPixelBufferGetPlaneCount(source) == 2,
              CVPixelBufferGetPlaneCount(destination) == 2,
              let sourceLuma = CVPixelBufferGetBaseAddressOfPlane(source, 0),
              let sourceChroma = CVPixelBufferGetBaseAddressOfPlane(source, 1),
              let destinationLuma = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
              let destinationChroma = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected x422 pixel buffer layout during native ProRes decode."]
            )
        }

        let sourceLumaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let sourceChromaStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let destinationLumaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        let destinationChromaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        let minimum10BitRowBytes = width * MemoryLayout<UInt16>.stride
        guard sourceLumaStride >= minimum10BitRowBytes,
              sourceChromaStride >= minimum10BitRowBytes,
              destinationLumaStride >= minimum10BitRowBytes,
              destinationChromaStride >= minimum10BitRowBytes else {
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Native x422/P010 pixel buffer row strides are smaller than the active image width."
                ]
            )
        }

        for row in 0..<height {
            memcpy(
                destinationLuma.advanced(by: row * destinationLumaStride),
                sourceLuma.advanced(by: row * sourceLumaStride),
                min(sourceLumaStride, destinationLumaStride)
            )
        }

        let chromaRows = max((height + 1) / 2, 1)
        let chromaSamplesPerRow = max(width / 2, 1)
        for row in 0..<chromaRows {
            let sourceTop = sourceChroma
                .advanced(by: min(row * 2, height - 1) * sourceChromaStride)
                .assumingMemoryBound(to: UInt16.self)
            let sourceBottom = sourceChroma
                .advanced(by: min(row * 2 + 1, height - 1) * sourceChromaStride)
                .assumingMemoryBound(to: UInt16.self)
            let destinationRow = destinationChroma
                .advanced(by: row * destinationChromaStride)
                .assumingMemoryBound(to: UInt16.self)

            for sample in 0..<chromaSamplesPerRow {
                let index = sample * 2
                destinationRow[index] = averageP010(sourceTop[index], sourceBottom[index])
                destinationRow[index + 1] = averageP010(sourceTop[index + 1], sourceBottom[index + 1])
            }
        }

        return destination
    }

    /// Quantizes 16-bit packed components and averages each 2x2 chroma footprint.
    private func convertY416ToP010(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let destination = try makeDestinationP010PixelBuffer()

        let sourceLockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLockStatus == kCVReturnSuccess else {
            throw NSError(
                domain: "AV1Encode",
                code: Int(sourceLockStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not lock the native y416 ProRes source buffer: \(sourceLockStatus)."
                ]
            )
        }
        let destinationLockStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLockStatus == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            throw NSError(
                domain: "AV1Encode",
                code: Int(destinationLockStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not lock the native ProRes P010 destination buffer: \(destinationLockStatus)."
                ]
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationLuma = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
              let destinationChroma = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected y416 pixel buffer layout during native ProRes decode."]
            )
        }

        let sourceStrideBytes = CVPixelBufferGetBytesPerRow(source)
        let sourceStrideWords = sourceStrideBytes / MemoryLayout<UInt16>.stride
        let destinationLumaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0) / MemoryLayout<UInt16>.stride
        let destinationChromaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1) / MemoryLayout<UInt16>.stride
        guard sourceStrideWords >= width * 4,
              destinationLumaStride >= width,
              destinationChromaStride >= width else {
            throw NSError(
                domain: "AV1Encode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Native y416/P010 pixel buffer row strides are smaller than the active image width."
                ]
            )
        }

        let sourceWords = sourceBase.assumingMemoryBound(to: UInt16.self)
        let destinationLumaWords = destinationLuma.assumingMemoryBound(to: UInt16.self)
        let destinationChromaWords = destinationChroma.assumingMemoryBound(to: UInt16.self)

        for row in 0..<height {
            let sourceRow = sourceWords.advanced(by: row * sourceStrideWords)
            let destinationRow = destinationLumaWords.advanced(by: row * destinationLumaStride)
            for x in 0..<width {
                destinationRow[x] = quantize16ToP010(sourceRow[x * 4 + 1])
            }
        }

        let chromaRows = max((height + 1) / 2, 1)
        let chromaSamplesPerRow = max(width / 2, 1)
        for row in 0..<chromaRows {
            let topRow = sourceWords.advanced(by: min(row * 2, height - 1) * sourceStrideWords)
            let bottomRow = sourceWords.advanced(by: min(row * 2 + 1, height - 1) * sourceStrideWords)
            let destinationRow = destinationChromaWords.advanced(by: row * destinationChromaStride)

            for sample in 0..<chromaSamplesPerRow {
                let leftX = sample * 2
                let rightX = min(leftX + 1, width - 1)

                let cb = average4Quantized(
                    topRow[leftX * 4 + 2],
                    topRow[rightX * 4 + 2],
                    bottomRow[leftX * 4 + 2],
                    bottomRow[rightX * 4 + 2]
                )
                let cr = average4Quantized(
                    topRow[leftX * 4 + 3],
                    topRow[rightX * 4 + 3],
                    bottomRow[leftX * 4 + 3],
                    bottomRow[rightX * 4 + 3]
                )

                destinationRow[sample * 2] = cb
                destinationRow[sample * 2 + 1] = cr
            }
        }

        return destination
    }
}

/// Averages two left-aligned 10-bit samples with integer rounding.
private func averageP010(_ a: UInt16, _ b: UInt16) -> UInt16 {
    let a10 = Int(a) >> 6
    let b10 = Int(b) >> 6
    return UInt16(((a10 + b10 + 1) / 2) << 6)
}

/// Quantizes and averages a 2x2 group into one left-aligned 10-bit sample.
private func average4Quantized(_ a: UInt16, _ b: UInt16, _ c: UInt16, _ d: UInt16) -> UInt16 {
    let a10 = Int(quantize16To10Bit(a))
    let b10 = Int(quantize16To10Bit(b))
    let c10 = Int(quantize16To10Bit(c))
    let d10 = Int(quantize16To10Bit(d))
    return UInt16(((a10 + b10 + c10 + d10 + 2) / 4) << 6)
}

/// Rounds a full 16-bit code value to an unsigned 10-bit value.
private func quantize16To10Bit(_ value: UInt16) -> UInt16 {
    UInt16(min((Int(value) + 32) >> 6, 1023))
}

/// Converts a full 16-bit code value to left-aligned P010 storage.
private func quantize16ToP010(_ value: UInt16) -> UInt16 {
    quantize16To10Bit(value) << 6
}

/// Formats a media subtype for decoder diagnostics.
private func proResDecodeFourCCString(_ code: FourCharCode) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff),
    ].map { ($0 >= 32 && $0 < 127) ? $0 : UInt8(ascii: ".") }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}
