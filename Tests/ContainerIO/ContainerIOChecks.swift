// Copyright © 2026 B00kerLouis. All rights reserved.
// SDK-free integration checks. Host PCM negotiation is tested separately in MC.
import Foundation
import AVFoundation
import ProResEncoderFramework

@main struct ContainerIOChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ContainerIOChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        let a = CommandLine.arguments
        guard a.count >= 3 else { throw NSError(domain: "ContainerIOChecks", code: 2) }
        if a[1] == "audio" || a[1] == "stereo" || a[1] == "cancel" {
            let destination = URL(fileURLWithPath: a[2])
            let sentinel = Data("existing output must survive cancellation".utf8)
            if a[1] == "cancel" { try sentinel.write(to: destination) }
            let session = ProResFrameStreamSession(outputURL: destination, width: 320, height: 180,
                fpsNumerator: 30000, fpsDenominator: 1001, quality: "proxy", containerExtension: "mov",
                bitrateMbps: 0, includeDolbyVision: false,
                advancedOptions: ["amaHostAudioEnabled": true, "amaBounceMix": a[1] == "stereo", "deleteSourceAudio": false] as NSDictionary)
            var picture = Data(count: 320 * 180 * 4)
            for index in 0..<60 {
                picture.withUnsafeMutableBytes { raw in
                    let words = raw.bindMemory(to: UInt32.self)
                    for n in words.indices { words[n] = 0xff000000 | UInt32(index * 3) << 16 | UInt32(n % 256) }
                }
                try require(session.appendBGRAFrame(picture, stride: 1280), session.lastErrorMessage)
            }
            if a[1] == "cancel" {
                session.cancel()
                try require(try Data(contentsOf: destination) == sentinel, "cancellation replaced the existing output")
                print("PASS cancellation preserves existing output")
                return
            }
            try require(session.setTimelineAudioFiles(Array(a.dropFirst(3))), session.lastErrorMessage)
            try require(session.finish(), session.lastErrorMessage)
            let asset = AVURLAsset(url: destination)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            try require(audio.count == (a[1] == "stereo" ? 1 : a.count - 3), "host PCM track count changed")
            for track in audio {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output); try require(reader.startReading(), "PCM reader failed")
                var samples = 0
                while let sample = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
                try require(reader.status == .completed && samples == 96096, "expected 96096 PCM samples, got \(samples)")
            }
            print("PASS 60 video pictures, \(audio.count) PCM tracks, 96096 samples per track")
        } else if a[1] == "extra" {
            guard a.count == 5, let format = ProResOutputFormat(rawValue: URL(fileURLWithPath: a[3]).pathExtension) else { throw NSError(domain: "ContainerIOChecks", code: 3) }
            _ = try await ProResEncoder().encode(inputURL: URL(fileURLWithPath: a[2]), outputURL: URL(fileURLWithPath: a[3]), format: format,
                options: ProResEncodeOptions(quality: "h264", extraAudioURL: URL(fileURLWithPath: a[4]), replaceSourceAudio: true, bitrateMbps: 8, multiPass: false))
            print("PASS opaque extra audio -> \(a[3])")
        } else {
            guard a.count == 5, let format = ProResOutputFormat(rawValue: URL(fileURLWithPath: a[3]).pathExtension) else { throw NSError(domain: "ContainerIOChecks", code: 3) }
            let result = try await ProResEncoder().encode(inputURL: URL(fileURLWithPath: a[2]), outputURL: URL(fileURLWithPath: a[3]),
                format: format, options: ProResEncodeOptions(quality: a[4], bitrateMbps: a[4] == "pass" ? nil : 8,
                    multiPass: a[4] == "h264" || a[4] == "hevc" ? false : nil))
            try require(!result.outputURLs.isEmpty, "no output")
            print("PASS \(a[2]) -> \(a[3]) (\(a[4]))")
        }
    }
}
