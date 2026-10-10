import Foundation
import ProResEncoderFramework

/// Local hardware integration check. The generated BGRA pattern has an explicit
/// Rec.709/Gamma 2.4 declaration; it is not evidence of Media Composer color.
@main
struct FrameStreamCheckpoints {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6, let count = Int(args[2]), count > 0,
              let width = Int(args[3]), let height = Int(args[4]), width > 0, height > 0 else {
            throw NSError(domain: "Checkpoint", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Usage: checkpoint proxy|hevc|dolby5 frames width height output.mov"])
        }
        let mode = args[1]
        let quality = mode == "proxy" ? "proxy" : "hevc"
        var options: [String: Any] = ["deleteSourceAudio": true,
            "inputColorGamut": "rec709", "inputColorTransfer": "gamma2.4"]
        if mode != "proxy" {
            options["colorMode"] = "direct"
            options["colorGamut"] = "rec2020"
            options["colorTransfer"] = "pq"
            options["colorPeakNits"] = 1000
            options["bFrames"] = false
            options["multiPass"] = false
        }
        if mode == "dolby5" {
            options["dolbyVisionProfile"] = "5"
            options["cmuMasteringNits"] = 1000
            options["includeGeneratedDolbyVisionMetadata"] = true
            options["useDolbyVisionCodecTag"] = true
        }
        let start = ProcessInfo.processInfo.systemUptime
        let session = ProResFrameStreamSession(outputURL: URL(fileURLWithPath: args[5]),
            width: width, height: height, fpsNumerator: 30000, fpsDenominator: 1001,
            quality: quality, containerExtension: "mov", bitrateMbps: 20,
            includeDolbyVision: mode == "dolby5", advancedOptions: options as NSDictionary)
        var frame = Data(count: width * height * 4)
        frame.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    bytes[offset] = UInt8((x * 255) / width)
                    bytes[offset + 1] = UInt8((y * 255) / height)
                    bytes[offset + 2] = 128
                    bytes[offset + 3] = 255
                }
            }
        }
        for index in 0..<count {
            // A moving patch verifies distinct frame content and ordering.
            frame.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for x in 0..<min(width, 64) {
                    bytes[x * 4] = UInt8(index % 256)
                    bytes[x * 4 + 2] = UInt8(255 - index % 256)
                }
            }
            guard session.appendBGRAFrame(frame, stride: width * 4) else {
                throw NSError(domain: "Checkpoint", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Frame \(index): \(session.lastErrorMessage)"])
            }
        }
        let submitted = ProcessInfo.processInfo.systemUptime
        guard session.finish() else {
            throw NSError(domain: "Checkpoint", code: 3,
                userInfo: [NSLocalizedDescriptionKey: session.lastErrorMessage])
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let mediaDuration = Double(count) * 1001 / 30000
        let result: [String: Any] = ["mode": mode, "frames": count, "width": width, "height": height,
            "fpsNumerator": 30000, "fpsDenominator": 1001, "mediaDuration": mediaDuration,
            "elapsed": elapsed, "submitSeconds": submitted - start,
            "speed": mediaDuration / elapsed, "output": args[5]]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
