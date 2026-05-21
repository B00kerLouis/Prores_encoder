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
    let generatedURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("prores_encoder_rpu_\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: generatedURL) }

    try runDoviTool(
        toolURL,
        arguments: [
            "generate",
            "--xml", xmlURL.path,
            "--profile", profile.doviToolProfileArgument,
            "--rpu-out", generatedURL.path
        ],
        operation: "RPU generation")

    switch profile {
    case .profile81:
        return try addProfile81Level4IfNeeded(
            toolURL: toolURL,
            generatedRPUURL: generatedURL)
    }
}

private func addProfile81Level4IfNeeded(
    toolURL: URL,
    generatedRPUURL: URL
) throws -> [Data] {
    let generatedRPUs = try parseDoviToolRPUFile(generatedRPUURL)
    guard !generatedRPUs.isEmpty else { return generatedRPUs }

    let tempDirectory = FileManager.default.temporaryDirectory
    let generatorJSONURL = tempDirectory
        .appendingPathComponent("prores_encoder_l4_generate_\(UUID().uuidString).json")
    let l4ReferenceURL = tempDirectory
        .appendingPathComponent("prores_encoder_l4_reference_\(UUID().uuidString).bin")
    let editorJSONURL = tempDirectory
        .appendingPathComponent("prores_encoder_l4_edit_\(UUID().uuidString).json")
    let editedURL = tempDirectory
        .appendingPathComponent("prores_encoder_rpu_l4_\(UUID().uuidString).bin")
    defer {
        try? FileManager.default.removeItem(at: generatorJSONURL)
        try? FileManager.default.removeItem(at: l4ReferenceURL)
        try? FileManager.default.removeItem(at: editorJSONURL)
        try? FileManager.default.removeItem(at: editedURL)
    }

    let generatorConfig: [String: Any] = [
        "cm_version": "V40",
        "profile": DolbyVisionHEVCProfile.profile81.doviToolProfileArgument,
        "length": generatedRPUs.count,
        "level6": [
            "max_display_mastering_luminance": 1000,
            "min_display_mastering_luminance": 1,
            "max_content_light_level": 1000,
            "max_frame_average_light_level": 400
        ],
        "default_metadata_blocks": [
            [
                "Level4": [
                    "anchor_pq": 0,
                    "anchor_power": 0
                ]
            ]
        ]
    ]
    let generatorData = try JSONSerialization.data(
        withJSONObject: generatorConfig,
        options: [.prettyPrinted, .sortedKeys])
    try generatorData.write(to: generatorJSONURL, options: .atomic)
    try runDoviTool(
        toolURL,
        arguments: [
            "generate",
            "--json", generatorJSONURL.path,
            "--rpu-out", l4ReferenceURL.path
        ],
        operation: "Profile 8.1 Level4 reference generation")

    let editorConfig: [String: Any] = [
        "source_rpu": l4ReferenceURL.path,
        "rpu_levels": [4]
    ]
    let editorData = try JSONSerialization.data(
        withJSONObject: editorConfig,
        options: [.prettyPrinted, .sortedKeys])
    try editorData.write(to: editorJSONURL, options: .atomic)
    try runDoviTool(
        toolURL,
        arguments: [
            "editor",
            "-i", generatedRPUURL.path,
            "-j", editorJSONURL.path,
            "-o", editedURL.path
        ],
        operation: "Profile 8.1 Level4 RPU merge")

    return try parseDoviToolRPUFile(editedURL)
}

private func runDoviTool(
    _ toolURL: URL,
    arguments: [String],
    operation: String
) throws {
    let process = Process()
    process.executableURL = toolURL
    process.arguments = arguments
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
                "dovi_tool \(operation) failed.\(detail.isEmpty ? "" : "\n\(detail)")"
            ]
        )
    }
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
    rpuNALUnit: Data,
    hdr10Metadata: HEVCHDR10Metadata? = nil
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
