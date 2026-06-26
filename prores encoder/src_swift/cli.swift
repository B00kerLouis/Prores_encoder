// cli.swift — CLI entry point & orchestration for ProRes Encoder
// Replaces main.swift: argument parsing, single/batch/XML dispatch,
// MXF → AAF generation, Metal pre-warm.

import Foundation
import AVFoundation
import Metal

#if PRORES_ENCODER_CLI

private let proResEncoderCLIVersion = "1.2.0"

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
    let deleteSourceAudio: Bool
    let forcedOutputStartTimecode: String?
    let dolbyVisionXMLURL: URL?
    let hevcOptions:    HEVCEncodeOptions?
    let av1Options:     AV1EncodeOptions?
    let colorTransform: ColorTransformRequest?
    let cmuMasteringNits: Float?
    let cmuInclude:     Bool
    let dvFlag:         Bool
    let dolbyVisionDualOutput: Bool
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
        var deleteSourceAudio = false
        var forcedOutputStartTimecode: String? = nil
        var dolbyVisionXMLPath = ""
        var videoBitrateMbps: Double? = nil
        var dolbyVisionProfile: DolbyVisionHEVCProfile? = nil
        var transformMode: TransformMode? = nil
        var mediaSearchPaths: [String] = []
        var targetGamut: String? = nil
        var targetOETF: String? = nil
        var targetNits: String? = nil
        var cmuMasteringNits: Float? = nil
        var cmuInclude = false
        var dvFlag = false
        var dolbyVisionDualOutput = false

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
            case "-v", "--version":
                print("prores encoder \(proResEncoderCLIVersion)")
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
            case "-dsa", "--delete-source-audio":
                deleteSourceAudio = true
            case "-ffoa", "--start-timecode", "--mov-start-timecode":
                forcedOutputStartTimecode = requireValue(for: args[idx])
            case "-dovi", "--dolby-vision-xml":
                dolbyVisionXMLPath = requireValue(for: args[idx])
            case "-b", "--bitrate":
                let raw = requireValue(for: args[idx])
                guard let parsed = Double(raw), parsed > 0 else {
                    print("[Error] --bitrate / -b must be a positive number in Mb/s.")
                    exit(1)
                }
                videoBitrateMbps = parsed
            case "-dp", "--dv-profile":
                let raw = requireValue(for: args[idx])
                guard let parsed = DolbyVisionHEVCProfile(argument: raw) else {
                    print("[Error] --dv-profile / -dp supports HEVC 76/81/84 and AV1 10/104.")
                    exit(1)
                }
                dolbyVisionProfile = parsed
            case "-ef", "--export-format":
                exportFormat = requireValue(for: args[idx]).lowercased()
            case "-ea", "--export-aaf", "--aaf":
                aafMode = .sequence
            case "-ea-all", "--export-aaf-all":
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
            case "--gamunt":
                targetGamut = requireValue(for: args[idx])
            case "--oetf":
                targetOETF = requireValue(for: args[idx])
            case "--nit":
                targetNits = requireValue(for: args[idx])
            case "--cmu":
                let raw = requireValue(for: args[idx])
                do {
                    cmuMasteringNits = try cmuParseMasteringBrightness(raw)
                } catch {
                    print("[Error] \(error.localizedDescription)")
                    exit(1)
                }
            case "--cmu-include", "-ci":
                cmuInclude = true
            case "--dv-flag", "-df":
                dvFlag = true
            case "--dual":
                dolbyVisionDualOutput = true
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
        if cmuMasteringNits != nil && !dolbyVisionXMLPath.isEmpty {
            print("[Error] --cmu and -dovi / --dolby-vision-xml are mutually exclusive.")
            exit(1)
        }
        if cmuInclude && cmuMasteringNits == nil {
            print("[Error] --cmu-include requires --cmu <nits>.")
            exit(1)
        }
        if cmuInclude && exportFormat != "mov" {
            print("[Error] --cmu-include is supported only with MOV output.")
            exit(1)
        }

        let colorArgumentCount = [targetGamut, targetOETF, targetNits]
            .compactMap { $0 }
            .count
        if colorArgumentCount != 0 && colorArgumentCount != 3 {
            print("[Error] \(ColorTransformError.incompleteArguments.localizedDescription)")
            exit(1)
        }
        let colorTransform: ColorTransformRequest?
        do {
            if let targetGamut, let targetOETF, let targetNits {
                colorTransform = try ColorTransformRequest(
                    gamut: targetGamut,
                    oetf: targetOETF,
                    nits: targetNits
                )
            } else {
                colorTransform = nil
            }
        } catch {
            print("[Error] \(error.localizedDescription)")
            exit(1)
        }

        if let transformMode {
            if colorTransform != nil {
                print("[Error] Color conversion parameters are valid only for encoding, not -trans timeline conversion.")
                exit(1)
            }
            if cmuMasteringNits != nil {
                print("[Error] --cmu is available only while encoding media, not with -trans timeline conversion.")
                exit(1)
            }
            if dvFlag {
                print("[Error] --dv-flag / -df is available only while encoding HEVC or AV1 media.")
                exit(1)
            }
            if dolbyVisionDualOutput {
                print("[Error] --dual is available only while encoding HEVC Profile 7.6.")
                exit(1)
            }
            guard !inputFilePath.isEmpty,
                  inputFolderPath.isEmpty,
                  inputXMLPath.isEmpty,
                  inputAAFPath.isEmpty,
                  !outputPath.isEmpty else {
                print("[Error] -trans requires exactly one -i <file> input and an -o <output> path.")
                printUsage()
                exit(1)
            }
            if !extraAudioPath.isEmpty || audioReplace || deleteSourceAudio {
                print("[Error] -aa, --audio-replace, and --delete-source-audio are not supported with -trans.")
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
        if !extraAudioPath.isEmpty
            && !audioReplace
            && !deleteSourceAudio
            && (exportFormat == "op1a" || exportFormat == "opatom") {
            print("[Error] MXF output supports -aa only with --audio-replace / -ar or --delete-source-audio / -dsa.")
            exit(1)
        }
        if let qualityError = proResQualityValidationError(quality) {
            print("[Error] \(qualityError)")
            printUsage()
            exit(1)
        }
        if colorTransform != nil && quality == "pass" {
            print("[Error] \(ColorTransformError.passthroughNotSupported.localizedDescription)")
            exit(1)
        }
        if colorTransform != nil
            && !dolbyVisionXMLPath.isEmpty
            && dolbyVisionProfile?.usesHLGBaseLayer != true {
            print("[Error] \(ColorTransformError.dolbyVisionNotSupported.localizedDescription)")
            exit(1)
        }
        let wantsHEVC = isHEVCQuality(quality)
        let wantsAV1 = isAV1Quality(quality)
        let wantsCompressedHDR = wantsHEVC || wantsAV1
        let hasDolbyVisionMetadataSource = !dolbyVisionXMLPath.isEmpty || cmuInclude
        if let profile = dolbyVisionProfile,
           profile.usesHLGBaseLayer,
           colorTransform?.isDolbyVisionHLGCompatible != true {
            print("[Error] -dp \(profile.rawValue) requires --gamunt rec2020, rec2020lm, or p3d65 together with --oetf hlg.")
            exit(1)
        }
        if let profile = dolbyVisionProfile,
           !profile.usesHLGBaseLayer,
           colorTransform?.outputOETF == .hlg {
            print("[Error] -dp \(profile.rawValue) requires a PQ base layer; use -dp 84 for HEVC HLG or -dp 104 for AV1 HLG.")
            exit(1)
        }
        if wantsCompressedHDR {
            guard exportFormat == "mov" else {
                print("[Error] -q \(quality) is supported only with MOV output.")
                exit(1)
            }
            guard inputXMLPath.isEmpty && inputAAFPath.isEmpty else {
                print("[Error] -q \(quality) currently supports single-file or folder media input, not timeline XML/AAF bounce.")
                exit(1)
            }
            guard let bitrate = videoBitrateMbps, bitrate > 0 else {
                print("[Error] -q \(quality) requires --bitrate / -b <Mb/s>.")
                exit(1)
            }
            if dolbyVisionProfile != nil && !hasDolbyVisionMetadataSource {
                print("[Error] --dv-profile / -dp requires either external -dovi XML or internally generated --cmu <nits> --cmu-include metadata.")
                exit(1)
            }
            if wantsHEVC, let profile = dolbyVisionProfile, !profile.isHEVCProfile {
                print("[Error] -q hevc with Dolby Vision metadata supports --dv-profile 76, 81, or 84.")
                exit(1)
            }
            if wantsAV1, let profile = dolbyVisionProfile, !profile.isAV1Profile {
                print("[Error] -q av1 with Dolby Vision metadata supports --dv-profile 10 or 104.")
                exit(1)
            }
            if hasDolbyVisionMetadataSource && dolbyVisionProfile == nil {
                let required = wantsAV1 ? "10 or 104" : "76, 81, or 84"
                print("[Error] -q \(quality) with Dolby Vision metadata requires --dv-profile \(required).")
                exit(1)
            }
            if dolbyVisionDualOutput
                && !(wantsHEVC && dolbyVisionProfile?.isProfile76 == true) {
                print("[Error] --dual requires -q hevc with --dv-profile 76 / 7.6.")
                exit(1)
            }
        } else {
            if videoBitrateMbps != nil {
                print("[Error] --bitrate / -b is available only with -q hevc or -q av1.")
                exit(1)
            }
            if dolbyVisionProfile != nil {
                print("[Error] --dv-profile / -dp is available only with -q hevc or -q av1.")
                exit(1)
            }
            if dvFlag {
                print("[Error] --dv-flag / -df is available only with -q hevc or -q av1.")
                exit(1)
            }
            if dolbyVisionDualOutput {
                print("[Error] --dual is available only with -q hevc --dv-profile 76 / 7.6.")
                exit(1)
            }
        }
        if exportFormat == "mov" && aafMode != .none {
            print("[Error] AAF (-ea / -ea-all) is only available with MXF output formats (op1a / opatom)."); exit(1)
        }
        if forcedOutputStartTimecode != nil && exportFormat != "mov" {
            print("[Error] -ffoa / --start-timecode is supported only with MOV output.")
            exit(1)
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
            bitrateMbps: videoBitrateMbps ?? 0,
            dvProfile: dolbyVisionProfile
        ) : nil
        let av1Options = wantsAV1 ? AV1EncodeOptions(
            bitrateMbps: videoBitrateMbps ?? 0,
            dvProfile: dolbyVisionProfile
        ) : nil

        let config = CLIConfig(quality: quality, exportFormat: exportFormat,
                               audioCHperFile: audioCHperFile, aafMode: aafMode,
                               audioReplace: audioReplace,
                               deleteSourceAudio: deleteSourceAudio,
                               forcedOutputStartTimecode: forcedOutputStartTimecode,
                               dolbyVisionXMLURL: dolbyVisionXMLURL,
                               hevcOptions: hevcOptions,
                               av1Options: av1Options,
                               colorTransform: colorTransform,
                               cmuMasteringNits: cmuMasteringNits,
                               cmuInclude: cmuInclude,
                               dvFlag: dvFlag,
                               dolbyVisionDualOutput: dolbyVisionDualOutput)
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
            guard let comp = try? await builder.buildAsync(from: desc) else {
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
            guard let comp = try? await builder.buildAsync(from: desc) else {
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
            let movieExtension = "mov"
            if isOutFile {
                let finalOut = outputURL
                    .deletingPathExtension()
                    .appendingPathExtension(movieExtension)
                _ = await processSingleVideo(inputAsset: asset, outputURL: finalOut,
                                             extraAudioURL: extraAudioURL, assetName: baseName,
                                             config: config)
                exit(encodingOutputExists(for: finalOut, config: config) ? 0 : 1)
            } else {
                try? fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
                let finalOut = outputURL.appendingPathComponent(
                    "\(baseName).\(movieExtension)"
                )
                _ = await processSingleVideo(inputAsset: asset, outputURL: finalOut,
                                             extraAudioURL: extraAudioURL, assetName: baseName,
                                             config: config)
                exit(encodingOutputExists(for: finalOut, config: config) ? 0 : 1)
            }
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
                let movieExtension = "mov"
                let finalOut = outputURL.appendingPathComponent(
                    "\(baseName).\(movieExtension)"
                )
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
        let colorLabel = config.colorTransform == nil ? "HDR10 HEVC" : "HEVC Main10"
        status = "-> Encoding \(colorLabel) \(String(format: "%.2f", hevcOptions.bitrateMbps)) Mb/s\(dvSuffix)"
    } else if isAV1Quality(config.quality), let av1Options = config.av1Options {
        let dvSuffix = av1Options.dvProfile.map { " + Dolby Vision Profile \($0.displayName)" } ?? ""
        let colorLabel = config.colorTransform == nil ? "HDR10 AV1" : "AV1 Main10"
        status = "-> Encoding \(colorLabel) \(String(format: "%.2f", av1Options.bitrateMbps)) Mb/s\(dvSuffix)"
    } else {
        status = "-> Encoding ProRes \(config.quality.uppercased())"
    }
    let audioStatus: String
    if extraAudioURL != nil {
        audioStatus = (config.audioReplace || config.deleteSourceAudio)
            ? " [deleting source audio + injecting extra audio]"
            : " [+ injecting extra audio]"
    } else if config.deleteSourceAudio {
        audioStatus = " [deleting source audio]"
    } else {
        audioStatus = ""
    }
    print(status + audioStatus + "...")

    let outputDir = outputURL.deletingLastPathComponent()
    try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

    if let masteringPeakNits = config.cmuMasteringNits {
        do {
            try await cmuPreflight(
                inputAsset: inputAsset,
                quality: config.quality,
                colorTransform: config.colorTransform,
                masteringPeakNits: masteringPeakNits
            )
        } catch {
            print("[Failed] CMU preflight: \(error.localizedDescription)")
            return nil
        }
    }

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
            audioOverrideURL: (config.audioReplace || config.deleteSourceAudio) ? extraAudioURL : nil,
            deleteSourceAudio: config.deleteSourceAudio,
            colorTransform: config.colorTransform)

        if result.success {
            print("[MXF] Encoded \(result.framesEncoded) frames at " +
                  "\(String(format: "%.1f", result.fps)) fps")
            print("[Success] MXF written for '\(assetName)'.")

            if let masteringPeakNits = config.cmuMasteringNits,
               let videoPath = result.paths.first(where: { $0.hasSuffix("_v.mxf") })
                    ?? result.paths.first(where: { $0.hasSuffix(".mxf") }) {
                do {
                    try await runCMUAnalysisAfterEncode(
                        inputAsset: inputAsset,
                        encodedOutputURL: URL(fileURLWithPath: videoPath),
                        sidecarBaseURL: outputDir.appendingPathComponent(basename),
                        quality: config.quality,
                        masteringPeakNits: masteringPeakNits,
                        forcedStartTimecode: config.forcedOutputStartTimecode
                    )
                } catch {
                    print("[Failed] CMU analysis: \(error.localizedDescription)")
                    return nil
                }
            }

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

    var generatedCMUArtifacts: CMUOutputArtifacts? = nil
    var dolbyVisionXMLURL = config.dolbyVisionXMLURL
    let isCompressedOutput =
        isHEVCQuality(config.quality) || isAV1Quality(config.quality)
    let temporaryCMUSidecarBaseURL = isCompressedOutput
        ? FileManager.default.temporaryDirectory.appendingPathComponent(
            "prores-encoder-cmu-\(UUID().uuidString)"
        )
        : outputURL
    defer {
        if isCompressedOutput {
            let temporaryXMLURL = temporaryCMUSidecarBaseURL.appendingPathExtension("xml")
            try? fm.removeItem(at: temporaryXMLURL)
        }
    }
    if config.cmuInclude,
       let masteringPeakNits = config.cmuMasteringNits,
       isCompressedOutput {
        do {
            let artifacts = try await runCMUAnalysisBeforeCompressedEncode(
                inputAsset: inputAsset,
                sidecarBaseURL: temporaryCMUSidecarBaseURL,
                quality: config.quality,
                colorTransform: config.colorTransform,
                masteringPeakNits: masteringPeakNits,
                forcedStartTimecode: config.forcedOutputStartTimecode
            )
            generatedCMUArtifacts = artifacts
            dolbyVisionXMLURL = artifacts.xmlURL
        } catch {
            print("[Failed] CMU analysis: \(error.localizedDescription)")
            try? fm.removeItem(at: outputURL)
            return nil
        }
    }

    let success = await encodeMOV(
        asset: inputAsset, outputURL: outputURL,
        quality: config.quality, extraAudioURL: extraAudioURL,
        audioReplace: config.audioReplace,
        deleteSourceAudio: config.deleteSourceAudio,
        forcedOutputStartTimecode: config.forcedOutputStartTimecode,
        dolbyVisionXMLURL: dolbyVisionXMLURL,
        hevcOptions: config.hevcOptions,
        av1Options: config.av1Options,
        colorSpace: cs, fpsInfo: fpsI,
        colorTransform: config.colorTransform,
        useDolbyVisionCodecTag: config.dvFlag,
        dolbyVisionDualOutput: config.dolbyVisionDualOutput)

    guard success else {
        print("[Failed] \(assetName)")
        try? fm.removeItem(at: outputURL)
        return nil
    }
    if let masteringPeakNits = config.cmuMasteringNits,
       generatedCMUArtifacts == nil {
        do {
            let artifacts = try await runCMUAnalysisAfterEncode(
                inputAsset: inputAsset,
                encodedOutputURL: outputURL,
                sidecarBaseURL: temporaryCMUSidecarBaseURL,
                quality: config.quality,
                masteringPeakNits: masteringPeakNits,
                forcedStartTimecode: config.forcedOutputStartTimecode
            )
            generatedCMUArtifacts = artifacts
        } catch {
            print("[Failed] CMU analysis: \(error.localizedDescription)")
            try? fm.removeItem(at: outputURL)
            return nil
        }
    }
    if config.cmuInclude,
       !isHEVCQuality(config.quality),
       !isAV1Quality(config.quality),
       let xmlURL = generatedCMUArtifacts?.xmlURL {
        guard await includeGeneratedCMUXMLInProResMOV(
            outputURL: outputURL,
            xmlURL: xmlURL
        ) else {
            try? fm.removeItem(at: outputURL)
            return nil
        }
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

private func fileHasContent(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let fileSize = attributes[.size] as? NSNumber else {
        return false
    }
    return fileSize.int64Value > 0
}

private func encodingOutputExists(for requestedURL: URL, config: CLIConfig) -> Bool {
    guard config.exportFormat != "mov" else {
        return fileHasContent(requestedURL)
    }
    let directory = requestedURL.deletingLastPathComponent()
    let basename = requestedURL.deletingPathExtension().lastPathComponent
    let candidates = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey]
    )) ?? []
    return candidates.contains {
        $0.pathExtension.lowercased() == "mxf"
            && $0.deletingPathExtension().lastPathComponent.hasPrefix(basename)
            && fileHasContent($0)
    }
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

    var selectedPreset: String?
    for candidate in timelineExportPresetCandidates(for: requestedQuality) {
        if await AVAssetExportSession.compatibility(
            ofExportPreset: candidate,
            with: composition,
            outputFileType: nil
        ) {
            selectedPreset = candidate
            break
        }
    }
    guard let preset = selectedPreset,
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
        quality: config.quality,
        forcedOutputStartTimecode: config.forcedOutputStartTimecode,
        deleteSourceAudio: config.deleteSourceAudio,
        colorTransform: config.colorTransform)

    guard success else {
        try? fm.removeItem(at: outputURL)
        print("[Failed] \(assetName)")
        return false
    }
    var generatedCMUArtifacts: CMUOutputArtifacts? = nil
    if let masteringPeakNits = config.cmuMasteringNits {
        do {
            generatedCMUArtifacts = try await runCMUAnalysisOnOutput(
                outputURL: outputURL,
                masteringPeakNits: masteringPeakNits,
                forcedStartTimecode: config.forcedOutputStartTimecode
            )
        } catch {
            print("[Failed] CMU analysis: \(error.localizedDescription)")
            return false
        }
    }
    if config.cmuInclude,
       let xmlURL = generatedCMUArtifacts?.xmlURL {
        guard await includeGeneratedCMUXMLInProResMOV(
            outputURL: outputURL,
            xmlURL: xmlURL
        ) else {
            return false
        }
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
      -v, --version                    Print version and exit
      -q, --quality <proxy|422lt|422|422hq|4444|4444xq|pass|hevc|av1>  Output codec/quality (default: 422hq)
      -b, --bitrate <Mb/s>           HEVC/AV1 bitrate in Mb/s (required with -q hevc or -q av1)
      -dp, --dv-profile <76|81|84|10|104> Dolby Vision profile: HEVC 7.6/8.1/8.4 or AV1 10.1/10.4
      -df, --dv-flag                  Label HEVC as dvhe (7.6) / dvh1 (8.x), or AV1 as dav1; default is hvc1/av01
      --dual                          With -q hevc -dp 76, also write Profile 7.6 BL/EL .hevc streams beside the MOV
      -aa, --add-audio <audio_file>   Add external audio in MOV mode, or provide replacement audio
      -ar, --audio-replace            Replace source audio with the -aa audio file
      -dsa, --delete-source-audio     Delete source audio first; may be combined with -aa to add only the new audio
      -ffoa, --start-timecode <TC>    MOV only; synthesize QuickTime TC from this start value when the source has no TC (default: 01:00:00:00)
      -dovi, --dolby-vision-xml <file> MOV only; embed ProRes PHDR metadata, or generate RPU for -q hevc/-q av1
      --gamunt <rec709|rec2020|rec2020lm|p3d65> Target gamut; rec2020lm is Rec.2020 tagged with P3-D65 gamut limiting
      --oetf <gamma2.4|gamma2.6|pq|hlg> Target opto-electronic transfer function
      --nit <nits>                     Target peak luminance, 1 <= nits <= 10000
      --cmu <nits>                     Metal-only HDR analysis; ProRes/MXF exports XML, HEVC/AV1 keep it internal
      --cmu-include                    Use the internally generated CMU XML directly as ProRes PHDR metadata, or to generate HEVC/AV1 RPU; requires --cmu and no -dovi
      --audio-ch-per-file <N>         Channels per OP-Atom audio MXF (default: 1)
      -ea, --export-aaf               Generate one AAF for all clips (MXF modes only)
      -ea-all, --export-aaf-all       Generate one AAF per clip (MXF modes only)
    """)
}

#endif
