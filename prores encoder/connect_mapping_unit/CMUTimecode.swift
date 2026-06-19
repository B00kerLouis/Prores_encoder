import Foundation
@preconcurrency import AVFoundation
import CoreMedia

func cmuResolveTimecodeReference(
    analyzedURL: URL,
    fallbackInputURL: URL?,
    forcedStartTimecode: String?,
    editRate: CMURational
) async throws -> CMUTimecodeReference {
    if let reference = try await cmuReadQuickTimeTimecode(url: analyzedURL) {
        return reference
    }
    if let fallbackInputURL,
       fallbackInputURL.standardizedFileURL != analyzedURL.standardizedFileURL,
       let reference = try await cmuReadQuickTimeTimecode(url: fallbackInputURL) {
        return reference
    }
    if let forcedStartTimecode {
        let fps = cmuTimecodeFrameQuanta(editRate)
        let isDropFrame = forcedStartTimecode.contains(";")
        guard let frame = cmuParseTimecodeFrame(
            forcedStartTimecode,
            fps: fps,
            dropFrame: isDropFrame
        ) else {
            throw CMUError.invalidTimecode(forcedStartTimecode)
        }
        return CMUTimecodeReference(
            startFrame: frame,
            stringValue: forcedStartTimecode,
            isDropFrame: isDropFrame,
            origin: .ffoa
        )
    }
    return CMUTimecodeReference(
        startFrame: 0,
        stringValue: cmuFormatTimecode(frame: 0, fps: cmuTimecodeFrameQuanta(editRate), dropFrame: false),
        isDropFrame: false,
        origin: .zero
    )
}
private func cmuReadQuickTimeTimecode(url: URL) async throws -> CMUTimecodeReference? {
    let asset = AVURLAsset(
        url: url,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    guard let track = try await asset.loadTracks(withMediaType: .timecode).first else {
        return nil
    }
    guard let format = try await track.load(.formatDescriptions).first else {
        return nil
    }

    let frameQuanta = max(Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format)), 1)
    let flags = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format)
    let isDropFrame = (flags & kCMTimeCodeFlag_DropFrame) != 0
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    guard reader.startReading() else { return nil }
    guard let sample = output.copyNextSampleBuffer(),
          let block = CMSampleBufferGetDataBuffer(sample),
          CMBlockBufferGetDataLength(block) >= 4 else {
        return nil
    }

    var raw = Int32.zero
    let status = withUnsafeMutableBytes(of: &raw) { bytes in
        CMBlockBufferCopyDataBytes(
            block,
            atOffset: 0,
            dataLength: 4,
            destination: bytes.baseAddress!
        )
    }
    guard status == kCMBlockBufferNoErr else { return nil }
    let startFrame = Int64(Int32(bigEndian: raw))
    return CMUTimecodeReference(
        startFrame: startFrame,
        stringValue: cmuFormatTimecode(
            frame: startFrame,
            fps: frameQuanta,
            dropFrame: isDropFrame
        ),
        isDropFrame: isDropFrame,
        origin: .quickTime
    )
}

private func cmuTimecodeFrameQuanta(_ editRate: CMURational) -> Int {
    let fps = editRate.fps
    let known: [(Double, Int)] = [
        (23.976, 24),
        (24, 24),
        (25, 25),
        (29.97, 30),
        (30, 30),
        (50, 50),
        (59.94, 60),
        (60, 60)
    ]
    for (reference, quanta) in known where abs(fps - reference) < 0.02 {
        return quanta
    }
    return max(Int(fps.rounded()), 1)
}

private func cmuParseTimecodeFrame(
    _ value: String,
    fps: Int,
    dropFrame: Bool
) -> Int64? {
    let parts = value
        .replacingOccurrences(of: ";", with: ":")
        .split(separator: ":")
    guard parts.count == 4,
          let hours = Int64(parts[0]),
          let minutes = Int64(parts[1]),
          let seconds = Int64(parts[2]),
          let frames = Int64(parts[3]),
          hours >= 0,
          minutes >= 0,
          minutes < 60,
          seconds >= 0,
          seconds < 60,
          frames >= 0,
          frames < Int64(fps) else {
        return nil
    }

    let nominal = ((hours * 3600 + minutes * 60 + seconds) * Int64(fps)) + frames
    guard dropFrame else { return nominal }
    guard fps == 30 || fps == 60 else { return nil }
    let dropFrames = Int64(fps / 15)
    let totalMinutes = hours * 60 + minutes
    return nominal - dropFrames * (totalMinutes - totalMinutes / 10)
}

private func cmuFormatTimecode(frame: Int64, fps: Int, dropFrame: Bool) -> String {
    let safeFrame = max(frame, 0)
    if dropFrame, fps == 30 || fps == 60 {
        let dropFrames = Int64(fps / 15)
        let framesPerMinute = Int64(fps * 60) - dropFrames
        let framesPerTenMinutes = Int64(fps * 60 * 10) - dropFrames * 9
        let tenMinuteBlocks = safeFrame / framesPerTenMinutes
        let remainder = safeFrame % framesPerTenMinutes
        let extraMinutes = max(
            Int64.zero,
            (remainder - Int64(fps * 60)) / framesPerMinute + 1
        )
        let nominal = safeFrame + dropFrames * (tenMinuteBlocks * 9 + extraMinutes)
        let frames = nominal % Int64(fps)
        let totalSeconds = nominal / Int64(fps)
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = (totalMinutes / 60) % 24
        return String(
            format: "%02lld:%02lld:%02lld;%02lld",
            hours, minutes, seconds, frames
        )
    }

    let frames = safeFrame % Int64(fps)
    let totalSeconds = safeFrame / Int64(fps)
    let seconds = totalSeconds % 60
    let totalMinutes = totalSeconds / 60
    let minutes = totalMinutes % 60
    let hours = (totalMinutes / 60) % 24
    return String(
        format: "%02lld:%02lld:%02lld:%02lld",
        hours, minutes, seconds, frames
    )
}
