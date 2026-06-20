// rpu.swift — Dolby Vision RPU generation and HEVC sample injection

import Foundation
import AVFoundation

struct HEVCHDR10Metadata: Sendable {
    let masteringDisplayColorVolume: Data?
    let contentLightLevelInfo: Data?

    var hasAnyPayload: Bool {
        masteringDisplayColorVolume?.count == 24 || contentLightLevelInfo?.count == 4
    }
}

private func hevcNALUnitLengthSize(from sampleBuffer: CMSampleBuffer) -> Int {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        return 4
    }
    var parameterSetCount = 0
    var nalUnitHeaderLength: Int32 = 0
    let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        formatDescription,
        parameterSetIndex: 0,
        parameterSetPointerOut: nil,
        parameterSetSizeOut: nil,
        parameterSetCountOut: &parameterSetCount,
        nalUnitHeaderLengthOut: &nalUnitHeaderLength
    )
    if status == noErr, nalUnitHeaderLength > 0 {
        return Int(nalUnitHeaderLength)
    }
    return 4
}

private func readLengthPrefix(_ data: Data, at offset: Int, byteCount: Int) -> Int {
    var value = 0
    for byte in data[offset..<(offset + byteCount)] {
        value = (value << 8) | Int(byte)
    }
    return value
}

private func lengthPrefixData(_ value: Int, byteCount: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for idx in 0..<byteCount {
        let shift = (byteCount - idx - 1) * 8
        bytes[idx] = UInt8((value >> shift) & 0xff)
    }
    return Data(bytes)
}

private func hevcNALType(_ nalu: Data) -> UInt8? {
    guard let first = nalu.first else { return nil }
    return (first >> 1) & 0x3f
}

private func hevcParameterSets(from sampleBuffer: CMSampleBuffer) -> [Data] {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        return []
    }
    var parameterSetCount = 0
    var nalUnitHeaderLength: Int32 = 0
    guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        formatDescription,
        parameterSetIndex: 0,
        parameterSetPointerOut: nil,
        parameterSetSizeOut: nil,
        parameterSetCountOut: &parameterSetCount,
        nalUnitHeaderLengthOut: &nalUnitHeaderLength
    ) == noErr else {
        return []
    }

    var parameterSets: [Data] = []
    parameterSets.reserveCapacity(parameterSetCount)
    for index in 0..<parameterSetCount {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        ) == noErr,
              let pointer,
              size > 0 else {
            continue
        }
        parameterSets.append(Data(bytes: pointer, count: size))
    }
    return parameterSets
}

private func sampleBufferIsSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
    ) as? [NSDictionary],
          let first = attachments.first,
          let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool else {
        return true
    }
    return !notSync
}

func sampleBufferContainsHEVCDolbyVisionRPU(_ sampleBuffer: CMSampleBuffer) -> Bool {
    sampleBufferContainsHEVCNALType(sampleBuffer, nalType: 62)
}

func sampleBufferContainsHEVCDolbyVisionEL(_ sampleBuffer: CMSampleBuffer) -> Bool {
    sampleBufferContainsHEVCNALType(sampleBuffer, nalType: 63)
}

private func sampleBufferContainsHEVCNALType(
    _ sampleBuffer: CMSampleBuffer,
    nalType targetNALType: UInt8
) -> Bool {
    guard let data = compressedData(from: sampleBuffer) else {
        return false
    }
    let lengthSize = hevcNALUnitLengthSize(from: sampleBuffer)
    var cursor = 0
    while cursor + lengthSize <= data.count {
        let nalLength = readLengthPrefix(data, at: cursor, byteCount: lengthSize)
        cursor += lengthSize
        guard nalLength > 0, cursor + nalLength <= data.count else {
            return false
        }
        let nalu = Data(data[cursor..<(cursor + nalLength)])
        if hevcNALType(nalu) == targetNALType {
            return true
        }
        cursor += nalLength
    }
    return false
}

func compressedData(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return nil
    }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    var data = Data(count: length)
    data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
    }
    return data
}

func copySampleAttachments(from source: CMSampleBuffer, to destination: CMSampleBuffer) {
    guard let sourceArray = CMSampleBufferGetSampleAttachmentsArray(
        source,
        createIfNecessary: false
    ) as? [NSDictionary],
          let destinationArray = CMSampleBufferGetSampleAttachmentsArray(
            destination,
            createIfNecessary: true
          ) as? [NSMutableDictionary],
          let sourceDictionary = sourceArray.first,
          let destinationDictionary = destinationArray.first else {
        return
    }
    for (key, value) in sourceDictionary {
        if let copyableKey = key as? NSCopying {
            destinationDictionary.setObject(value, forKey: copyableKey)
        }
    }
}

func sampleBufferByInjectingHEVCRPU(
    _ sampleBuffer: CMSampleBuffer,
    rpuNALUnit: Data,
    hdr10Metadata: HEVCHDR10Metadata? = nil
) throws -> CMSampleBuffer {
    guard CMSampleBufferGetFormatDescription(sampleBuffer) != nil,
          let data = compressedData(from: sampleBuffer) else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not read encoded HEVC sample data."]
        )
    }

    let lengthSize = hevcNALUnitLengthSize(from: sampleBuffer)
    var output = Data()
    let hdr10SEINALUnit = makeHEVCPrefixSEINALUnit(metadata: hdr10Metadata)
    output.reserveCapacity(data.count + rpuNALUnit.count + (hdr10SEINALUnit?.count ?? 0) + (lengthSize * 2))

    var cursor = 0
    var insertedHDR10SEI = hdr10SEINALUnit == nil
    while cursor + lengthSize <= data.count {
        let nalLength = readLengthPrefix(data, at: cursor, byteCount: lengthSize)
        cursor += lengthSize
        guard nalLength >= 0, cursor + nalLength <= data.count else {
            throw NSError(
                domain: "DolbyVisionRPU",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HEVC length-prefixed NAL unit."]
            )
        }
        let nalu = Data(data[cursor..<(cursor + nalLength)])
        cursor += nalLength
        if hevcNALType(nalu) == 62 {
            continue
        }
        if !insertedHDR10SEI,
           let nalType = hevcNALType(nalu),
           nalType <= 31,
           let hdr10SEINALUnit {
            output.append(lengthPrefixData(hdr10SEINALUnit.count, byteCount: lengthSize))
            output.append(hdr10SEINALUnit)
            insertedHDR10SEI = true
        }
        output.append(lengthPrefixData(nalLength, byteCount: lengthSize))
        output.append(nalu)
    }

    if !insertedHDR10SEI, let hdr10SEINALUnit {
        output.append(lengthPrefixData(hdr10SEINALUnit.count, byteCount: lengthSize))
        output.append(hdr10SEINALUnit)
    }

    output.append(lengthPrefixData(rpuNALUnit.count, byteCount: lengthSize))
    output.append(rpuNALUnit)

    return try compressedSampleBuffer(output, using: sampleBuffer)
}

func sampleBufferByMuxingDolbyVisionProfile7(
    baseLayerSample: CMSampleBuffer,
    enhancementLayerSample: CMSampleBuffer,
    rpuNALUnit: Data,
    hdr10Metadata: HEVCHDR10Metadata? = nil
) throws -> CMSampleBuffer {
    guard CMSampleBufferGetFormatDescription(baseLayerSample) != nil,
          let baseLayerData = compressedData(from: baseLayerSample),
          let enhancementLayerData = compressedData(from: enhancementLayerSample) else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not read encoded Profile 7 BL/EL sample data."]
        )
    }

    let outputLengthSize = hevcNALUnitLengthSize(from: baseLayerSample)
    let enhancementLengthSize = hevcNALUnitLengthSize(from: enhancementLayerSample)
    let hdr10SEINALUnit = makeHEVCPrefixSEINALUnit(metadata: hdr10Metadata)
    var output = Data()
    output.reserveCapacity(
        baseLayerData.count + enhancementLayerData.count +
        rpuNALUnit.count + (hdr10SEINALUnit?.count ?? 0) + 128
    )

    var baseCursor = 0
    var insertedHDR10SEI = hdr10SEINALUnit == nil
    while baseCursor + outputLengthSize <= baseLayerData.count {
        let nalLength = readLengthPrefix(
            baseLayerData,
            at: baseCursor,
            byteCount: outputLengthSize
        )
        baseCursor += outputLengthSize
        guard nalLength > 0, baseCursor + nalLength <= baseLayerData.count else {
            throw NSError(
                domain: "DolbyVisionRPU",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Profile 7 base-layer NAL unit."]
            )
        }
        let nalu = Data(baseLayerData[baseCursor..<(baseCursor + nalLength)])
        baseCursor += nalLength
        guard let nalType = hevcNALType(nalu), nalType != 62, nalType != 63 else {
            continue
        }
        if !insertedHDR10SEI, nalType <= 31, let hdr10SEINALUnit {
            output.append(lengthPrefixData(hdr10SEINALUnit.count, byteCount: outputLengthSize))
            output.append(hdr10SEINALUnit)
            insertedHDR10SEI = true
        }
        output.append(lengthPrefixData(nalu.count, byteCount: outputLengthSize))
        output.append(nalu)
    }

    if !insertedHDR10SEI, let hdr10SEINALUnit {
        output.append(lengthPrefixData(hdr10SEINALUnit.count, byteCount: outputLengthSize))
        output.append(hdr10SEINALUnit)
    }

    // Match dovi_tool mux: every EL NAL except an RPU is nested behind an
    // UNSPEC63 (0x7e01) header while preserving the complete original NAL.
    if sampleBufferIsSync(enhancementLayerSample) {
        for parameterSet in hevcParameterSets(from: enhancementLayerSample) {
            var wrappedNALUnit = Data([0x7e, 0x01])
            wrappedNALUnit.append(parameterSet)
            output.append(lengthPrefixData(wrappedNALUnit.count, byteCount: outputLengthSize))
            output.append(wrappedNALUnit)
        }
    }

    var enhancementCursor = 0
    while enhancementCursor + enhancementLengthSize <= enhancementLayerData.count {
        let nalLength = readLengthPrefix(
            enhancementLayerData,
            at: enhancementCursor,
            byteCount: enhancementLengthSize
        )
        enhancementCursor += enhancementLengthSize
        guard nalLength > 0, enhancementCursor + nalLength <= enhancementLayerData.count else {
            throw NSError(
                domain: "DolbyVisionRPU",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Profile 7 enhancement-layer NAL unit."]
            )
        }
        let nalu = Data(
            enhancementLayerData[enhancementCursor..<(enhancementCursor + nalLength)]
        )
        enhancementCursor += nalLength
        if let nalType = hevcNALType(nalu), nalType == 62 || nalType == 63 {
            continue
        }
        var wrappedNALUnit = Data([0x7e, 0x01])
        wrappedNALUnit.append(nalu)
        output.append(lengthPrefixData(wrappedNALUnit.count, byteCount: outputLengthSize))
        output.append(wrappedNALUnit)
    }

    output.append(lengthPrefixData(rpuNALUnit.count, byteCount: outputLengthSize))
    output.append(rpuNALUnit)
    return try compressedSampleBuffer(output, using: baseLayerSample)
}

private func compressedSampleBuffer(
    _ output: Data,
    using templateSampleBuffer: CMSampleBuffer
) throws -> CMSampleBuffer {
    guard let formatDescription = CMSampleBufferGetFormatDescription(templateSampleBuffer) else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not read compressed sample format."]
        )
    }
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
            userInfo: [NSLocalizedDescriptionKey: "Could not create HEVC sample block buffer: \(blockStatus)."]
        )
    }

    var timing = CMSampleTimingInfo()
    let timingStatus = CMSampleBufferGetSampleTimingInfo(
        templateSampleBuffer,
        at: 0,
        timingInfoOut: &timing
    )
    guard timingStatus == noErr else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: Int(timingStatus),
            userInfo: [NSLocalizedDescriptionKey: "Could not read HEVC sample timing: \(timingStatus)."]
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
            userInfo: [NSLocalizedDescriptionKey: "Could not create HEVC sample buffer with RPU: \(sampleStatus)."]
        )
    }
    copySampleAttachments(from: templateSampleBuffer, to: injectedSample)
    return injectedSample
}

private func makeHEVCPrefixSEINALUnit(metadata: HEVCHDR10Metadata?) -> Data? {
    guard let metadata, metadata.hasAnyPayload else { return nil }
    var rbsp = Data()
    if let masteringDisplay = metadata.masteringDisplayColorVolume,
       masteringDisplay.count == 24 {
        appendSEIMessage(payloadType: 137, payload: masteringDisplay, to: &rbsp)
    }
    if let contentLight = metadata.contentLightLevelInfo,
       contentLight.count == 4 {
        appendSEIMessage(payloadType: 144, payload: contentLight, to: &rbsp)
    }
    guard !rbsp.isEmpty else { return nil }
    rbsp.append(0x80)
    var nalu = Data([0x4e, 0x01])
    nalu.append(hevcEBSP(from: rbsp))
    return nalu
}

private func appendSEIMessage(payloadType: Int, payload: Data, to rbsp: inout Data) {
    appendSEIEncodedInteger(payloadType, to: &rbsp)
    appendSEIEncodedInteger(payload.count, to: &rbsp)
    rbsp.append(payload)
}

private func appendSEIEncodedInteger(_ value: Int, to data: inout Data) {
    var remainder = value
    while remainder >= 255 {
        data.append(255)
        remainder -= 255
    }
    data.append(UInt8(remainder))
}

private func hevcEBSP(from rbsp: Data) -> Data {
    var output = Data()
    output.reserveCapacity(rbsp.count)
    var zeroCount = 0
    for byte in rbsp {
        if zeroCount >= 2, byte <= 0x03 {
            output.append(0x03)
            zeroCount = 0
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

private extension OSStatus {
    func flatMapNoErr(_ body: () -> OSStatus) -> OSStatus {
        self == noErr ? body() : self
    }
}
