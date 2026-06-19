import Darwin
import Foundation
import ProResEncoderFramework

@main
struct FrameworkParityHarness {
    static func main() async {
        guard CommandLine.arguments.count >= 4 else {
            fputs(
                "usage: FrameworkParityHarness <input> <output> <quality> [bitrate] [profile] [xml]\n",
                stderr
            )
            exit(2)
        }

        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let quality = CommandLine.arguments[3]
        let bitrate = CommandLine.arguments.count > 4
            ? Double(CommandLine.arguments[4])
            : nil
        let profile: ProResDolbyVisionProfile?
        if CommandLine.arguments.count > 5 {
            profile = ProResDolbyVisionProfile(
                rawValue: CommandLine.arguments[5]
            )
        } else {
            profile = nil
        }
        let xmlURL = CommandLine.arguments.count > 6
            ? URL(fileURLWithPath: CommandLine.arguments[6])
            : nil
        let useDolbyVisionCodecTag = CommandLine.arguments.dropFirst(7)
            .contains("--dv-flag")

        do {
            let result = try await ProResEncoder().encode(
                inputURL: inputURL,
                outputURL: outputURL,
                options: ProResEncodeOptions(
                    quality: quality,
                    dolbyVisionXMLURL: xmlURL,
                    bitrateMbps: bitrate,
                    dolbyVisionProfile: profile,
                    useDolbyVisionCodecTag: useDolbyVisionCodecTag
                )
            )
            guard result.outputURLs.contains(outputURL) else {
                throw ProResEncoderError.encodingFailed(
                    "Framework result did not report the requested output URL."
                )
            }
            print("[Framework Success] \(outputURL.path)")
        } catch {
            fputs("[Framework Failed] \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
