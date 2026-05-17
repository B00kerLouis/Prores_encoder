// cli.swift — CLI entry point & orchestration for ProRes Encoder
// Replaces main.swift: argument parsing, single/batch/XML dispatch,
// MXF → AAF generation, Metal pre-warm.

import Foundation
import AVFoundation
import Metal

// MARK: - CLI Config (Sendable, passed by value)

enum AAFMode: Sendable {
    case none       // no AAF
    case sequence   // -ea: one AAF with all clips
    case perClip    // -ea-all: one AAF per clip
}

enum TransformMode: Sendable {
    case outputAAF
    case outputXML

    init?(argument: String) {
        switch argument.lowercased() {
        case "aaf":
            self = .outputAAF
        case "xml":
            self = .outputXML
        default:
            return nil
        }
    }

    var cliValue: String {
        switch self {
        case .outputAAF: return "aaf"
        case .outputXML: return "xml"
        }
    }
}

struct CLIConfig: Sendable {
    let quality:        String
    let exportFormat:   String
    let audioCHperFile: Int
    let aafMode:        AAFMode
    let audioReplace:   Bool
    let dolbyVisionXMLURL: URL?
    let hevcOptions:    HEVCEncodeOptions?
}

// MARK: - Entry Point

@main
enum ProResEncoderCLI {
    static func main() async {
        // Pre-warm GPU services on the main thread before codec setup.
        _ = MTLCreateSystemDefaultDevice()

        // ── Parse CLI ──
        var inputFilePath   = ""
        var inputFolderPath = ""
        var inputXMLPath    = ""
        var inputAAFPath    = ""
        var outputPath      = ""
        var quality         = "422hq"
        var extraAudioPath  = ""
        var exportFormat    = "mov"
        var aafMode: AAFMode = .none
        var audioCHperFile  = 1
        var audioReplace    = false
        var dolbyVisionXMLPath = ""
        var hevcBitrateMbps: Double? = nil
        var hevcDVProfile: DolbyVisionHEVCProfile? = nil
        var transformMode: TransformMode? = nil
        var mediaSearchPaths: [String] = []

        let args = CommandLine.arguments
        var idx = 1
        func requireValue(for option: String) -> String {
            let valueIndex = idx + 1
            guard valueIndex < args.count else {
                print("[Error] Missing value for \(option).")
                printUsage()
                exit(1)
            }
            idx = valueIndex
            return args[idx]
        }

        while idx < args.count {
            switch args[idx] {
            case "-h", "--help":
                printUsage()
                exit(0)
            case "-i", "--input":
                inputFilePath = requireValue(for: args[idx])
            case "-if", "--input-folder":
                inputFolderPath = requireValue(for: args[idx])
            case "--input-xml", "-ix", "-xml":
                inputXMLPath = requireValue(for: args[idx])
            case "--input-aaf", "-ia", "-aaf":
                inputAAFPath = requireValue(for: args[idx])
            case "-o", "--output":
                outputPath = requireValue(for: args[idx])
            case "-q", "-quality", "--quality":
                quality = normalizedProResQuality(requireValue(for: args[idx]))
            case "-aa", "--add-audio":
                extraAudioPath = requireValue(for: args[idx])
            case "-ar", "--audio-replace":
                audioReplace = true
            case "-dovi", "--dolby-vision-xml":
                dolbyVisionXMLPath = requireValue(for: args[idx])
            case "-b", "--bitrate":
                let raw = requireValue(for: args[idx])
                guard let parsed = Double(raw), parsed > 0 else {
                    print("[Error] --bitrate / -b must be a positive number in Mb/s.")
                    exit(1)
                }
                hevcBitrateMbps = parsed
            case "-dp", "--dv-profile":
                let raw = requireValue(for: args[idx])
                guard let parsed = DolbyVisionHEVCProfile(argument: raw) else {
                    print("[Error] --dv-profile / -dp currently supports only 81 for Dolby Vision Profile 8.1.")
                    exit(1)
                }
                hevcDVProfile = parsed
            case "-ef", "-export-format", "--export-format":
                exportFormat = requireValue(for: args[idx]).lowercased()
            case "-ea", "-export-aaf", "--export-aaf", "--aaf":
                aafMode = .sequence
            case "-ea-all", "-export-aaf-all", "--export-aaf-all":
                aafMode = .perClip
            case "--audio-ch-per-file":
                let raw = requireValue(for: args[idx])
                guard let parsed = Int(raw), parsed > 0 else {
                    print("[Error] --audio-ch-per-file must be a positive integer.")
                    exit(1)
                }
                audioCHperFile = parsed
            case "-trans", "--transform":
                let raw = requireValue(for: args[idx])
                if let mode = TransformMode(argument: raw) {
                    transformMode = mode
                } else {
                    print("[Error] Invalid -trans mode. Use AAF or XML.")
                    printUsage()
                    exit(1)
                }
            case "--media-search-path":
                mediaSearchPaths.append(requireValue(for: args[idx]))
            default:
                print("[Error] Unknown argument: \(args[idx])")
                printUsage()
                exit(1)
            }
            idx += 1
        }

        let validExportFormats: Set<String> = ["mov", "op1a", "opatom"]
        guard validExportFormats.contains(exportFormat) else {
            print("[Error] Invalid export format: \(exportFormat). Use mov, op1a, or opatom.")
            printUsage()
            exit(1)
        }

        guard audioCHperFile > 0 else {
            print("[Error] --audio-ch-per-file must be a positive integer.")
            exit(1)
        }

        if let transformMode {
            guard !inputFilePath.isEmpty,
                  inputFolderPath.isEmpty,
                  inputXMLPath.isEmpty,
                  inputAAFPath.isEmpty,
                  !outputPath.isEmpty else {
                print("[Error] -trans requires exactly one -i <file> input and an -o <output> path.")
                printUsage()
                exit(1)
            }
            if !extraAudioPath.isEmpty || audioReplace {
                print("[Error] -aa and --audio-replace are not supported with -trans.")
                exit(1)
            }
            let inputURL = URL(fileURLWithPath: inputFilePath)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print("[Error] Transform input file not found: \(inputFilePath)")
                exit(1)
            }
            let ok = runSwiftTimelineTransform(inputURL: inputURL,
                                               outputPath: outputPath,
                                               mode: transformMode,
                                               mediaSearchPaths: mediaSearchPaths)
            exit(ok ? 0 : 1)
        }

        // ── Validate ──
        let inputModes = [!inputFilePath.isEmpty, !inputFolderPath.isEmpty, !inputXMLPath.isEmpty, !inputAAFPath.isEmpty]
        if inputModes.filter({ $0 }).count != 1 || outputPath.isEmpty {
            printUsage(); exit(1)
        }
        if !inputFolderPath.isEmpty && !extraAudioPath.isEmpty {
            print("[Error] -aa is not supported with folder input (-if)."); exit(1)
        }
        if (!inputXMLPath.isEmpty || !inputAAFPath.isEmpty) && !extraAudioPath.isEmpty {
            print("[Error] -aa is not supported with XML/AAF timeline inputs."); exit(1)
        }
        if audioReplace && extraAudioPath.isEmpty {
            print("[Error] --audio-replace / -ar requires -aa <audio_file>.")
            exit(1)
        }
        if !extraAudioPath.isEmpty && !audioReplace && (exportFormat == "op1a" || exportFormat == "opatom") {
            print("[Error] MXF output supports -aa only with --audio-replace / -ar.")
            exit(1)
        }
        if let qualityError = proResQualityValidationError(quality) {
            print("[Error] \(qualityError)")
            printUsage()
            exit(1)
        }
        let wantsHEVC = isHEVCQuality(quality)
        if wantsHEVC {
            guard exportFormat == "mov" else {
                print("[Error] -q hevc is supported only with MOV output.")
                exit(1)
            }
            guard inputXMLPath.isEmpty && inputAAFPath.isEmpty else {
                print("[Error] -q hevc currently supports single-file or folder media input, not timeline XML/AAF bounce.")
                exit(1)
            }
            guard let bitrate = hevcBitrateMbps, bitrate > 0 else {
                print("[Error] -q hevc requires --bitrate / -b <Mb/s>.")
                exit(1)
            }
            if hevcDVProfile != nil && dolbyVisionXMLPath.isEmpty {
                print("[Error] --dv-profile / -dp requires -dovi / --dolby-vision-xml.")
                exit(1)
            }
            if !dolbyVisionXMLPath.isEmpty && hevcDVProfile == nil {
                print("[Error] -q hevc with -dovi requires --dv-profile 81 / -dp 81.")
                exit(1)
            }
        } else {
            if hevcBitrateMbps != nil {
                print("[Error] --bitrate / -b is available only with -q hevc.")
                exit(1)
            }
            if hevcDVProfile != nil {
                print("[Error] --dv-profile / -dp is available only with -q hevc.")
                exit(1)
            }
        }
        if exportFormat == "mov" && aafMode != .none {
            print("[Error] AAF (-ea / -ea-all) is only available with MXF output formats (op1a / opatom)."); exit(1)
        }
        if !dolbyVisionXMLPath.isEmpty {
            guard exportFormat == "mov" else {
                print("[Error] Dolby Vision export is currently supported only with MOV output; MXF (OP-1A/OP-Atom) is not supported.")
                exit(1)
            }
            guard !inputFilePath.isEmpty else {
                print("[Error] --dolby-vision-xml currently requires single-file input (-i).")
                exit(1)
            }
        }

        let dolbyVisionXMLURL: URL?
        if !dolbyVisionXMLPath.isEmpty {
            let u = URL(fileURLWithPath: dolbyVisionXMLPath)
            guard FileManager.default.fileExists(atPath: u.path) else {
                print("[Error] Dolby Vision XML file not found: \(dolbyVisionXMLPath)")
                exit(1)
            }
            dolbyVisionXMLURL = u
        } else {
            dolbyVisionXMLURL = nil
        }

        let hevcOptions = wantsHEVC ? HEVCEncodeOptions(
            bitrateMbps: hevcBitrateMbps ?? 0,
            dvProfile: hevcDVProfile
        ) : nil

        let config = CLIConfig(quality: quality, exportFormat: exportFormat,
                               audioCHperFile: audioCHperFile, aafMode: aafMode,
                               audioReplace: audioReplace,
                               dolbyVisionXMLURL: dolbyVisionXMLURL,
                               hevcOptions: hevcOptions)
        let fm = FileManager.default
        let outputURL = URL(fileURLWithPath: outputPath)
        let isOutFile = !outputURL.pathExtension.isEmpty
        let validExts: Set<String> = ["mp4", "mov", "m4v", "mxf", "avi", "mkv"]

        var extraAudioURL: URL? = nil
        if !extraAudioPath.isEmpty {
            let u = URL(fileURLWithPath: extraAudioPath)
            guard fm.fileExists(atPath: u.path) else {
                print("[Error] Extra audio file not found: \(extraAudioPath)"); exit(1)
            }
            extraAudioURL = u
        }

        // ── XML Timeline Mode ──
        if !inputXMLPath.isEmpty {
            let xmlURL = URL(fileURLWithPath: inputXMLPath)
            guard fm.fileExists(atPath: xmlURL.path) else {
                print("[Error] XML file not found: \(inputXMLPath)"); exit(1)
            }
            print("[XML] Parsing timeline: \(xmlURL.lastPathComponent)")
            let parser = XMLTimelineParser()
            guard let desc = parser.parse(url: xmlURL) else {
                print("[Error] Failed to parse XML timeline."); exit(1)
            }
            print("[XML] Sequence '\(desc.name)' parsed: \(desc.clips.count) clips")
            let builder = CompositionBuilder()
            guard let comp = try? builder.build(from: desc) else {
                print("[Error] Failed to build AVMutableComposition."); exit(1)
            }
            let outName = desc.name.isEmpty ? xmlURL.deletingPathExtension().lastPathComponent : desc.name
            let finalOut = resolvedTimelineOutputURL(baseOutputURL: outputURL, fallbackName: outName)
            let ok = await processTimelineComposition(composition: comp, descriptor: desc, outputURL: finalOut,
                                                       assetName: outName, config: config)
            exit(ok ? 0 : 1)
        }

        // ── AAF Timeline Mode ──
        if !inputAAFPath.isEmpty {
            let aafURL = URL(fileURLWithPath: inputAAFPath)
            guard fm.fileExists(atPath: aafURL.path) else {
                print("[Error] AAF file not found: \(inputAAFPath)"); exit(1)
            }
            guard config.exportFormat == "mov" else {
                print("[Error] -x currently supports MOV bounce output only."); exit(1)
            }

            print("[AAF] Parsing timeline: \(aafURL.lastPathComponent)")
            let searchPaths = uniqueSearchPaths(for: aafURL, explicitPaths: mediaSearchPaths)
            let parser = AAFTimelineParser()
            guard let desc = parser.parse(
                url: aafURL,
                mediaSearchPaths: searchPaths.map { URL(fileURLWithPath: $0) }
            ) else {
                print("[Error] Failed to parse AAF timeline."); exit(1)
            }
            print("[AAF] Sequence '\(desc.name)' parsed: \(desc.clips.count) clips")
            let builder = CompositionBuilder()
            guard let comp = try? builder.build(from: desc) else {
                print("[Error] Failed to build AVMutableComposition from AAF."); exit(1)
            }

            let outName = desc.name.isEmpty ? aafURL.deletingPathExtension().lastPathComponent : desc.name
            let finalOut = resolvedTimelineOutputURL(baseOutputURL: outputURL, fallbackName: outName)
            let ok = await processTimelineComposition(composition: comp, descriptor: desc, outputURL: finalOut,
                                                       assetName: outName, config: config)
            exit(ok ? 0 : 1)
        }

        // ── Single File Mode ──
        if !inputFilePath.isEmpty {
            let inputURL = URL(fileURLWithPath: inputFilePath)
            guard fm.fileExists(atPath: inputURL.path) else {
                print("[Error] Input file not found: \(inputFilePath)"); exit(1)
            }
            guard validExts.contains(inputURL.pathExtension.lowercased()) else {
                print("[Error] Unsupported format: .\(inputURL.pathExtension)."); exit(1)
            }
            let asset = AVURLAsset(url: inputURL)
            let baseName = inputURL.deletingPathExtension().lastPathComponent
            if isOutFile {
                let finalOut = outputURL.deletingPathExtension().appendingPathExtension("mov")
                _ = await processSingleVideo(inputAsset: asset, outputURL: finalOut,
                                             extraAudioURL: extraAudioURL, assetName: baseName,
                                             config: config)
            } else {
                try? fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
                let finalOut = outputURL.appendingPathComponent("\(baseName).mov")
                _ = await processSingleVideo(inputAsset: asset, outputURL: finalOut,
                                             extraAudioURL: extraAudioURL, assetName: baseName,
                                             config: config)
            }
            exit(0)
        }

        // ── Folder Batch Mode ──
        if !inputFolderPath.isEmpty {
            let folderURL = URL(fileURLWithPath: inputFolderPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
                print("[Error] Input folder not found: \(inputFolderPath)"); exit(1)
            }
            guard !isOutFile else {
                print("[Error] Cannot batch-encode multiple files to a single output file."); exit(1)
            }
            try? fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
            let videos = files.filter { validExts.contains($0.pathExtension.lowercased()) }
            guard !videos.isEmpty else { print("[Info] No supported video files found."); exit(0) }
            var sequencedAAFClips: [AAFClipInfo] = []
            for file in videos {
                let baseName = file.deletingPathExtension().lastPathComponent
                let finalOut = outputURL.appendingPathComponent("\(baseName).mov")
                let asset    = AVURLAsset(url: file)
                if let clip = await processSingleVideo(inputAsset: asset, outputURL: finalOut,
                                                       extraAudioURL: nil, assetName: baseName,
                                                       config: config,
                                                       deferSequenceAAF: config.aafMode == .sequence) {
                    sequencedAAFClips.append(clip)
                }
            }
            if config.aafMode == .sequence, !sequencedAAFClips.isEmpty {
                let sequenceName = folderURL.lastPathComponent.isEmpty ? "ProRes Sequence" : folderURL.lastPathComponent
                let aafPath = outputURL.appendingPathComponent(sequenceName + ".aaf").path
                print("[AAF] Generating sequence AAF...")
                if !generateAAFWithSwiftAAF(clips: sequencedAAFClips, outputPath: aafPath, sequenceName: sequenceName) {
                    print("[Failed] AAF generation failed.")
                }
            }
            exit(0)
        }
    }
}

// MARK: - Single Video Processor

private func processSingleVideo(
    inputAsset:    AVAsset,
    outputURL:     URL,
    extraAudioURL: URL?,
    assetName:     String,
    config:        CLIConfig,
    deferSequenceAAF: Bool = false
) async -> AAFClipInfo? {
    let fm = FileManager.default
    print("\n[Processing]: \(assetName)")

    let isMXF  = (config.exportFormat == "op1a" || config.exportFormat == "opatom")
    let status: String
    if config.quality == "pass" {
        status = "-> Lossless remux (pass-through)"
    } else if isHEVCQuality(config.quality), let hevcOptions = config.hevcOptions {
        let dvSuffix = hevcOptions.dvProfile.map { " + Dolby Vision Profile \($0.displayName)" } ?? ""
        status = "-> Encoding HDR10 HEVC \(String(format: "%.2f", hevcOptions.bitrateMbps)) Mb/s\(dvSuffix)"
    } else {
        status = "-> Encoding ProRes \(config.quality.uppercased())"
    }
    let audioStatus: String
    if extraAudioURL != nil {
        audioStatus = config.audioReplace ? " [replacing source audio]" : " [+ injecting extra audio]"
    } else {
        audioStatus = ""
    }
    print(status + audioStatus + "...")

    let outputDir = outputURL.deletingLastPathComponent()
    try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

    // ── MXF path ──
    if isMXF {
        let basename = outputURL.deletingPathExtension().lastPathComponent
        guard let urlAsset = inputAsset as? AVURLAsset else {
            print("[Failed] MXF encode requires a file-based asset."); return nil
        }

        let stale = outputDir.appendingPathComponent(basename + ".mxf")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: stale.path, isDirectory: &isDir), isDir.boolValue {
            try? fm.removeItem(at: stale)
        }

        print("[MXF] Encoding source directly to MXF...")

        let result = await encodeMXF(
            asset: inputAsset,
            sourceURL: urlAsset.url,
            outputDir: outputDir.path,
            basename: basename,
            quality: config.quality,
            exportFormat: config.exportFormat,
            audioCHperFile: config.audioCHperFile,
            audioOverrideURL: config.audioReplace ? extraAudioURL : nil)

        if result.success {
            print("[MXF] Encoded \(result.framesEncoded) frames at " +
                  "\(String(format: "%.1f", result.fps)) fps")
            print("[Success] MXF written for '\(assetName)'.")

            if config.aafMode != .none && !result.paths.isEmpty {
                let fpsI = await framerateInfo(from: inputAsset)
                let tc   = await readTimecodeString(from: inputAsset)
                let (w, h) = await videoSize(from: inputAsset)
                let isOPAtom = (config.exportFormat == "opatom")

                // Separate video and audio MXF paths
                let videoMXF: String
                let audioMXFs: [String]
                let audioTrackCount: Int
                let audioChannelCounts: [Int]
                if isOPAtom {
                    videoMXF  = result.paths.first { $0.hasSuffix("_v.mxf") } ?? result.paths[0]
                    audioMXFs = result.paths.filter { $0.hasSuffix(".mxf") && !$0.hasSuffix("_v.mxf") }.sorted()
                    audioTrackCount = audioMXFs.count
                    audioChannelCounts = audioChannelCountsForOPAtom(
                        sourceChannels: result.sourceAudioChannels,
                        channelsPerFile: config.audioCHperFile,
                        fileCount: audioTrackCount)
                } else {
                    videoMXF  = result.paths[0]
                    audioMXFs = []  // OP-1a: audio is inside the video MXF
                    let ch = result.sourceAudioChannels
                    audioTrackCount = ch > 0 ? 1 : 0
                    audioChannelCounts = ch > 0 ? [ch] : []
                }

                // Compute total audio samples: (frames * sampleRate * fpsDen + fpsNum/2) / fpsNum
                let totalAudioSamples: Int64 = {
                    let sr = Int64(48000)
                    let frames = result.framesEncoded
                    let num = Int64(fpsI.numerator)
                    let den = Int64(fpsI.denominator)
                    return (frames * sr * den + num / 2) / num
                }()

                let clip = AAFClipInfo(
                    videoMXFPath: videoMXF, audioMXFPaths: audioMXFs,
                    width: w, height: h,
                    duration: result.framesEncoded,
                    fpsNumerator: Int32(fpsI.numerator),
                    fpsDenominator: Int32(fpsI.denominator),
                    isDropFrame: fpsI.isDropFrame,
                    timecode: tc,
                    audioBits: 24, audioSampleRate: 48000,
                    audioChannels: audioChannelCounts.first ?? config.audioCHperFile,
                    audioChannelCounts: audioChannelCounts,
                    audioTrackCount: audioTrackCount,
                    isOPAtom: isOPAtom,
                    codecVariant: config.quality,
                    videoMXFUMID: result.videoMXFUMID,
                    audioMXFUMIDs: result.audioMXFUMIDs,
                    totalAudioSamples: totalAudioSamples)

                if deferSequenceAAF {
                    return clip
                }

                print("[AAF] Generating AAF...")
                let aafPath = outputDir.appendingPathComponent(basename + ".aaf").path
                let ok = generateAAFWithSwiftAAF(clips: [clip], outputPath: aafPath, sequenceName: basename)
                if !ok { print("[Failed] AAF generation failed.") }
                return clip
            }
        } else {
            print("[Failed] MXF encode failed: \(result.error ?? "unknown")")
        }

        return nil
    }

    let cs: SourceColorSpace?
    if config.quality != "pass",
       let vt = try? await inputAsset.loadTracks(withMediaType: .video).first {
        cs = await detectColorSpace(from: vt)
    } else { cs = nil }
    let fpsI = await framerateInfo(from: inputAsset)

    let success = await encodeMOV(
        asset: inputAsset, outputURL: outputURL,
        quality: config.quality, extraAudioURL: extraAudioURL,
        audioReplace: config.audioReplace,
        dolbyVisionXMLURL: config.dolbyVisionXMLURL,
        hevcOptions: config.hevcOptions,
        colorSpace: cs, fpsInfo: fpsI)

    guard success else {
        print("[Failed] \(assetName)")
        try? fm.removeItem(at: outputURL)
        return nil
    }
    print("[Success] -> \(outputURL.path)")
    return nil
}

// MARK: - Helpers

private func uniqueSearchPaths(for inputURL: URL, explicitPaths: [String]) -> [String] {
    let candidates = explicitPaths + [inputURL.deletingLastPathComponent().path]
    var seen = Set<String>()
    var result: [String] = []
    for raw in candidates {
        let path = URL(fileURLWithPath: raw).standardizedFileURL.path
        if seen.insert(path).inserted {
            result.append(path)
        }
    }
    return result
}

private func timelineDescriptor(
    from inputURL: URL,
    mediaSearchPaths: [String]
) -> TimelineDescriptor? {
    let ext = inputURL.pathExtension.lowercased()
    switch ext {
    case "aaf":
        let paths = uniqueSearchPaths(for: inputURL, explicitPaths: mediaSearchPaths)
        return AAFTimelineParser().parse(
            url: inputURL,
            mediaSearchPaths: paths.map { URL(fileURLWithPath: $0) }
        )
    case "xml", "fcpxml":
        return XMLTimelineParser().parse(url: inputURL)
    default:
        print("[Transform] Unsupported timeline input: .\(ext)")
        return nil
    }
}

private func runSwiftTimelineTransform(
    inputURL: URL,
    outputPath: String,
    mode: TransformMode,
    mediaSearchPaths: [String]
) -> Bool {
    guard let descriptor = timelineDescriptor(from: inputURL, mediaSearchPaths: mediaSearchPaths) else {
        print("[Transform] Failed to parse input timeline.")
        return false
    }

    let requestedURL = URL(fileURLWithPath: outputPath)
    let outputURL: URL
    switch mode {
    case .outputAAF:
        outputURL = requestedURL.pathExtension.isEmpty
            ? requestedURL.appendingPathExtension("aaf")
            : requestedURL
        return generateLinkedAAFWithSwiftAAF(
            descriptor: descriptor,
            outputPath: outputURL.path,
            sequenceName: descriptor.name
        )
    case .outputXML:
        outputURL = requestedURL.pathExtension.isEmpty
            ? requestedURL.appendingPathExtension("xml")
            : requestedURL
        let ok = FCP7XMLTimelineWriter().write(descriptor, to: outputURL)
        if ok {
            print("[XML] Wrote \(outputURL.path)")
        }
        return ok
    }
}

private func resolvedTimelineOutputURL(baseOutputURL: URL, fallbackName: String) -> URL {
    if !baseOutputURL.pathExtension.isEmpty {
        return baseOutputURL.deletingPathExtension().appendingPathExtension("mov")
    }
    return baseOutputURL.appendingPathComponent("\(fallbackName).mov")
}

private func audioChannelCountsForOPAtom(sourceChannels: Int, channelsPerFile: Int, fileCount: Int) -> [Int] {
    guard fileCount > 0 else {
        return []
    }
    let safeChannelsPerFile = max(channelsPerFile, 1)
    guard sourceChannels > 0 else {
        return Array(repeating: safeChannelsPerFile, count: fileCount)
    }
    return (0..<fileCount).map { index in
        let consumed = index * safeChannelsPerFile
        return max(1, min(safeChannelsPerFile, sourceChannels - consumed))
    }
}

private func timelineExportPresetCandidates(for quality: String) -> [String] {
    switch normalizedProResQuality(quality) {
    case "4444", "4444xq":
        return [AVAssetExportPresetAppleProRes4444LPCM,
                AVAssetExportPresetAppleProRes422LPCM,
                AVAssetExportPresetHighestQuality]
    default:
        return [AVAssetExportPresetAppleProRes422LPCM,
                AVAssetExportPresetHighestQuality]
    }
}

func compositionVideoTrackIndex(_ track: AVCompositionTrack) -> Int {
    let rawValue = Int(track.trackID)
    if rawValue >= 1001 {
        return rawValue - 1001
    }
    return rawValue
}

func compositionTrackIsActive(_ track: AVCompositionTrack, over timeRange: CMTimeRange) -> Bool {
    for segment in track.segments where !segment.isEmpty {
        let target = segment.timeMapping.target
        let intersection = CMTimeRangeGetIntersection(target, otherRange: timeRange)
        if intersection.duration > .zero {
            return true
        }
    }
    return false
}

func buildTimelineVideoComposition(
    composition: AVMutableComposition,
    descriptor: TimelineDescriptor
) -> AVMutableVideoComposition {
    let videoTracks = composition.tracks(withMediaType: .video)
    let videoComposition = AVMutableVideoComposition()
    videoComposition.frameDuration = descriptor.frameRate.value > 0 && descriptor.frameRate.timescale > 0
        ? descriptor.frameRate
        : CMTime(value: 1, timescale: 24)
    videoComposition.renderSize = descriptor.resolution.width > 0 && descriptor.resolution.height > 0
        ? descriptor.resolution
        : CGSize(width: 1920, height: 1080)

    guard !videoTracks.isEmpty else {
        videoComposition.instructions = []
        return videoComposition
    }

    var boundaries: [CMTime] = [.zero]
    for track in videoTracks {
        for segment in track.segments where !segment.isEmpty {
            boundaries.append(segment.timeMapping.target.start)
            boundaries.append(segment.timeMapping.target.end)
        }
    }

    let sortedBoundaries = boundaries.sorted { lhs, rhs in
        CMTimeCompare(lhs, rhs) < 0
    }.reduce(into: [CMTime]()) { partial, time in
        if let last = partial.last, CMTimeCompare(last, time) == 0 {
            return
        }
        partial.append(time)
    }

    var instructions: [AVVideoCompositionInstructionProtocol] = []
    if sortedBoundaries.count >= 2 {
        for idx in 0..<(sortedBoundaries.count - 1) {
            let start = sortedBoundaries[idx]
            let end = sortedBoundaries[idx + 1]
            guard CMTimeCompare(end, start) > 0 else { continue }

            let timeRange = CMTimeRange(start: start, end: end)
            let activeTracks = videoTracks
                .filter { compositionTrackIsActive($0, over: timeRange) }
                .sorted { lhs, rhs in
                    compositionVideoTrackIndex(lhs) > compositionVideoTrackIndex(rhs)
                }

            guard !activeTracks.isEmpty else { continue }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = timeRange
            instruction.enablePostProcessing = true
            instruction.layerInstructions = activeTracks.map { track in
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(track.preferredTransform, at: start)
                return layer
            }
            instructions.append(instruction)
        }
    }

    if instructions.isEmpty {
        let fallbackInstruction = AVMutableVideoCompositionInstruction()
        fallbackInstruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let activeTracks = videoTracks.sorted { lhs, rhs in
            compositionVideoTrackIndex(lhs) > compositionVideoTrackIndex(rhs)
        }
        fallbackInstruction.layerInstructions = activeTracks.map { track in
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(track.preferredTransform, at: .zero)
            return layer
        }
        instructions = [fallbackInstruction]
    }

    videoComposition.instructions = instructions
    return videoComposition
}

private func exportTimelineComposition(
    composition: AVMutableComposition,
    descriptor: TimelineDescriptor,
    outputURL: URL,
    quality: String
) async -> Bool {
    let requestedQuality = normalizedProResQuality(quality)
    if requestedQuality == "pass" {
        print("[Timeline] pass-through is not possible for rendered timelines; falling back to ProRes bounce.")
    }

    let supportedPresets = Set(AVAssetExportSession.exportPresets(compatibleWith: composition))
    guard let preset = timelineExportPresetCandidates(for: requestedQuality)
        .first(where: { supportedPresets.contains($0) }),
          let session = AVAssetExportSession(asset: composition, presetName: preset) else {
        print("[Timeline] No compatible export preset found for rendered timeline.")
        return false
    }

    let fm = FileManager.default
    try? fm.removeItem(at: outputURL)

    let videoComposition = buildTimelineVideoComposition(
        composition: composition,
        descriptor: descriptor)
    if !composition.tracks(withMediaType: .audio).isEmpty {
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = composition.tracks(withMediaType: .audio).map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(1.0, at: .zero)
            return params
        }
        session.audioMix = audioMix
    }

    session.outputURL = outputURL
    session.outputFileType = .mov
    session.shouldOptimizeForNetworkUse = false
    session.videoComposition = videoComposition

    print("[Timeline] Using export preset: \(preset)")
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        session.exportAsynchronously {
            cont.resume()
        }
    }

    if session.status == .completed {
        return true
    }

    if let error = session.error {
        print("[Timeline] Export failed: \(error.localizedDescription)")
    } else {
        print("[Timeline] Export failed with status: \(session.status.rawValue)")
    }
    return false
}

private func processTimelineComposition(
    composition: AVMutableComposition,
    descriptor: TimelineDescriptor,
    outputURL: URL,
    assetName: String,
    config: CLIConfig
) async -> Bool {
    let fm = FileManager.default
    print("\n[Timeline Bounce]: \(assetName)")

    guard config.exportFormat == "mov" else {
        print("[Failed] Timeline bounce currently supports MOV output only.")
        return false
    }

    let outputDir = outputURL.deletingLastPathComponent()
    try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let success = await encodeTimelineMOV(
        composition: composition,
        descriptor: descriptor,
        outputURL: outputURL,
        quality: config.quality)

    guard success else {
        try? fm.removeItem(at: outputURL)
        print("[Failed] \(assetName)")
        return false
    }
    print("[Success] -> \(outputURL.path)")
    return true
}

private func printUsage() {
    print("""
    Usage:
      prores_encoder <input-mode> -o <output> [options]

    Input modes (choose exactly one):
      -i <file>           Single media file
      -if <folder>        Batch folder
      -xml <file>         XML timeline
      -aaf <file>           AAF timeline, parsed natively then bounced to MOV

    Transform mode:
      -trans AAF|XML                 Convert timeline with native Swift parser/writers
      --media-search-path <path>     Extra relink path for linked AAF media

    Output format:
      -ef, --export-format <format>   Export format (default: mov)
        mov             MOV container
        op1a            MXF OP-1a (direct VT→MXF)
        opatom          MXF OP-Atom (direct VT→MXF)

    Options:
      -q, --quality <proxy|422lt|422|422hq|4444|4444xq|pass|hevc>  Output codec/quality (default: 422hq)
      -b, --bitrate <Mb/s>           HEVC bitrate in Mb/s (required with -q hevc)
      -dp, --dv-profile <81>         Dolby Vision HEVC profile; currently only 81 / Profile 8.1
      -aa, --add-audio <audio_file>   Add external audio in MOV mode, or provide replacement audio
      -ar, --audio-replace            Replace source audio with the -aa audio file
      -dovi, --dolby-vision-xml <file> MOV only; embed ProRes PHDR metadata, or generate HEVC RPU with -q hevc -dp 81
      --audio-ch-per-file <N>         Channels per OP-Atom audio MXF (default: 1)
      -ea, --export-aaf               Generate one AAF for all clips (MXF modes only)
      -ea-all, --export-aaf-all       Generate one AAF per clip (MXF modes only)
    """)
}
