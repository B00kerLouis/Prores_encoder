import Foundation
import ProResEncoderFramework

/// Local hardware integration check. BGRA and packed 10.6 patterns declare
/// Rec.709/Gamma 2.4; they are not evidence of Media Composer color or delivery.
@main
struct FrameStreamCheckpoints {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6, let count = Int(args[2]), count > 0,
              let width = Int(args[3]), let height = Int(args[4]), width > 0, height > 0 else {
            throw NSError(domain: "Checkpoint", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Usage: checkpoint proxy|hevc|dolby5|dolby81|dolby81-packed frames width height output.mov"])
        }
        let mode = args[1]
        let profile81 = mode == "dolby81" || mode == "dolby81-packed"
        let packed = mode == "dolby81-packed"
        guard !packed || width.isMultiple(of: 2) else {
            throw NSError(domain: "Checkpoint", code: 1)
        }
        let quality = mode == "proxy" ? "proxy" : "hevc"
        let numerator = profile81 ? 24 : 30000
        let denominator = profile81 ? 1 : 1001
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
        if mode == "dolby5" || profile81 {
            options["dolbyVisionProfile"] = profile81 ? "81" : "5"
            options["cmuMasteringNits"] = 1000
            options["includeGeneratedDolbyVisionMetadata"] = true
            options["useDolbyVisionCodecTag"] = true
        }
        if profile81 { options["amaSharedColorPipeline"] = true }
        let start = ProcessInfo.processInfo.systemUptime
        let session = ProResFrameStreamSession(outputURL: URL(fileURLWithPath: args[5]),
            width: width, height: height, fpsNumerator: numerator, fpsDenominator: denominator,
            quality: quality, containerExtension: URL(fileURLWithPath: args[5]).pathExtension, bitrateMbps: 20,
            includeDolbyVision: mode == "dolby5" || profile81, advancedOptions: options as NSDictionary)
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
        if profile81 {
            // A large neutral white patch independently checks that the private
            // carrier holds PQ pixels and that finish does not tone-map twice.
            frame.withUnsafeMutableBytes { raw in
                if packed {
                    let words = raw.bindMemory(to: UInt16.self)
                    for row in 0..<height { for x in stride(from: 0, to: width, by: 2) {
                        let offset = row * width * 2 + x * 2
                        let grey = x >= width / 2 ? 940 : 64 + x * 876 / width
                        words[offset] = 512 << 6; words[offset + 1] = UInt16(grey) << 6
                        words[offset + 2] = 512 << 6; words[offset + 3] = UInt16(grey) << 6
                    } }
                } else {
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for row in 0..<height { for x in width / 2..<width {
                        let offset = (row * width + x) * 4
                        bytes[offset] = 255; bytes[offset + 1] = 255; bytes[offset + 2] = 255
                    } }
                }
            }
        }
        for index in 0..<count {
            // A moving patch verifies distinct frame content and ordering.
            if !packed {
                frame.withUnsafeMutableBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for x in 0..<min(width, 64) {
                        bytes[x * 4] = UInt8(index % 256)
                        bytes[x * 4 + 2] = UInt8(255 - index % 256)
                    }
                }
            } else {
                frame.withUnsafeMutableBytes { raw in
                    let words = raw.bindMemory(to: UInt16.self)
                    words[1] = UInt16(64 + index % 877) << 6
                }
            }
            let accepted = packed ? session.appendPacked422Frame(frame, stride: width * 4)
                : session.appendBGRAFrame(frame, stride: width * 4)
            guard accepted else {
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
        let mediaDuration = Double(count * denominator) / Double(numerator)
        let result: [String: Any] = ["mode": mode, "frames": count, "width": width, "height": height,
            "fpsNumerator": numerator, "fpsDenominator": denominator, "mediaDuration": mediaDuration,
            "elapsed": elapsed, "submitSeconds": submitted - start,
            "speed": mediaDuration / elapsed, "output": args[5]]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
