import Foundation
import swiftaaf_Framework

private let swiftAAFVideoPhysicalTrackNumber: UInt32 = 0x15011700
private let swiftAAFAudioPhysicalTrackNumber: UInt32 = 0x16010100

func generateAAFWithSwiftAAF(clips: [AAFClipInfo], outputPath: String, sequenceName: String) -> Bool {
    guard !clips.isEmpty else {
        print("[AAF] No clips to sequence.")
        return false
    }

    do {
        let linkedClips = try clips.map { try makeSwiftAAFClip(from: $0) }
        let outputURL = URL(fileURLWithPath: outputPath)
        try swiftaaf_Framework.AAFMXFSequenceWriter().write(
            clips: linkedClips,
            to: outputURL,
            options: swiftaaf_Framework.AAFMXFSequenceWriterOptions(
                sequenceName: sequenceName,
                locatorStyle: .fileURL,
                productName: "prores encoder",
                companyName: "prores encoder"
            )
        )

        guard FileManager.default.fileExists(atPath: outputPath) else {
            print("[AAF] Expected output file was not created: \(outputPath)")
            return false
        }
        print("[AAF] SwiftAAF wrote \(outputPath)")
        return true
    } catch {
        print("[AAF] SwiftAAF generation failed: \(error.localizedDescription)")
        return false
    }
}

func generateAAFPerClipWithSwiftAAF(clips: [AAFClipInfo], outputDir: URL, basename: String) -> Bool {
    guard !clips.isEmpty else {
        print("[AAF] No clips to export.")
        return false
    }

    var ok = true
    for (index, clip) in clips.enumerated() {
        let suffix = clips.count == 1 ? "" : "_\(index + 1)"
        let clipName = clipSequenceName(clip, fallback: "\(basename)\(suffix)")
        let outputPath = outputDir.appendingPathComponent("\(basename)\(suffix).aaf").path
        ok = generateAAFWithSwiftAAF(clips: [clip], outputPath: outputPath, sequenceName: clipName) && ok
    }
    return ok
}

private func makeSwiftAAFClip(from clip: AAFClipInfo) throws -> swiftaaf_Framework.AAFLinkedMXFClip {
    let editRate = swiftaaf_Framework.AAFRational(Int64(clip.fpsNumerator), Int64(clip.fpsDenominator))
    let videoMobID = try sourceMobID(from: clip.videoMXFUMID, label: "video")
    let videoName = URL(fileURLWithPath: clip.videoMXFPath).deletingPathExtension().lastPathComponent
    let operation: swiftaaf_Framework.AAFLinkedMXFOperation = clip.isOPAtom ? .opAtom : .op1a

    return swiftaaf_Framework.AAFLinkedMXFClip(
        name: clipSequenceName(clip, fallback: videoName),
        operation: operation,
        videoMXFPath: clip.videoMXFPath,
        videoSourceMobID: videoMobID,
        videoSourceMobName: clip.isOPAtom ? videoName : nil,
        videoPhysicalTrackNumber: clip.isOPAtom ? swiftAAFVideoPhysicalTrackNumber : nil,
        videoDescriptorLength: clip.isOPAtom ? clip.duration : nil,
        videoDescriptorKind: .cdci,
        videoCompression: swiftaaf_Framework.AAFProResCompressionAUID.from(variant: clip.codecVariant),
        width: clip.width,
        height: clip.height,
        durationFrames: clip.duration,
        editRate: editRate,
        isDropFrame: clip.isDropFrame,
        startTimecode: clip.timecode,
        audioTracks: try makeSwiftAAFAudioTracks(from: clip, editRate: editRate)
    )
}

private func makeSwiftAAFAudioTracks(
    from clip: AAFClipInfo,
    editRate: swiftaaf_Framework.AAFRational
) throws -> [swiftaaf_Framework.AAFLinkedMXFAudioTrack] {
    guard clip.audioTrackCount > 0 else {
        return []
    }

    let audioCounts = normalizedAudioChannelCounts(for: clip)
    if clip.isOPAtom {
        return try clip.audioMXFPaths.enumerated().map { index, path in
            guard index < clip.audioMXFUMIDs.count else {
                throw AAFExportError.invalidSourceMobID("missing audio UMID for \(path)")
            }
            let sourceMobID = try sourceMobID(from: clip.audioMXFUMIDs[index], label: "audio \(index + 1)")
            let channelCount = audioCounts.indices.contains(index) ? audioCounts[index] : max(clip.audioChannels, 1)
            return swiftaaf_Framework.AAFLinkedMXFAudioTrack(
                mxfPath: path,
                sourceMobID: sourceMobID,
                sourceMobName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                lengthSamples: clip.totalAudioSamples,
                fileLengthSamples: clip.totalAudioSamples,
                physicalTrackNumber: swiftAAFAudioPhysicalTrackNumber,
                sampleRate: clip.audioSampleRate,
                channelCount: channelCount,
                quantizationBits: clip.audioBits,
                blockAlign: channelCount * max(clip.audioBits / 8, 1),
                averageBytesPerSecond: clip.audioSampleRate * channelCount * max(clip.audioBits / 8, 1),
                timecodeEditRate: editRate,
                timecodeLengthFrames: clip.duration,
                slotName: "Audio"
            )
        }
    }

    let channelCount = audioCounts.first ?? max(clip.audioChannels, 1)
    return [
        swiftaaf_Framework.AAFLinkedMXFAudioTrack(
            mxfPath: "",
            sourceMobID: try sourceMobID(from: clip.videoMXFUMID, label: "OP-1a audio"),
            lengthSamples: clip.totalAudioSamples,
            sampleRate: clip.audioSampleRate,
            channelCount: channelCount,
            quantizationBits: clip.audioBits,
            blockAlign: channelCount * max(clip.audioBits / 8, 1),
            averageBytesPerSecond: clip.audioSampleRate * channelCount * max(clip.audioBits / 8, 1),
            slotName: "Sound Track"
        )
    ]
}

private func normalizedAudioChannelCounts(for clip: AAFClipInfo) -> [Int] {
    let counts = clip.audioChannelCounts.filter { $0 > 0 }
    if !counts.isEmpty {
        return counts
    }
    guard clip.audioTrackCount > 0 else {
        return []
    }
    return Array(repeating: max(clip.audioChannels, 1), count: clip.audioTrackCount)
}

private func sourceMobID(from data: Data, label: String) throws -> swiftaaf_Framework.MobID {
    let bytes = Array(data)
    guard bytes.count == 32, bytes.contains(where: { $0 != 0 }) else {
        throw AAFExportError.invalidSourceMobID("invalid \(label) Source Package UMID")
    }
    return try swiftaaf_Framework.MobID(bytesLE: bytes)
}

private func clipSequenceName(_ clip: AAFClipInfo, fallback: String) -> String {
    let name = URL(fileURLWithPath: clip.videoMXFPath).deletingPathExtension().lastPathComponent
    return name.isEmpty ? fallback : name
}

private enum AAFExportError: LocalizedError {
    case invalidSourceMobID(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceMobID(let message):
            return message
        }
    }
}
