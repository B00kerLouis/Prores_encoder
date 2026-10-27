// Copyright © 2026 B00kerLouis. All rights reserved.
// Independent AVFoundation container/timestamp and optional full decode check.
import Foundation
@preconcurrency import AVFoundation

@main
struct NativeMovieReaderCheck {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 5, let frames = Int(args[2]), let numerator = Int32(args[3]),
              let denominator = Int64(args[4]), frames > 0, numerator > 0, denominator > 0 else {
            throw NSError(domain: "NativeMovieReaderCheck", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Usage: native-reader movie frames numerator denominator [--decode]"])
        }
        let decode = args.contains("--decode")
        let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "NativeMovieReaderCheck", code: 2)
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any]? = decode ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : nil
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NSError(domain: "NativeMovieReaderCheck", code: 3) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "NativeMovieReaderCheck", code: 4) }
        var timestamps: [CMTime] = []
        while true {
            let next: CMTime? = try autoreleasepool {
                while let sample = output.copyNextSampleBuffer() {
                    if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                    guard CMSampleBufferGetNumSamples(sample) == 1,
                          !decode || CMSampleBufferGetImageBuffer(sample) != nil else {
                        throw NSError(domain: "NativeMovieReaderCheck", code: 5)
                    }
                    return CMSampleBufferGetPresentationTimeStamp(sample)
                }
                return nil
            }
            guard let next else { break }
            timestamps.append(next)
        }
        guard reader.status == .completed, timestamps.count == frames else {
            throw reader.error ?? NSError(domain: "NativeMovieReaderCheck", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Native reader returned \(timestamps.count)/\(frames) frames, status \(reader.status.rawValue)"])
        }
        timestamps.sort { CMTimeCompare($0, $1) < 0 }
        for (index, pts) in timestamps.enumerated() {
            let expected = CMTime(value: Int64(index) * denominator, timescale: numerator)
            guard CMTimeCompare(pts, expected) == 0 else {
                throw NSError(domain: "NativeMovieReaderCheck", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Native timestamp mismatch at picture \(index): \(pts), expected \(expected)"])
            }
        }
        let duration = try await track.load(.timeRange).duration
        let expectedDuration = CMTime(value: Int64(frames) * denominator, timescale: numerator)
        guard CMTimeCompare(duration, expectedDuration) == 0 else {
            throw NSError(domain: "NativeMovieReaderCheck", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Native duration mismatch: \(duration), expected \(expectedDuration)"])
        }
        let report: [String: Any] = ["path": args[1], "native_frames": timestamps.count,
            "decoded": decode, "numerator": numerator, "denominator": denominator,
            "duration_seconds": duration.seconds]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
