// AV1Support.swift — AV1 CMSampleBuffer creation and Dolby Vision metadata OBU injection.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

extension AV1Bridge: @unchecked Sendable {}
extension AV1BridgePacket: @unchecked Sendable {}
extension AV1BridgeConfig: @unchecked Sendable {}

private let av1CodecType: CMVideoCodecType = kCMVideoCodecType_AV1
private let av1DecodeFallbackPixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

struct AV1EncodeOptions: Sendable {
    let bitrateMbps: Double
    let dvProfile: DolbyVisionHEVCProfile?

    var bitrateBitsPerSecond: Int {
        Int((bitrateMbps * 1_000_000.0).rounded())
    }
}

func isAV1Quality(_ quality: String) -> Bool {
    normalizedProResQuality(quality) == "av1"
}

func isCompressedHDRQuality(_ quality: String) -> Bool {
    isHEVCQuality(quality) || isAV1Quality(quality)
}

func makeAV1BridgeConfig(
    width: Int,
    height: Int,
    fpsInfo: FramerateInfo,
    options: AV1EncodeOptions,
    colorSpace: SourceColorSpace?
) -> AV1BridgeConfig {
    let config = AV1BridgeConfig()
    config.width = Int32(width)
    config.height = Int32(height)
    config.fpsNum = Int32(fpsInfo.numerator)
    config.fpsDen = Int32(fpsInfo.denominator)
    config.bitrateBitsPerSecond = Int64(options.bitrateBitsPerSecond)
    config.colorPrimaries = av1ColorPrimaries(from: colorSpace)
    config.transferCharacteristics = av1TransferCharacteristics(from: colorSpace)
    config.matrixCoefficients = av1MatrixCoefficients(from: colorSpace)
    // Keep AV1 static HDR signaling at the container/sample-entry layer.
    // In-band hdr_mdcv/clli metadata OBU on key frames trips DV container checks.
    config.masteringDisplayColorVolume = nil
    config.contentLightLevelInfo = nil
    return config
}

func makeAV1FormatDescription(
    width: Int,
    height: Int,
    codecConfigurationRecord: Data,
    colorSpace: SourceColorSpace?
) throws -> CMFormatDescription {
    var extensions: [String: Any] = [
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: [
            "av1C": codecConfigurationRecord
        ],
        kCMFormatDescriptionExtension_ColorPrimaries as String:
            (colorSpace?.primaries ?? (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)),
        kCMFormatDescriptionExtension_TransferFunction as String:
            (colorSpace?.transfer ?? (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)),
        kCMFormatDescriptionExtension_YCbCrMatrix as String:
            (colorSpace?.matrix ?? (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)),
        kCMFormatDescriptionExtension_FullRangeVideo as String:
            kCFBooleanFalse as Any
    ]
    if let masteringDisplay = colorSpace?.masteringDisplayColorVolume {
        extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] = masteringDisplay
    }
    if let contentLight = colorSpace?.contentLightLevelInfo {
        extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] = contentLight
    }

    var formatDescription: CMFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: av1CodecType,
        width: Int32(width),
        height: Int32(height),
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw NSError(
            domain: "AV1Encode",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Could not create AV1 format description: \(status)."]
        )
    }
    return formatDescription
}

private func av1ColorPrimaries(from colorSpace: SourceColorSpace?) -> Int32 {
    if colorSpace?.primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) {
        return 1
    }
    if colorSpace?.primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) {
        return 12
    }
    return 9
}

private func av1TransferCharacteristics(from colorSpace: SourceColorSpace?) -> Int32 {
    if colorSpace?.transfer == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String) {
        return 1
    }
    if colorSpace?.transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1 as String) {
        return 17
    }
    if colorSpace?.transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
        return 18
    }
    return 16
}

private func av1MatrixCoefficients(from colorSpace: SourceColorSpace?) -> Int32 {
    colorSpace?.matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String) ? 1 : 9
}

func makeAV1SampleBuffer(
    packet: AV1BridgePacket,
    formatDescription: CMFormatDescription,
    fpsInfo: FramerateInfo
) throws -> CMSampleBuffer {
    let data = stripAV1TemporalDelimiterOBUs(from: packet.data)
    var blockBuffer: CMBlockBuffer?
    let blockStatus = data.withUnsafeBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
        return CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ).flatMapNoErr {
            CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
    }
    guard blockStatus == noErr, let blockBuffer else {
        throw NSError(
            domain: "AV1Encode",
            code: Int(blockStatus),
            userInfo: [NSLocalizedDescriptionKey: "Could not create AV1 sample block buffer: \(blockStatus)."]
        )
    }

    let pts = CMTime(
        value: CMTimeValue(packet.presentationIndex) * CMTimeValue(fpsInfo.denominator),
        timescale: CMTimeScale(fpsInfo.numerator)
    )
    let duration = CMTime(
        value: CMTimeValue(fpsInfo.denominator),
        timescale: CMTimeScale(fpsInfo.numerator)
    )
    var timing = CMSampleTimingInfo(
        duration: duration,
        presentationTimeStamp: pts,
        decodeTimeStamp: .invalid
    )
    var sampleSize = data.count
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        throw NSError(
            domain: "AV1Encode",
            code: Int(sampleStatus),
            userInfo: [NSLocalizedDescriptionKey: "Could not create AV1 sample buffer: \(sampleStatus)."]
        )
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: true
    ) as? [NSMutableDictionary],
       let first = attachments.first,
       !packet.keyframe {
        first.setObject(kCFBooleanTrue as Any, forKey: kCMSampleAttachmentKey_NotSync as NSString)
    }
    return sampleBuffer
}

private func stripAV1TemporalDelimiterOBUs(from data: Data) -> Data {
    var cursor = data.startIndex
    var output = Data()
    output.reserveCapacity(data.count)

    while cursor < data.endIndex {
        let obuStart = cursor
        let header = data[cursor]
        cursor = data.index(after: cursor)

        let obuType = (header >> 3) & 0x0f
        let hasExtension = (header & 0x04) != 0
        let hasSize = (header & 0x02) != 0
        if hasExtension {
            guard cursor < data.endIndex else { break }
            cursor = data.index(after: cursor)
        }

        let payloadSize: Int
        if hasSize {
            do {
                payloadSize = try readAV1LEB128(in: data, cursor: &cursor)
            } catch {
                return data
            }
        } else {
            payloadSize = data.distance(from: cursor, to: data.endIndex)
        }

        guard payloadSize >= 0,
              let obuEnd = data.index(cursor, offsetBy: payloadSize, limitedBy: data.endIndex) else {
            return data
        }

        if obuType != 2 {
            output.append(data[obuStart..<obuEnd])
        }
        cursor = obuEnd
    }

    return output.isEmpty ? data : output
}

func av1DecodeProbeFailure(asset: AVAsset, videoTrack: AVAssetTrack) async -> String? {
    guard let reader = try? AVAssetReader(asset: asset) else {
        return "AVAssetReader probe could not be created for AV1 decode."
    }
    defer { reader.cancelReading() }

    let output = AVAssetReaderTrackOutput(
        track: videoTrack,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: av1DecodeFallbackPixelFormat)
        ]
    )
    output.alwaysCopiesSampleData = false

    guard reader.canAdd(output) else {
        return "AVAssetReader cannot add a decoded P010 video output for the source track."
    }
    reader.add(output)

    guard reader.startReading() else {
        let detail = reader.error?.localizedDescription ?? "unknown reader error"
        return "AVAssetReader cannot decode the source video to P010 pixel buffers (\(detail))."
    }

    if let sample = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetImageBuffer(sample) != nil else {
            return "AVAssetReader returned a compressed sample instead of a decoded pixel buffer."
        }
        return nil
    }

    if reader.status == .failed {
        let detail = reader.error?.localizedDescription ?? "unknown reader error"
        return "AVAssetReader failed during the decoded sample probe (\(detail))."
    }
    return "AVAssetReader produced no decoded video samples during the AV1 probe."
}

func sampleBufferByInjectingAV1RPU(
    _ sampleBuffer: CMSampleBuffer,
    rpuNALUnit: Data
) throws -> CMSampleBuffer {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let data = compressedData(from: sampleBuffer) else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not read encoded AV1 sample data."]
        )
    }

    let doviOBU = try makeAV1DolbyVisionMetadataOBU(fromHEVCRPU: rpuNALUnit)
    let insertOffset = try av1MetadataInsertionOffset(in: data)
    var output = Data()
    output.reserveCapacity(data.count + doviOBU.count)
    output.append(data[..<insertOffset])
    output.append(doviOBU)
    output.append(data[insertOffset...])

    var blockBuffer: CMBlockBuffer?
    let blockStatus = output.withUnsafeBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
        return CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: output.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: output.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ).flatMapNoErr {
            CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: output.count
            )
        }
    }
    guard blockStatus == noErr, let blockBuffer else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: Int(blockStatus),
            userInfo: [NSLocalizedDescriptionKey: "Could not create AV1 sample block buffer: \(blockStatus)."]
        )
    }

    var timing = CMSampleTimingInfo()
    let timingStatus = CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
    guard timingStatus == noErr else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: Int(timingStatus),
            userInfo: [NSLocalizedDescriptionKey: "Could not read AV1 sample timing: \(timingStatus)."]
        )
    }

    var sampleSize = output.count
    var injectedSample: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &injectedSample
    )
    guard sampleStatus == noErr, let injectedSample else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: Int(sampleStatus),
            userInfo: [NSLocalizedDescriptionKey: "Could not create AV1 sample buffer with RPU: \(sampleStatus)."]
        )
    }
    copySampleAttachments(from: sampleBuffer, to: injectedSample)
    return injectedSample
}

func sampleBufferContainsAV1DolbyVisionRPU(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let data = compressedData(from: sampleBuffer) else {
        return false
    }
    var cursor = data.startIndex
    while cursor < data.endIndex {
        let header = data[cursor]
        cursor = data.index(after: cursor)

        let obuType = (header >> 3) & 0x0f
        let hasExtension = (header & 0x04) != 0
        let hasSize = (header & 0x02) != 0
        if hasExtension {
            guard cursor < data.endIndex else { return false }
            cursor = data.index(after: cursor)
        }

        let payloadSize: Int
        if hasSize {
            guard let parsedSize = try? readAV1LEB128(in: data, cursor: &cursor) else {
                return false
            }
            payloadSize = parsedSize
        } else {
            payloadSize = data.distance(from: cursor, to: data.endIndex)
        }
        guard payloadSize >= 0,
              let payloadEnd = data.index(
                cursor,
                offsetBy: payloadSize,
                limitedBy: data.endIndex
              ) else {
            return false
        }

        if obuType == 5 {
            var metadataCursor = cursor
            if let metadataType = try? readAV1LEB128(
                in: data,
                cursor: &metadataCursor
            ),
               metadataType == 4,
               metadataCursor < payloadEnd,
               data[metadataCursor] == 0xb5 {
                return true
            }
        }
        cursor = payloadEnd
    }
    return false
}

private func av1MetadataInsertionOffset(in data: Data) throws -> Data.Index {
    var cursor = data.startIndex
    var fallback: Data.Index?
    while cursor < data.endIndex {
        let obuStart = cursor
        let header = data[cursor]
        cursor = data.index(after: cursor)
        let obuType = (header >> 3) & 0x0f
        let hasExtension = (header & 0x04) != 0
        let hasSize = (header & 0x02) != 0
        if hasExtension {
            guard cursor < data.endIndex else { break }
            cursor = data.index(after: cursor)
        }
        let payloadSize: Int
        if hasSize {
            let read = try readAV1LEB128(in: data, cursor: &cursor)
            payloadSize = read
        } else {
            payloadSize = data.distance(from: cursor, to: data.endIndex)
        }
        guard payloadSize >= 0,
              let obuEnd = data.index(cursor, offsetBy: payloadSize, limitedBy: data.endIndex) else {
            throw NSError(
                domain: "DolbyVisionRPU",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid AV1 length-prefixed OBU."]
            )
        }
        if obuType == 6 {
            fallback = obuStart
        }
        if obuType == 3 || obuType == 4 {
            return obuStart
        }
        cursor = obuEnd
    }
    if let fallback {
        return fallback
    }
    throw NSError(
        domain: "DolbyVisionRPU",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Encoded AV1 sample has no frame OBU for Dolby Vision RPU insertion."]
    )
}

private func makeAV1DolbyVisionMetadataOBU(fromHEVCRPU rpuNALUnit: Data) throws -> Data {
    let rawRPU = try regularRPUData(fromHEVCNALUnit: rpuNALUnit)
    let completeT35 = try av1T35PayloadComplete(fromRegularRPU: rawRPU)

    var payload = Data()
    payload.append(av1LEB128Data(4))
    payload.append(completeT35)
    payload.append(0x80)

    var obu = Data([0x2a])
    obu.append(av1LEB128Data(payload.count))
    obu.append(payload)
    return obu
}

private func regularRPUData(fromHEVCNALUnit nalu: Data) throws -> Data {
    var payload = nalu
    if payload.count >= 2, payload[payload.startIndex] == 0x7c, payload[payload.index(after: payload.startIndex)] == 0x01 {
        payload.removeFirst(2)
    }
    let cleared = clearHEVCStartCodeEmulationPrevention(payload)
    guard let first = cleared.first, first == 0x19 else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "RPU payload is not a regular Dolby Vision RPU."]
        )
    }
    return cleared
}

private func av1T35PayloadComplete(fromRegularRPU rpu: Data) throws -> Data {
    guard rpu.first == 0x19 else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "AV1 Dolby Vision conversion requires an RPU starting with 0x19."]
        )
    }
    var rpuEnd = rpu.count
    while rpuEnd > 0, rpu[rpu.index(rpu.startIndex, offsetBy: rpuEnd - 1)] == 0 {
        rpuEnd -= 1
    }
    guard rpuEnd > 0, rpu[rpu.index(rpu.startIndex, offsetBy: rpuEnd - 1)] == 0x80 else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "RPU payload has no 0x80 terminator."]
        )
    }
    let emdfPayloadStart = rpu.index(after: rpu.startIndex)
    let emdfPayloadEnd = rpu.index(rpu.startIndex, offsetBy: rpuEnd)
    let emdfPayload = Data(rpu[emdfPayloadStart..<emdfPayloadEnd])

    var writer = AV1MSBBitWriter()
    writer.write(0x003b, bitCount: 16)
    writer.write(0x0800, bitCount: 32)
    writeEMDFContainer(payload: emdfPayload, to: &writer)
    while !writer.isByteAligned {
        writer.writeBit(true)
    }

    var complete = Data([0xb5])
    complete.append(writer.data)
    return complete
}

private func writeEMDFContainer(payload: Data, to writer: inout AV1MSBBitWriter) {
    writer.write(0, bitCount: 2)
    writer.write(6, bitCount: 3)
    writer.write(31, bitCount: 5)
    writeEMDFVariableBits(225, bits: 5, to: &writer)
    writer.write(0, bitCount: 4)
    writer.writeBit(true)
    writeEMDFVariableBits(UInt32(payload.count), bits: 8, to: &writer)
    writer.writeBytes(payload)
    writer.write(0, bitCount: 5)
    writer.write(1, bitCount: 2)
    writer.write(0, bitCount: 2)
    writer.write(0, bitCount: 8)
}

private func writeEMDFVariableBits(_ value: UInt32, bits: Int, to writer: inout AV1MSBBitWriter) {
    let maxValue = UInt32(1 << bits)
    if value > maxValue {
        var remaining = value
        while true {
            let tmp = remaining >> UInt32(bits)
            let clipped = tmp << UInt32(bits)
            remaining -= clipped
            let byte = (clipped - maxValue) >> UInt32(bits)
            writer.write(UInt64(byte), bitCount: bits)
            writer.writeBit(true)
            if remaining <= maxValue {
                break
            }
        }
        writer.write(UInt64(remaining), bitCount: bits)
    } else {
        writer.write(UInt64(value), bitCount: bits)
    }
    writer.writeBit(false)
}

private func clearHEVCStartCodeEmulationPrevention(_ data: Data) -> Data {
    var output = Data()
    output.reserveCapacity(data.count)
    var zeroCount = 0
    for byte in data {
        if zeroCount >= 2, byte == 0x03 {
            zeroCount = 0
            continue
        }
        output.append(byte)
        if byte == 0 {
            zeroCount += 1
        } else {
            zeroCount = 0
        }
    }
    return output
}

private func readAV1LEB128(in data: Data, cursor: inout Data.Index) throws -> Int {
    var value = 0
    var shift = 0
    while cursor < data.endIndex, shift <= 56 {
        let byte = data[cursor]
        cursor = data.index(after: cursor)
        value |= Int(byte & 0x7f) << shift
        if (byte & 0x80) == 0 {
            return value
        }
        shift += 7
    }
    throw NSError(
        domain: "AV1Encode",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid AV1 LEB128 value."]
    )
}

private func av1LEB128Data(_ value: Int) -> Data {
    var remaining = value
    var bytes = Data()
    repeat {
        var byte = UInt8(remaining & 0x7f)
        remaining >>= 7
        if remaining != 0 {
            byte |= 0x80
        }
        bytes.append(byte)
    } while remaining != 0
    return bytes
}

private struct AV1MSBBitWriter {
    private(set) var data = Data()
    private var bitOffset = 0

    var isByteAligned: Bool { bitOffset == 0 }

    mutating func writeBit(_ bit: Bool) {
        if bitOffset == 0 {
            data.append(0)
        }
        if bit {
            let index = data.index(before: data.endIndex)
            data[index] |= UInt8(1 << (7 - bitOffset))
        }
        bitOffset = (bitOffset + 1) & 7
    }

    mutating func write(_ value: UInt64, bitCount: Int) {
        guard bitCount > 0 else { return }
        for bitIndex in stride(from: bitCount - 1, through: 0, by: -1) {
            writeBit(((value >> UInt64(bitIndex)) & 1) != 0)
        }
    }

    mutating func writeBytes(_ bytes: Data) {
        for byte in bytes {
            write(UInt64(byte), bitCount: 8)
        }
    }
}

private extension OSStatus {
    func flatMapNoErr(_ body: () -> OSStatus) -> OSStatus {
        self == noErr ? body() : self
    }
}
