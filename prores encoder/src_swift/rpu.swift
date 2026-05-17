// rpu.swift — Dolby Vision RPU generation and HEVC sample injection

import Foundation
import AVFoundation

final class DolbyVisionRPUProvider: @unchecked Sendable {
    private let task: Task<[Data], Error>
    private let expectedFrameCount: Int64

    init(xmlURL: URL, profile: DolbyVisionHEVCProfile, expectedFrameCount: Int64) {
        self.expectedFrameCount = expectedFrameCount
        task = Task.detached(priority: .userInitiated) {
            try generateDolbyVisionRPUNALUnits(xmlURL: xmlURL, profile: profile)
        }
    }

    func rpu(forFrame frameIndex: Int64) async throws -> Data {
        let rpus = try await task.value
        if expectedFrameCount > 0, Int64(rpus.count) != expectedFrameCount {
            throw NSError(
                domain: "DolbyVisionRPU",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Generated RPU count is \(rpus.count), but source video is estimated at \(expectedFrameCount) frames."
                ]
            )
        }
        guard !rpus.isEmpty else {
            throw NSError(
                domain: "DolbyVisionRPU",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "dovi_tool generated no RPU frames."]
            )
        }
        if frameIndex < Int64(rpus.count) {
            return rpus[Int(frameIndex)]
        }
        return rpus[rpus.count - 1]
    }

    func waitForCompletion() async throws -> Int {
        try await task.value.count
    }
}

private func generateDolbyVisionRPUNALUnits(
    xmlURL: URL,
    profile: DolbyVisionHEVCProfile
) throws -> [Data] {
    let toolURL = try resolveDoviToolExecutableURL()
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("prores_encoder_rpu_\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let process = Process()
    process.executableURL = toolURL
    process.arguments = [
        "generate",
        "--xml", xmlURL.path,
        "--profile", profile.doviToolProfileArgument,
        "--rpu-out", tempURL.path
    ]
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        let detail = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        throw NSError(
            domain: "DolbyVisionRPU",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey:
                "dovi_tool RPU generation failed.\(detail.isEmpty ? "" : "\n\(detail)")"
            ]
        )
    }

    return try parseDoviToolRPUFile(tempURL)
}

private func resolveDoviToolExecutableURL() throws -> URL {
    let fm = FileManager.default
    var candidates: [String] = []
    if let env = ProcessInfo.processInfo.environment["DOVI_TOOL"], !env.isEmpty {
        candidates.append(env)
    }
    candidates.append(contentsOf: [
        "/opt/homebrew/bin/dovi_tool",
        "/usr/local/bin/dovi_tool",
        "/Volumes/HP_SSD_FX900_Pro /Xcode_WorkSpace/dovi_tool/target/release/dovi_tool",
        "/Volumes/HP_SSD_FX900_Pro /Xcode_WorkSpace/dovi_tool/target/debug/dovi_tool"
    ])

    for candidate in candidates {
        if fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
    }

    throw NSError(
        domain: "DolbyVisionRPU",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey:
            "dovi_tool executable was not found. Install dovi_tool or set DOVI_TOOL to its executable path."
        ]
    )
}

private func parseDoviToolRPUFile(_ url: URL) throws -> [Data] {
    let data = try Data(contentsOf: url)
    var starts: [Int] = []
    var i = 0
    while i + 4 <= data.count {
        if data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
            starts.append(i)
            i += 4
        } else {
            i += 1
        }
    }

    guard !starts.isEmpty else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Generated RPU file has no HEVC start codes."]
        )
    }

    var rpus: [Data] = []
    for (index, start) in starts.enumerated() {
        let payloadStart = start + 4
        let payloadEnd = index + 1 < starts.count ? starts[index + 1] : data.count
        guard payloadEnd > payloadStart else { continue }
        var nalu = Data(data[payloadStart..<payloadEnd])
        while let last = nalu.last, last == 0 {
            nalu.removeLast()
        }
        if nalu.count >= 2, nalu[0] == 0x7c, nalu[1] == 0x01 {
            rpus.append(nalu)
        } else {
            var withHeader = Data([0x7c, 0x01])
            withHeader.append(nalu)
            rpus.append(withHeader)
        }
    }
    return rpus
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

private func compressedData(from sampleBuffer: CMSampleBuffer) -> Data? {
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

private func copySampleAttachments(from source: CMSampleBuffer, to destination: CMSampleBuffer) {
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
    rpuNALUnit: Data
) throws -> CMSampleBuffer {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let data = compressedData(from: sampleBuffer) else {
        throw NSError(
            domain: "DolbyVisionRPU",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not read encoded HEVC sample data."]
        )
    }

    let lengthSize = hevcNALUnitLengthSize(from: sampleBuffer)
    var output = Data()
    output.reserveCapacity(data.count + rpuNALUnit.count + lengthSize)

    var cursor = 0
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
        output.append(lengthPrefixData(nalLength, byteCount: lengthSize))
        output.append(nalu)
    }

    output.append(lengthPrefixData(rpuNALUnit.count, byteCount: lengthSize))
    output.append(rpuNALUnit)

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
        sampleBuffer,
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
    copySampleAttachments(from: sampleBuffer, to: injectedSample)
    return injectedSample
}

private extension OSStatus {
    func flatMapNoErr(_ body: () -> OSStatus) -> OSStatus {
        self == noErr ? body() : self
    }
}
