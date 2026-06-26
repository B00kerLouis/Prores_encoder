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

private func profile7EnhancementLayerHDR10Metadata(from metadata: HEVCHDR10Metadata?) -> HEVCHDR10Metadata? {
    guard let masteringDisplay = metadata?.masteringDisplayColorVolume,
          masteringDisplay.count == 24 else {
        return nil
    }
    return HEVCHDR10Metadata(
        masteringDisplayColorVolume: masteringDisplay,
        contentLightLevelInfo: Data([0x00, 0x00, 0x00, 0x00])
    )
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

// MARK: - Dolby Vision Profile 7.6 dual elementary-stream writer

private enum HEVCBitstreamError: LocalizedError {
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .invalidData(let message): return message
        }
    }
}

private struct HEVCBitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(_ data: Data) {
        bytes = Array(data)
    }

    private var bitCount: Int {
        bytes.count * 8
    }

    var bitsRemaining: Int {
        bitCount - bitOffset
    }

    mutating func readBit() throws -> Bool {
        guard bitOffset < bitCount else {
            throw HEVCBitstreamError.invalidData("Unexpected end of HEVC RBSP.")
        }
        let byte = bytes[bitOffset / 8]
        let bit = (byte >> UInt8(7 - (bitOffset % 8))) & 1
        bitOffset += 1
        return bit != 0
    }

    mutating func readBits(_ count: Int) throws -> UInt64 {
        guard count >= 0, count <= 64, bitsRemaining >= count else {
            throw HEVCBitstreamError.invalidData("Could not read \(count) HEVC bits.")
        }
        var value: UInt64 = 0
        for _ in 0..<count {
            value = (value << 1) | (try readBit() ? 1 : 0)
        }
        return value
    }

    mutating func readUE() throws -> UInt64 {
        var leadingZeroBits = 0
        while true {
            guard bitsRemaining > 0 else {
                throw HEVCBitstreamError.invalidData("Could not read HEVC unsigned Exp-Golomb code.")
            }
            if try readBit() {
                break
            }
            leadingZeroBits += 1
            if leadingZeroBits > 62 {
                throw HEVCBitstreamError.invalidData("HEVC Exp-Golomb code is too large.")
            }
        }
        if leadingZeroBits == 0 {
            return 0
        }
        let suffix = try readBits(leadingZeroBits)
        return ((UInt64(1) << UInt64(leadingZeroBits)) - 1) + suffix
    }

    mutating func readSE() throws -> Int64 {
        let codeNum = try readUE()
        let magnitude = Int64((codeNum + 1) / 2)
        return codeNum.isMultiple(of: 2) ? -magnitude : magnitude
    }
}

private struct HEVCBitWriter {
    private var bytes: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var usedBits = 0

    mutating func writeBit(_ bit: Bool) {
        if bit {
            currentByte |= UInt8(1 << (7 - usedBits))
        }
        usedBits += 1
        if usedBits == 8 {
            bytes.append(currentByte)
            currentByte = 0
            usedBits = 0
        }
    }

    mutating func writeBits(_ value: UInt64, count: Int) {
        guard count > 0 else { return }
        for index in stride(from: count - 1, through: 0, by: -1) {
            writeBit(((value >> UInt64(index)) & 1) != 0)
        }
    }

    mutating func writeUE(_ value: UInt64) {
        let codeNum = value + 1
        let bitWidth = max(1, 64 - codeNum.leadingZeroBitCount)
        for _ in 0..<(bitWidth - 1) {
            writeBit(false)
        }
        writeBits(codeNum, count: bitWidth)
    }

    mutating func writeSE(_ value: Int64) {
        let codeNum: UInt64
        if value > 0 {
            codeNum = UInt64(value * 2 - 1)
        } else {
            codeNum = UInt64(-value * 2)
        }
        writeUE(codeNum)
    }

    mutating func byteAlignWithOneBit() {
        writeBit(true)
        while usedBits != 0 {
            writeBit(false)
        }
    }

    mutating func writeRBSPTrailingBits() {
        byteAlignWithOneBit()
    }

    func data() -> Data {
        var output = bytes
        if usedBits > 0 {
            output.append(currentByte)
        }
        return Data(output)
    }
}

private func hevcRBSP(from ebsp: Data) -> Data {
    var output = Data()
    output.reserveCapacity(ebsp.count)
    var zeroCount = 0
    for byte in ebsp {
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

@discardableResult
private func hevcCopyBit(
    from reader: inout HEVCBitReader,
    to writer: inout HEVCBitWriter
) throws -> Bool {
    let bit = try reader.readBit()
    writer.writeBit(bit)
    return bit
}

@discardableResult
private func hevcCopyBits(
    _ count: Int,
    from reader: inout HEVCBitReader,
    to writer: inout HEVCBitWriter
) throws -> UInt64 {
    let value = try reader.readBits(count)
    writer.writeBits(value, count: count)
    return value
}

@discardableResult
private func hevcCopyUE(
    from reader: inout HEVCBitReader,
    to writer: inout HEVCBitWriter
) throws -> UInt64 {
    let value = try reader.readUE()
    writer.writeUE(value)
    return value
}

private func hevcCopySE(
    from reader: inout HEVCBitReader,
    to writer: inout HEVCBitWriter
) throws {
    let value = try reader.readSE()
    writer.writeSE(value)
}

private func hevcCopyProfileTierLevel(
    maxSubLayersMinus1: Int,
    from reader: inout HEVCBitReader,
    to writer: inout HEVCBitWriter
) throws {
    try hevcCopyBits(2, from: &reader, to: &writer)
    _ = try reader.readBit()
    writer.writeBit(true)
    try hevcCopyBits(5, from: &reader, to: &writer)
    try hevcCopyBits(32, from: &reader, to: &writer)
    try hevcCopyBits(4, from: &reader, to: &writer)
    try hevcCopyBits(44, from: &reader, to: &writer)
    _ = try reader.readBits(8)
    writer.writeBits(153, count: 8)

    var profilePresentFlags: [Bool] = []
    var levelPresentFlags: [Bool] = []
    if maxSubLayersMinus1 > 0 {
        for _ in 0..<maxSubLayersMinus1 {
            profilePresentFlags.append(try hevcCopyBit(from: &reader, to: &writer))
            levelPresentFlags.append(try hevcCopyBit(from: &reader, to: &writer))
        }
        for _ in maxSubLayersMinus1..<8 {
            try hevcCopyBits(2, from: &reader, to: &writer)
        }
    }

    for index in 0..<maxSubLayersMinus1 {
        if profilePresentFlags[index] {
            try hevcCopyBits(2, from: &reader, to: &writer)
            _ = try reader.readBit()
            writer.writeBit(true)
            try hevcCopyBits(5, from: &reader, to: &writer)
            try hevcCopyBits(32, from: &reader, to: &writer)
            try hevcCopyBits(4, from: &reader, to: &writer)
            try hevcCopyBits(44, from: &reader, to: &writer)
        }
        if levelPresentFlags[index] {
            _ = try reader.readBits(8)
            writer.writeBits(153, count: 8)
        }
    }
}

private func hevcCopyScalingListData(
    from reader: inout HEVCBitReader,
    to writer: inout HEVCBitWriter
) throws {
    for sizeID in 0..<4 {
        let matrixStep = sizeID == 3 ? 3 : 1
        var matrixID = 0
        while matrixID < 6 {
            let predModeFlag = try hevcCopyBit(from: &reader, to: &writer)
            if predModeFlag {
                let coefNum = min(64, 1 << (4 + (sizeID << 1)))
                if sizeID > 1 {
                    try hevcCopySE(from: &reader, to: &writer)
                }
                for _ in 0..<coefNum {
                    try hevcCopySE(from: &reader, to: &writer)
                }
            } else {
                try hevcCopyUE(from: &reader, to: &writer)
            }
            matrixID += matrixStep
        }
    }
}

private func hevcCopyShortTermRefPicSet(
    stRpsIndex: Int,
    numShortTermRefPicSets: Int,
    priorDeltaPOCCounts: inout [Int],
    from reader: inout HEVCBitReader,
    to writer: inout HEVCBitWriter
) throws {
    if stRpsIndex != 0 {
        let interPredictionFlag = try hevcCopyBit(from: &reader, to: &writer)
        if interPredictionFlag {
            let deltaIndexMinus1: Int
            if stRpsIndex == numShortTermRefPicSets {
                deltaIndexMinus1 = Int(try hevcCopyUE(from: &reader, to: &writer))
            } else {
                deltaIndexMinus1 = 0
            }
            try hevcCopyBit(from: &reader, to: &writer)
            try hevcCopyUE(from: &reader, to: &writer)
            let referenceIndex = stRpsIndex - 1 - deltaIndexMinus1
            let referenceDeltaPOCCount = priorDeltaPOCCounts.indices.contains(referenceIndex)
                ? priorDeltaPOCCounts[referenceIndex]
                : 0
            var deltaPOCCount = 0
            for _ in 0...referenceDeltaPOCCount {
                let usedByCurrentPicFlag = try hevcCopyBit(from: &reader, to: &writer)
                var useDeltaFlag = true
                if !usedByCurrentPicFlag {
                    useDeltaFlag = try hevcCopyBit(from: &reader, to: &writer)
                }
                if usedByCurrentPicFlag || useDeltaFlag {
                    deltaPOCCount += 1
                }
            }
            priorDeltaPOCCounts.append(deltaPOCCount)
            return
        }
    }

    let negativePicCount = Int(try hevcCopyUE(from: &reader, to: &writer))
    let positivePicCount = Int(try hevcCopyUE(from: &reader, to: &writer))
    for _ in 0..<negativePicCount {
        try hevcCopyUE(from: &reader, to: &writer)
        try hevcCopyBit(from: &reader, to: &writer)
    }
    for _ in 0..<positivePicCount {
        try hevcCopyUE(from: &reader, to: &writer)
        try hevcCopyBit(from: &reader, to: &writer)
    }
    priorDeltaPOCCounts.append(negativePicCount + positivePicCount)
}

private func hevcTimingUnits(from fpsInfo: FramerateInfo) -> (numUnitsInTick: UInt32, timeScale: UInt32) {
    let numUnitsInTick = UInt32(max(fpsInfo.denominator, 1))
    let timeScale = UInt32(max(fpsInfo.numerator, 1))
    return (numUnitsInTick, timeScale)
}

private func hevcHRDBitRateValueMinus1(_ bitrateBitsPerSecond: Int) -> UInt64 {
    UInt64(max(1, Int((Double(max(bitrateBitsPerSecond, 1)) / 256.0).rounded())) - 1)
}

private func hevcWriteHRDParameters(
    maxSubLayersMinus1: Int,
    bitrateBitsPerSecond: Int,
    to writer: inout HEVCBitWriter
) {
    writer.writeBit(true)  // nal_hrd_parameters_present_flag
    writer.writeBit(false) // vcl_hrd_parameters_present_flag
    writer.writeBit(false) // sub_pic_hrd_params_present_flag
    writer.writeBits(2, count: 4) // bit_rate_scale
    writer.writeBits(4, count: 4) // cpb_size_scale
    writer.writeBits(18, count: 5) // initial_cpb_removal_delay_length_minus1
    writer.writeBits(9, count: 5)  // au_cpb_removal_delay_length_minus1
    writer.writeBits(5, count: 5)  // dpb_output_delay_length_minus1

    let hrdValueMinus1 = hevcHRDBitRateValueMinus1(bitrateBitsPerSecond)
    for _ in 0...maxSubLayersMinus1 {
        writer.writeBit(true) // fixed_pic_rate_general_flag
        writer.writeUE(0)    // elemental_duration_in_tc_minus1
        writer.writeUE(0)    // cpb_cnt_minus1
        writer.writeUE(hrdValueMinus1)
        writer.writeUE(hrdValueMinus1)
        writer.writeBit(false) // cbr_flag
    }
}

private func hevcWriteVUIParameters(
    fpsInfo: FramerateInfo,
    maxSubLayersMinus1: Int,
    bitrateBitsPerSecond: Int,
    to writer: inout HEVCBitWriter
) {
    let timing = hevcTimingUnits(from: fpsInfo)
    writer.writeBit(true)
    writer.writeBits(1, count: 8) // square sample aspect ratio
    writer.writeBit(false) // overscan_info_present_flag
    writer.writeBit(true)
    writer.writeBits(5, count: 3) // video_format: unspecified
    writer.writeBit(false) // video_full_range_flag
    writer.writeBit(true)
    writer.writeBits(9, count: 8)  // BT.2020 primaries
    writer.writeBits(16, count: 8) // PQ
    writer.writeBits(9, count: 8)  // BT.2020 non-constant luminance
    writer.writeBit(true)
    writer.writeUE(2)
    writer.writeUE(2)
    writer.writeBit(false) // neutral_chroma_indication_flag
    writer.writeBit(false) // field_seq_flag
    writer.writeBit(false) // frame_field_info_present_flag
    writer.writeBit(false) // default_display_window_flag
    writer.writeBit(true)
    writer.writeBits(UInt64(timing.numUnitsInTick), count: 32)
    writer.writeBits(UInt64(timing.timeScale), count: 32)
    writer.writeBit(false) // vui_poc_proportional_to_timing_flag
    writer.writeBit(true)
    hevcWriteHRDParameters(
        maxSubLayersMinus1: maxSubLayersMinus1,
        bitrateBitsPerSecond: bitrateBitsPerSecond,
        to: &writer
    )
    writer.writeBit(false) // bitstream_restriction_flag
}

private func hevcNALByPatchingProfile7VPS(_ nalu: Data, fpsInfo: FramerateInfo) throws -> Data {
    guard nalu.count > 2 else {
        throw HEVCBitstreamError.invalidData("Invalid HEVC VPS NAL unit.")
    }
    var reader = HEVCBitReader(hevcRBSP(from: Data(nalu.dropFirst(2))))
    var writer = HEVCBitWriter()

    try hevcCopyBits(4, from: &reader, to: &writer)
    try hevcCopyBit(from: &reader, to: &writer)
    try hevcCopyBit(from: &reader, to: &writer)
    try hevcCopyBits(6, from: &reader, to: &writer)
    let maxSubLayersMinus1 = Int(try hevcCopyBits(3, from: &reader, to: &writer))
    try hevcCopyBit(from: &reader, to: &writer)
    try hevcCopyBits(16, from: &reader, to: &writer)
    try hevcCopyProfileTierLevel(
        maxSubLayersMinus1: maxSubLayersMinus1,
        from: &reader,
        to: &writer
    )
    let subLayerOrderingInfoPresent = try hevcCopyBit(from: &reader, to: &writer)
    let orderingStart = subLayerOrderingInfoPresent ? 0 : maxSubLayersMinus1
    if orderingStart <= maxSubLayersMinus1 {
        for _ in orderingStart...maxSubLayersMinus1 {
            try hevcCopyUE(from: &reader, to: &writer)
            try hevcCopyUE(from: &reader, to: &writer)
            try hevcCopyUE(from: &reader, to: &writer)
        }
    }
    let maxLayerID = Int(try hevcCopyBits(6, from: &reader, to: &writer))
    let layerSetsMinus1 = Int(try hevcCopyUE(from: &reader, to: &writer))
    if layerSetsMinus1 > 0 {
        for _ in 0..<layerSetsMinus1 {
            for _ in 0...maxLayerID {
                try hevcCopyBit(from: &reader, to: &writer)
            }
        }
    }

    let timing = hevcTimingUnits(from: fpsInfo)
    writer.writeBit(true)
    writer.writeBits(UInt64(timing.numUnitsInTick), count: 32)
    writer.writeBits(UInt64(timing.timeScale), count: 32)
    writer.writeBit(false)
    writer.writeUE(0)
    writer.writeBit(false)
    writer.writeRBSPTrailingBits()

    var output = Data(nalu.prefix(2))
    output.append(hevcEBSP(from: writer.data()))
    return output
}

private func hevcNALByPatchingProfile7SPS(
    _ nalu: Data,
    fpsInfo: FramerateInfo,
    bitrateBitsPerSecond: Int
) throws -> Data {
    guard nalu.count > 2 else {
        throw HEVCBitstreamError.invalidData("Invalid HEVC SPS NAL unit.")
    }
    var reader = HEVCBitReader(hevcRBSP(from: Data(nalu.dropFirst(2))))
    var writer = HEVCBitWriter()

    try hevcCopyBits(4, from: &reader, to: &writer)
    let maxSubLayersMinus1 = Int(try hevcCopyBits(3, from: &reader, to: &writer))
    try hevcCopyBit(from: &reader, to: &writer)
    try hevcCopyProfileTierLevel(
        maxSubLayersMinus1: maxSubLayersMinus1,
        from: &reader,
        to: &writer
    )
    try hevcCopyUE(from: &reader, to: &writer)
    let chromaFormatIDC = try hevcCopyUE(from: &reader, to: &writer)
    if chromaFormatIDC == 3 {
        try hevcCopyBit(from: &reader, to: &writer)
    }
    try hevcCopyUE(from: &reader, to: &writer)
    try hevcCopyUE(from: &reader, to: &writer)
    let conformanceWindowFlag = try hevcCopyBit(from: &reader, to: &writer)
    if conformanceWindowFlag {
        try hevcCopyUE(from: &reader, to: &writer)
        try hevcCopyUE(from: &reader, to: &writer)
        try hevcCopyUE(from: &reader, to: &writer)
        try hevcCopyUE(from: &reader, to: &writer)
    }
    try hevcCopyUE(from: &reader, to: &writer)
    try hevcCopyUE(from: &reader, to: &writer)
    let log2MaxPicOrderCntLSBMinus4 = Int(try hevcCopyUE(from: &reader, to: &writer))
    let subLayerOrderingInfoPresent = try hevcCopyBit(from: &reader, to: &writer)
    let orderingStart = subLayerOrderingInfoPresent ? 0 : maxSubLayersMinus1
    if orderingStart <= maxSubLayersMinus1 {
        for _ in orderingStart...maxSubLayersMinus1 {
            try hevcCopyUE(from: &reader, to: &writer)
            try hevcCopyUE(from: &reader, to: &writer)
            try hevcCopyUE(from: &reader, to: &writer)
        }
    }
    try hevcCopyUE(from: &reader, to: &writer)
    try hevcCopyUE(from: &reader, to: &writer)
    try hevcCopyUE(from: &reader, to: &writer)
    try hevcCopyUE(from: &reader, to: &writer)
    try hevcCopyUE(from: &reader, to: &writer)
    try hevcCopyUE(from: &reader, to: &writer)
    let scalingListEnabled = try hevcCopyBit(from: &reader, to: &writer)
    if scalingListEnabled {
        let scalingListPresent = try hevcCopyBit(from: &reader, to: &writer)
        if scalingListPresent {
            try hevcCopyScalingListData(from: &reader, to: &writer)
        }
    }
    try hevcCopyBit(from: &reader, to: &writer)
    try hevcCopyBit(from: &reader, to: &writer)
    let pcmEnabled = try hevcCopyBit(from: &reader, to: &writer)
    if pcmEnabled {
        try hevcCopyBits(4, from: &reader, to: &writer)
        try hevcCopyBits(4, from: &reader, to: &writer)
        try hevcCopyUE(from: &reader, to: &writer)
        try hevcCopyUE(from: &reader, to: &writer)
        try hevcCopyBit(from: &reader, to: &writer)
    }
    let shortTermRefPicSetCount = Int(try hevcCopyUE(from: &reader, to: &writer))
    var deltaPOCCounts: [Int] = []
    for stRpsIndex in 0..<shortTermRefPicSetCount {
        try hevcCopyShortTermRefPicSet(
            stRpsIndex: stRpsIndex,
            numShortTermRefPicSets: shortTermRefPicSetCount,
            priorDeltaPOCCounts: &deltaPOCCounts,
            from: &reader,
            to: &writer
        )
    }
    let longTermRefPicsPresent = try hevcCopyBit(from: &reader, to: &writer)
    if longTermRefPicsPresent {
        let longTermRefPicCount = Int(try hevcCopyUE(from: &reader, to: &writer))
        for _ in 0..<longTermRefPicCount {
            try hevcCopyBits(log2MaxPicOrderCntLSBMinus4 + 4, from: &reader, to: &writer)
            try hevcCopyBit(from: &reader, to: &writer)
        }
    }
    try hevcCopyBit(from: &reader, to: &writer)
    try hevcCopyBit(from: &reader, to: &writer)

    writer.writeBit(true)
    hevcWriteVUIParameters(
        fpsInfo: fpsInfo,
        maxSubLayersMinus1: maxSubLayersMinus1,
        bitrateBitsPerSecond: bitrateBitsPerSecond,
        to: &writer
    )
    writer.writeBit(false)
    writer.writeRBSPTrailingBits()

    var output = Data(nalu.prefix(2))
    output.append(hevcEBSP(from: writer.data()))
    return output
}

private func hevcProfile7AUDNALUnit(isSync: Bool) -> Data {
    var writer = HEVCBitWriter()
    writer.writeBits(isSync ? 0 : 1, count: 3)
    writer.writeRBSPTrailingBits()
    var nalu = Data([0x46, 0x01])
    nalu.append(hevcEBSP(from: writer.data()))
    return nalu
}

private func hevcSEINALUnit(payloadType: Int, payload: Data) -> Data {
    var rbsp = Data()
    appendSEIMessage(payloadType: payloadType, payload: payload, to: &rbsp)
    rbsp.append(0x80)
    var nalu = Data([0x4e, 0x01])
    nalu.append(hevcEBSP(from: rbsp))
    return nalu
}

private func hevcProfile7BufferingPeriodSEINALUnit(concatenationFlag: Bool) -> Data {
    var writer = HEVCBitWriter()
    writer.writeUE(0)
    writer.writeBit(false)
    writer.writeBit(concatenationFlag)
    writer.writeBits(0, count: 10)
    writer.writeBits(81_000, count: 19)
    writer.writeBits(9_000, count: 19)
    writer.byteAlignWithOneBit()
    return hevcSEINALUnit(payloadType: 0, payload: writer.data())
}

private func hevcProfile7PictureTimingSEINALUnit(framesSinceBufferingPeriod: UInt64) -> Data {
    let removalDelayMinus1 = framesSinceBufferingPeriod == 0
        ? UInt64(0)
        : min(framesSinceBufferingPeriod - 1, 1023)
    var writer = HEVCBitWriter()
    writer.writeBits(removalDelayMinus1, count: 10)
    writer.writeBits(0, count: 6)
    writer.byteAlignWithOneBit()
    return hevcSEINALUnit(payloadType: 1, payload: writer.data())
}

private func hevcLengthPrefixedNALUnits(from sampleBuffer: CMSampleBuffer) throws -> [Data] {
    guard let data = compressedData(from: sampleBuffer) else {
        throw HEVCBitstreamError.invalidData("Could not read HEVC sample data.")
    }
    let lengthSize = hevcNALUnitLengthSize(from: sampleBuffer)
    var cursor = 0
    var nalUnits: [Data] = []
    while cursor + lengthSize <= data.count {
        let nalLength = readLengthPrefix(data, at: cursor, byteCount: lengthSize)
        cursor += lengthSize
        guard nalLength > 0, cursor + nalLength <= data.count else {
            throw HEVCBitstreamError.invalidData("Invalid HEVC length-prefixed NAL unit.")
        }
        nalUnits.append(Data(data[cursor..<(cursor + nalLength)]))
        cursor += nalLength
    }
    guard cursor == data.count else {
        throw HEVCBitstreamError.invalidData("Trailing bytes after HEVC sample NAL units.")
    }
    return nalUnits
}

private func appendAnnexBNALUnit(_ nalu: Data, to output: inout Data) {
    output.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
    output.append(nalu)
}

final class DolbyVisionProfile7DualWriter: @unchecked Sendable {
    let baseLayerURL: URL
    let enhancementLayerURL: URL

    private let baseLayerHandle: FileHandle
    private let enhancementLayerHandle: FileHandle
    private let fpsInfo: FramerateInfo
    private let baseLayerBitrateBitsPerSecond: Int
    private let enhancementLayerBitrateBitsPerSecond: Int
    private var frameIndex: UInt64 = 0
    private var framesSinceBufferingPeriod: UInt64 = 0
    private var isClosed = false

    static func outputURLs(for outputURL: URL) -> (baseLayerURL: URL, enhancementLayerURL: URL) {
        let directory = outputURL.deletingLastPathComponent()
        let basename = outputURL.deletingPathExtension().lastPathComponent
        return (
            directory.appendingPathComponent("\(basename)_P7_6_BL.hevc"),
            directory.appendingPathComponent("\(basename)_P7_6_EL.hevc")
        )
    }

    init(outputURL: URL, fpsInfo: FramerateInfo, totalBitrateMbps: Double) throws {
        let urls = Self.outputURLs(for: outputURL)
        baseLayerURL = urls.baseLayerURL
        enhancementLayerURL = urls.enhancementLayerURL
        self.fpsInfo = fpsInfo
        baseLayerBitrateBitsPerSecond = Int((totalBitrateMbps * 0.74 * 1_000_000.0).rounded())
        enhancementLayerBitrateBitsPerSecond = Int((totalBitrateMbps * 0.26 * 1_000_000.0).rounded())

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: baseLayerURL)
        try? fileManager.removeItem(at: enhancementLayerURL)
        guard fileManager.createFile(atPath: baseLayerURL.path, contents: nil),
              fileManager.createFile(atPath: enhancementLayerURL.path, contents: nil) else {
            throw HEVCBitstreamError.invalidData(
                "Could not create Profile 7.6 BL/EL elementary-stream output files."
            )
        }
        baseLayerHandle = try FileHandle(forWritingTo: baseLayerURL)
        enhancementLayerHandle = try FileHandle(forWritingTo: enhancementLayerURL)
    }

    deinit {
        try? finish()
    }

    func write(frame: DolbyVisionProfile7EncodedFrame, hdr10Metadata: HEVCHDR10Metadata?) throws {
        let isSync = sampleBufferIsSync(frame.baseLayerSample)
        let framesSinceBPForPicture = isSync ? 0 : framesSinceBufferingPeriod + 1
        let concatenationFlag = isSync && frameIndex > 0

        let baseAccessUnit = try makeAccessUnit(
            sample: frame.baseLayerSample,
            isSync: isSync,
            framesSinceBufferingPeriod: framesSinceBPForPicture,
            concatenationFlag: concatenationFlag,
            bitrateBitsPerSecond: baseLayerBitrateBitsPerSecond,
            hdr10Metadata: hdr10Metadata,
            rpuNALUnit: nil
        )
        baseLayerHandle.write(baseAccessUnit)

        let enhancementAccessUnit = try makeAccessUnit(
            sample: frame.enhancementLayerSample,
            isSync: isSync,
            framesSinceBufferingPeriod: framesSinceBPForPicture,
            concatenationFlag: concatenationFlag,
            bitrateBitsPerSecond: enhancementLayerBitrateBitsPerSecond,
            hdr10Metadata: profile7EnhancementLayerHDR10Metadata(from: hdr10Metadata),
            rpuNALUnit: frame.rpuNALUnit
        )
        enhancementLayerHandle.write(enhancementAccessUnit)

        if isSync {
            framesSinceBufferingPeriod = 0
        } else {
            framesSinceBufferingPeriod += 1
        }
        frameIndex += 1
    }

    func finish() throws {
        guard !isClosed else { return }
        isClosed = true
        baseLayerHandle.synchronizeFile()
        enhancementLayerHandle.synchronizeFile()
        baseLayerHandle.closeFile()
        enhancementLayerHandle.closeFile()
    }

    private func makeAccessUnit(
        sample: CMSampleBuffer,
        isSync: Bool,
        framesSinceBufferingPeriod: UInt64,
        concatenationFlag: Bool,
        bitrateBitsPerSecond: Int,
        hdr10Metadata: HEVCHDR10Metadata?,
        rpuNALUnit: Data?
    ) throws -> Data {
        var output = Data()
        appendAnnexBNALUnit(hevcProfile7AUDNALUnit(isSync: isSync), to: &output)

        if isSync {
            let parameterSets = hevcParameterSets(from: sample)
            guard !parameterSets.isEmpty else {
                throw HEVCBitstreamError.invalidData("HEVC keyframe is missing parameter sets.")
            }
            for parameterSet in parameterSets {
                guard let nalType = hevcNALType(parameterSet) else { continue }
                let patchedParameterSet: Data
                switch nalType {
                case 32:
                    patchedParameterSet = try hevcNALByPatchingProfile7VPS(
                        parameterSet,
                        fpsInfo: fpsInfo
                    )
                case 33:
                    patchedParameterSet = try hevcNALByPatchingProfile7SPS(
                        parameterSet,
                        fpsInfo: fpsInfo,
                        bitrateBitsPerSecond: bitrateBitsPerSecond
                    )
                default:
                    patchedParameterSet = parameterSet
                }
                appendAnnexBNALUnit(patchedParameterSet, to: &output)
            }
            appendAnnexBNALUnit(
                hevcProfile7BufferingPeriodSEINALUnit(
                    concatenationFlag: concatenationFlag
                ),
                to: &output
            )
        }

        appendAnnexBNALUnit(
            hevcProfile7PictureTimingSEINALUnit(
                framesSinceBufferingPeriod: framesSinceBufferingPeriod
            ),
            to: &output
        )
        if let hdr10SEINALUnit = makeHEVCPrefixSEINALUnit(metadata: hdr10Metadata) {
            appendAnnexBNALUnit(hdr10SEINALUnit, to: &output)
        }

        for nalu in try hevcLengthPrefixedNALUnits(from: sample) {
            guard let nalType = hevcNALType(nalu) else { continue }
            switch nalType {
            case 32, 33, 34, 35, 39, 40, 62, 63:
                continue
            default:
                appendAnnexBNALUnit(nalu, to: &output)
            }
        }

        if let rpuNALUnit {
            appendAnnexBNALUnit(rpuNALUnit, to: &output)
        }
        return output
    }
}

private extension OSStatus {
    func flatMapNoErr(_ body: () -> OSStatus) -> OSStatus {
        self == noErr ? body() : self
    }
}
