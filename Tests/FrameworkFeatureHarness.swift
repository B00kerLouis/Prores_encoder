import Darwin
import Foundation
import ProResEncoderFramework

private struct Arguments {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    mutating func take() -> String {
        guard !values.isEmpty else {
            fputs("Missing required argument.\n", stderr)
            exit(2)
        }
        return values.removeFirst()
    }

    mutating func option(_ name: String) -> String? {
        guard let index = values.firstIndex(of: name) else {
            return nil
        }
        guard values.indices.contains(index + 1) else {
            fputs("Missing value for \(name).\n", stderr)
            exit(2)
        }
        let value = values[index + 1]
        values.removeSubrange(index...(index + 1))
        return value
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = values.firstIndex(of: name) else {
            return false
        }
        values.remove(at: index)
        return true
    }

    func requireEmpty() {
        guard values.isEmpty else {
            fputs("Unexpected arguments: \(values.joined(separator: " "))\n", stderr)
            exit(2)
        }
    }
}

private func outputFormat(_ raw: String) -> ProResOutputFormat {
    guard let format = ProResOutputFormat(rawValue: raw) else {
        fputs("Invalid output format: \(raw)\n", stderr)
        exit(2)
    }
    return format
}

private func aafMode(_ raw: String?) -> ProResAAFMode {
    switch raw {
    case nil, "none":
        return .none
    case "sequence":
        return .sequence
    case "per-clip":
        return .perClip
    default:
        fputs("Invalid AAF mode: \(raw ?? "")\n", stderr)
        exit(2)
    }
}

private func colorConversion(
    gamut: String?,
    oetf: String?,
    nits: String?
) -> ProResColorConversion? {
    guard gamut != nil || oetf != nil || nits != nil else {
        return nil
    }
    guard let gamut,
          let oetf,
          let nits,
          let parsedGamut = ProResColorGamut(rawValue: gamut),
          let parsedOETF = ProResTransferFunction(rawValue: oetf),
          let parsedNits = Float(nits) else {
        fputs("Color conversion requires valid --gamut, --oetf, and --nits values.\n", stderr)
        exit(2)
    }
    return ProResColorConversion(
        gamut: parsedGamut,
        transferFunction: parsedOETF,
        targetPeakNits: parsedNits
    )
}

private func encodeOptions(_ arguments: inout Arguments) -> ProResEncodeOptions {
    let quality = arguments.option("--quality") ?? "422hq"
    let bitrate = arguments.option("--bitrate").flatMap(Double.init)
    let profile = arguments.option("--profile").flatMap(ProResDolbyVisionProfile.init(rawValue:))
    let xml = arguments.option("--xml").map { URL(fileURLWithPath: $0) }
    let extraAudio = arguments.option("--extra-audio").map { URL(fileURLWithPath: $0) }
    let timecode = arguments.option("--timecode")
    let channelsPerFile = arguments.option("--audio-ch-per-file").flatMap(Int.init) ?? 1
    let masteringNits = arguments.option("--cmu").flatMap(Float.init)
    let gamut = arguments.option("--gamut")
    let oetf = arguments.option("--oetf")
    let nits = arguments.option("--nits")
    let mode = aafMode(arguments.option("--aaf"))
    let replaceAudio = arguments.flag("--replace-audio")
    let includeCMU = arguments.flag("--cmu-include")
    let dvFlag = arguments.flag("--dv-flag")
    return ProResEncodeOptions(
        quality: quality,
        extraAudioURL: extraAudio,
        replaceSourceAudio: replaceAudio,
        forcedOutputStartTimecode: timecode,
        dolbyVisionXMLURL: xml,
        bitrateMbps: bitrate,
        dolbyVisionProfile: profile,
        audioChannelsPerMXFFile: channelsPerFile,
        colorConversion: colorConversion(gamut: gamut, oetf: oetf, nits: nits),
        cmuMasteringNits: masteringNits,
        includeGeneratedDolbyVisionMetadata: includeCMU,
        useDolbyVisionCodecTag: dvFlag,
        aafMode: mode
    )
}

@main
struct FrameworkFeatureHarness {
    static func main() async {
        var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
        let command = arguments.take()
        let encoder = ProResEncoder()

        do {
            switch command {
            case "encode":
                let inputURL = URL(fileURLWithPath: arguments.take())
                let outputURL = URL(fileURLWithPath: arguments.take())
                let format = outputFormat(arguments.option("--format") ?? "mov")
                let options = encodeOptions(&arguments)
                arguments.requireEmpty()
                let result = try await encoder.encode(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    format: format,
                    options: options
                )
                print("[Framework Encode Success] \(result.outputURLs.map(\.path).joined(separator: ","))")
                if let xmlURL = result.cmuXMLURL {
                    print("[Framework CMU XML] \(xmlURL.path)")
                }
                if let aafURL = result.aafURL {
                    print("[Framework AAF] \(aafURL.path)")
                }

            case "folder":
                let inputURL = URL(fileURLWithPath: arguments.take())
                let outputURL = URL(fileURLWithPath: arguments.take())
                let format = outputFormat(arguments.option("--format") ?? "mov")
                let options = encodeOptions(&arguments)
                arguments.requireEmpty()
                let result = try await encoder.encodeFolder(
                    inputFolderURL: inputURL,
                    outputDirectoryURL: outputURL,
                    format: format,
                    options: options
                )
                print("[Framework Folder Success] \(result.clips.count) clip(s)")
                if let aafURL = result.sequenceAAFURL {
                    print("[Framework Sequence AAF] \(aafURL.path)")
                }

            case "timeline":
                let inputURL = URL(fileURLWithPath: arguments.take())
                let outputURL = URL(fileURLWithPath: arguments.take())
                let mediaSearchURL = arguments.option("--media-search").map {
                    [URL(fileURLWithPath: $0)]
                } ?? []
                let options = encodeOptions(&arguments)
                arguments.requireEmpty()
                let result = try await encoder.encodeTimeline(
                    inputTimelineURL: inputURL,
                    outputURL: outputURL,
                    mediaSearchURLs: mediaSearchURL,
                    options: options
                )
                print("[Framework Timeline Success] \(result.outputURLs.map(\.path).joined(separator: ","))")

            case "transform":
                let inputURL = URL(fileURLWithPath: arguments.take())
                let outputURL = URL(fileURLWithPath: arguments.take())
                let rawFormat = arguments.option("--to") ?? ""
                guard let format = ProResTimelineFormat(rawValue: rawFormat) else {
                    fputs("Transform requires --to aaf|xml.\n", stderr)
                    exit(2)
                }
                let mediaSearchURL = arguments.option("--media-search").map {
                    [URL(fileURLWithPath: $0)]
                } ?? []
                arguments.requireEmpty()
                let result = try encoder.transformTimeline(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    to: format,
                    mediaSearchURLs: mediaSearchURL
                )
                print("[Framework Transform Success] \(result.path)")

            default:
                fputs("Usage: FrameworkFeatureHarness encode|folder|timeline|transform ...\n", stderr)
                exit(2)
            }
        } catch {
            fputs("[Framework Failed] \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
