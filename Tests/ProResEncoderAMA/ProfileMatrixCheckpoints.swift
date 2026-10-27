import Foundation
import ProResEncoderFramework

// B00kerLouis. SDK-free hardware regression; native MC acceptance is separate.
@main struct ProfileMatrixCheckpoints {
    static func main() throws {
        let a = CommandLine.arguments
        let flags = Set(a.dropFirst(7))
        let pq2020 = flags.contains("--pq2020")
        let pqP3D65 = flags.contains("--pqp3d65")
        let pqInput = pq2020 || pqP3D65
        let wire709 = flags.contains("--wire709")
        guard a.count >= 7, flags.isSubset(of: ["--pq2020", "--pqp3d65", "--wire709"]),
              !(pq2020 && pqP3D65), (!wire709 || pqInput), let frames = Int(a[3]), frames > 0,
              let numerator = Int(a[5]), let denominator = Int(a[6]) else {
            throw NSError(domain: "ProfileMatrix", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Usage: matrix profile gamut frames output.mp4 numerator denominator [--pq2020|--pqp3d65] [--wire709]"])
        }
        let profile = a[1], gamut = a[2], av1 = profile.hasPrefix("10")
        let width = profile == "76" ? 3840 : 320
        let height = profile == "76" ? 2160 : 180
        let hlg = profile == "84" || profile == "104"
        var options: [String: Any] = ["deleteSourceAudio": true,
            "inputColorGamut": pqP3D65 ? "p3d65" : (pq2020 ? "rec2020" : "rec709"),
            "inputColorTransfer": pqInput ? "pq" : "gamma2.4",
            "amaSharedColorPipeline": true, "colorMode": "direct", "colorGamut": gamut,
            "colorTransfer": hlg ? "hlg" : "pq", "colorPeakNits": 1000,
            "dolbyVisionProfile": profile, "cmuMasteringNits": 1000,
            "includeGeneratedDolbyVisionMetadata": true, "useDolbyVisionCodecTag": true]
        if !av1 { options["multiPass"] = false }
        if wire709 {
            options["amaPacked422Input"] = true
            options["amaPacked422Matrix"] = 709
        }
        let session = ProResFrameStreamSession(outputURL: URL(fileURLWithPath: a[4]),
            width: width, height: height, fpsNumerator: numerator, fpsDenominator: denominator,
            quality: av1 ? "av1" : "hevc", containerExtension: URL(fileURLWithPath: a[4]).pathExtension, bitrateMbps: 25,
            includeDolbyVision: true, advancedOptions: options as NSDictionary)
        // Packed Cb/Y0/Cr/Y1 10.6 with neutral ramp, white, and known primaries.
        var frame = Data(count: width * height * 4)
        frame.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt16.self)
            for row in 0..<height { for x in stride(from: 0, to: width, by: 2) {
                let rgb: (Double, Double, Double)
                switch x * 5 / width {
                case 0: rgb = (Double(x * 5) / Double(width), Double(x * 5) / Double(width), Double(x * 5) / Double(width))
                case 1: rgb = (1, 1, 1)
                case 2: rgb = (1, 0, 0)
                case 3: rgb = (0, 1, 0)
                default: rgb = (0, 0, 1)
                }
                // In PQ mode the signal spans the absolute 10000-nit domain,
                // matching the facade's documented fallback when host frames
                // carry no mastering payload. This is not a source-peak claim.
                let kr = pqInput && !wire709 ? 0.2627 : 0.2126
                let kb = pqInput && !wire709 ? 0.0593 : 0.0722
                let y = kr * rgb.0 + (1 - kr - kb) * rgb.1 + kb * rgb.2
                let cb = (rgb.2 - y) / (2 * (1 - kb))
                let cr = (rgb.0 - y) / (2 * (1 - kr))
                let offset = (row * width + x) * 2
                words[offset] = UInt16((512 + 896 * cb).rounded()) << 6
                words[offset + 1] = UInt16((64 + 876 * y).rounded()) << 6
                words[offset + 2] = UInt16((512 + 896 * cr).rounded()) << 6
                words[offset + 3] = words[offset + 1]
            } }
        }
        for index in 0..<frames {
            guard session.appendPacked422Frame(frame, stride: width * 4) else {
                throw NSError(domain: "ProfileMatrix", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Frame \(index): \(session.lastErrorMessage)"])
            }
        }
        guard session.finish() else {
            throw NSError(domain: "ProfileMatrix", code: 3,
                userInfo: [NSLocalizedDescriptionKey: session.lastErrorMessage])
        }
        let inputLabel = pqP3D65 ? "P3D65/PQ" : (pq2020 ? "Rec2020/PQ" : "Rec709/Gamma2.4")
        print("Profile \(profile), \(gamut), input \(inputLabel), \(frames) packed pictures: finished.")
    }
}
