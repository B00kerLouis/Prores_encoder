// Selects the eligible media stage for GPU metadata analysis and coordinates
// analysis, timecode resolution, and XML export.

import Foundation
@preconcurrency import AVFoundation

/// Validates mastering brightness and confirms that either the input or planned
/// output can supply PQ pixels in a supported gamut.
func cmuPreflight(
    inputAsset: AVAsset,
    quality: String,
    colorTransform: ColorTransformRequest?,
    dolbyVisionProfile: DolbyVisionHEVCProfile? = nil,
    masteringPeakNits: Float
) async throws {
    guard masteringPeakNits.isFinite,
          masteringPeakNits >= 1,
          masteringPeakNits <= 10_000 else {
        throw CMUError.invalidMasteringBrightness("\(masteringPeakNits)")
    }
    guard let inputURL = (inputAsset as? AVURLAsset)?.url else {
        throw CMUError.unsupportedColorSpace(
            "CMU currently requires file-based input media."
        )
    }

    if isHEVCQuality(quality) || isAV1Quality(quality) {
        _ = try await CMUAssetDescriptor.inspect(url: inputURL)
        if let colorTransform {
            guard let track = try? await inputAsset.loadTracks(withMediaType: .video).first else {
                throw CMUError.noVideoTrack(inputURL)
            }
            let resolved = try resolveColorTransform(
                request: colorTransform,
                sourceColorSpace: await detectColorSpace(from: track)
            )
            switch colorTransform.outputOETF {
            case .hlg:
                print(
                    "[CMU] \(quality.uppercased()) uses the PQ input as the Dolby Vision " +
                    "metadata source before Profile 8.4/10.4 HLG base-layer conversion."
                )
            case .pq:
                guard colorTransform.outputGamut == .p3D65
                        || colorTransform.outputGamut.isRec2020Encoding else {
                    throw CMUError.unsupportedColorSpace(
                        "Compressed Profile 8.1/10.1 CMU generation requires a P3-D65 " +
                        "or Rec.2020-encoded PQ base layer."
                    )
                }
                if let dolbyVisionProfile, !dolbyVisionProfile.usesNativeIPT {
                    print(
                        "[CMU] Profile \(dolbyVisionProfile.displayName) Level 4 analysis " +
                        "uses the common PQ master before compatibility base-layer conversion."
                    )
                } else {
                    print(
                        "[CMU] \(quality.uppercased()) CMU analysis will apply the requested " +
                        "\(resolved.outputGamut.label) PQ transform before measuring the pixels."
                    )
                }
            default:
                throw CMUError.unsupportedColorSpace(
                    "Compressed Dolby Vision generation supports a preserved PQ base layer " +
                    "or PQ-to-HLG Profile 8.4/10.4 conversion."
                )
            }
        } else {
            print("[CMU] \(quality.uppercased()) analysis source is the input file by rule.")
        }
        return
    }

    if let colorTransform,
       colorTransform.outputOETF == .pq,
       (colorTransform.outputGamut == .p3D65
            || colorTransform.outputGamut.isRec2020Encoding) {
        print("[CMU] Planned ProRes output is \(colorTransform.outputGamut.label) PQ; output analysis will take priority.")
        return
    }

    do {
        _ = try await CMUAssetDescriptor.inspect(url: inputURL)
        if colorTransform == nil {
            print("[CMU] Input and inherited ProRes output are eligible; output analysis will take priority.")
        } else {
            print("[CMU] Planned output is not eligible PQ; CMU will analyze the eligible input.")
        }
    } catch {
        throw CMUError.unsupportedColorSpace(
            "Neither the input nor the planned output is P3-D65 PQ or Rec.2020 PQ."
        )
    }
}

@discardableResult
/// Analyzes the encoded output when eligible, otherwise analyzes the input, and
/// writes the resulting metadata beside `sidecarBaseURL`.
func runCMUAnalysisAfterEncode(
    inputAsset: AVAsset,
    encodedOutputURL: URL,
    sidecarBaseURL: URL,
    quality: String,
    masteringPeakNits: Float,
    forcedStartTimecode: String?
) async throws -> CMUOutputArtifacts {
    guard let inputURL = (inputAsset as? AVURLAsset)?.url else {
        throw CMUError.unsupportedColorSpace(
            "CMU currently requires file-based input media."
        )
    }

    let selectedURL: URL
    let descriptor: CMUAssetDescriptor
    let source: CMUAnalysisSource
    if isHEVCQuality(quality) || isAV1Quality(quality) {
        selectedURL = inputURL
        descriptor = try await CMUAssetDescriptor.inspect(url: inputURL)
        source = .input
    } else if let outputDescriptor = try? await CMUAssetDescriptor.inspect(
        url: encodedOutputURL
    ) {
        selectedURL = encodedOutputURL
        descriptor = outputDescriptor
        source = .output
    } else {
        selectedURL = inputURL
        descriptor = try await CMUAssetDescriptor.inspect(url: inputURL)
        source = .input
    }

    return try await runCMUAnalysis(
        selectedURL: selectedURL,
        descriptor: descriptor,
        source: source,
        fallbackInputURL: inputURL,
        sidecarBaseURL: sidecarBaseURL,
        masteringPeakNits: masteringPeakNits,
        forcedStartTimecode: forcedStartTimecode
    )
}

@discardableResult
/// Analyzes input pixels before compressed encoding, optionally applying the
/// resolved PQ color transform used by the later encoder.
func runCMUAnalysisBeforeCompressedEncode(
    inputAsset: AVAsset,
    sidecarBaseURL: URL,
    quality: String,
    colorTransform: ColorTransformRequest?,
    dolbyVisionProfile: DolbyVisionHEVCProfile?,
    masteringPeakNits: Float,
    forcedStartTimecode: String?
) async throws -> CMUOutputArtifacts {
    guard isHEVCQuality(quality) || isAV1Quality(quality) else {
        throw CMUError.exportFailed(
            "--cmu-include pre-encode analysis is reserved for HEVC or AV1 output."
        )
    }
    guard let inputURL = (inputAsset as? AVURLAsset)?.url else {
        throw CMUError.unsupportedColorSpace(
            "CMU currently requires file-based input media."
        )
    }
    let inputDescriptor = try await CMUAssetDescriptor.inspect(url: inputURL)
    var descriptor = inputDescriptor
    var resolvedTransform: ResolvedColorTransform?
    if let colorTransform,
       colorTransform.outputOETF == .pq,
       dolbyVisionProfile == nil || dolbyVisionProfile?.usesNativeIPT == true {
        guard let track = try await inputAsset.loadTracks(withMediaType: .video).first else {
            throw CMUError.noVideoTrack(inputURL)
        }
        let resolved = try resolveColorTransform(
            request: colorTransform,
            sourceColorSpace: await detectColorSpace(from: track)
        )
        descriptor = inputDescriptor.applying(resolved)
        resolvedTransform = resolved
    }
    print("[CMU] Generating Dolby Vision metadata before \(quality.uppercased()) encode.")
    return try await runCMUAnalysis(
        selectedURL: inputURL,
        descriptor: descriptor,
        source: resolvedTransform == nil ? .input : .transformedInput,
        fallbackInputURL: inputURL,
        sidecarBaseURL: sidecarBaseURL,
        masteringPeakNits: masteringPeakNits,
        forcedStartTimecode: forcedStartTimecode,
        colorTransform: resolvedTransform
    )
}

/// Runs the common analyzer and exporter path for the selected source.
private func runCMUAnalysis(
    selectedURL: URL,
    descriptor: CMUAssetDescriptor,
    source: CMUAnalysisSource,
    fallbackInputURL: URL?,
    sidecarBaseURL: URL,
    masteringPeakNits: Float,
    forcedStartTimecode: String?,
    colorTransform: ResolvedColorTransform? = nil
) async throws -> CMUOutputArtifacts {
    let timecode = try await cmuResolveTimecodeReference(
        analyzedURL: selectedURL,
        fallbackInputURL: fallbackInputURL,
        forcedStartTimecode: forcedStartTimecode,
        editRate: descriptor.editRate
    )
    print(
        "[CMU] Metal-only analysis: \(source.rawValue) \(selectedURL.lastPathComponent), " +
        "\(descriptor.primaries.displayName) PQ, master \(String(format: "%.1f", masteringPeakNits)) nit."
    )
    print(
        "[CMU] Record starts at \(timecode.stringValue) / frame \(timecode.startFrame) " +
        "using \(timecode.origin.rawValue) reference."
    )

    let analyzer = try CMUMetalAnalyzer()
    let document = try await analyzer.analyze(
        url: selectedURL,
        descriptor: descriptor,
        source: source,
        masteringPeakNits: masteringPeakNits,
        timecode: timecode,
        colorTransform: colorTransform
    )
    let artifacts = try CMUExporter.write(
        document: document,
        sidecarBaseURL: sidecarBaseURL
    )
    print(
        "[CMU] Analyzed \(document.durationFrames) actual decoded frames " +
        "(\(document.recordIn)...\(document.recordOut)); MaxCLL \(document.maxCLL), MaxFALL \(document.maxFALL)."
    )
    if let first = artifacts.level4Measurements.first,
       let last = artifacts.level4Measurements.last {
        print(
            "[CMU] L4 PQ(maxRGB) moments \(artifacts.level4Measurements.count) frames; " +
            "first \(String(format: "%.6f", first.meanMaxRGBPQ))/" +
            "\(String(format: "%.6f", first.stdevMaxRGBPQ)), last " +
            "\(String(format: "%.6f", last.meanMaxRGBPQ))/" +
            "\(String(format: "%.6f", last.stdevMaxRGBPQ))."
        )
    }
    print("[CMU] XML -> \(artifacts.xmlURL.path)")
    return artifacts
}

/// Runs the Metal statistics prepass required when an external authoring XML
/// does not carry the RPU-only per-frame Level 4 analysis sequence.
func runDolbyVisionLevel4Analysis(
    inputAsset: AVAsset,
    colorTransform: ResolvedColorTransform?,
    profile: DolbyVisionHEVCProfile
) async throws -> [DolbyVisionLevel4Measurement] {
    guard let inputURL = (inputAsset as? AVURLAsset)?.url else {
        throw CMUError.unsupportedColorSpace(
            "Dolby Vision Level 4 analysis requires file-based input media."
        )
    }
    let inputDescriptor = try await CMUAssetDescriptor.inspect(url: inputURL)
    // P8.4/P10.4 still derives authoring L4 from the common PQ master, never
    // from the HLG compatibility base layer.
    let analysisTransform = profile.usesNativeIPT && colorTransform?.outputOETF == .pq
        ? colorTransform
        : nil
    let descriptor = analysisTransform.map(inputDescriptor.applying) ?? inputDescriptor
    let timecode = CMUTimecodeReference(
        startFrame: 0,
        stringValue: "00:00:00:00",
        isDropFrame: false,
        origin: .zero
    )
    print(
        "[DoVi] Metal PQ-master Level 4 analysis: \(inputURL.lastPathComponent), " +
        "\(descriptor.primaries.displayName) PQ."
    )
    let document = try await CMUMetalAnalyzer().analyze(
        url: inputURL,
        descriptor: descriptor,
        source: analysisTransform == nil ? .input : .transformedInput,
        masteringPeakNits: 10_000,
        timecode: timecode,
        colorTransform: analysisTransform
    )
    return cmuBuildDolbyVisionLevel4Measurements(
        frames: document.frames
    )
}

@discardableResult
/// Analyzes a completed timeline output and writes its metadata sidecar.
func runCMUAnalysisOnOutput(
    outputURL: URL,
    masteringPeakNits: Float,
    forcedStartTimecode: String?
) async throws -> CMUOutputArtifacts {
    let descriptor = try await CMUAssetDescriptor.inspect(url: outputURL)
    let timecode = try await cmuResolveTimecodeReference(
        analyzedURL: outputURL,
        fallbackInputURL: nil,
        forcedStartTimecode: forcedStartTimecode,
        editRate: descriptor.editRate
    )
    print(
        "[CMU] Metal-only timeline output analysis: \(outputURL.lastPathComponent), " +
        "\(descriptor.primaries.displayName) PQ."
    )
    let document = try await CMUMetalAnalyzer().analyze(
        url: outputURL,
        descriptor: descriptor,
        source: .output,
        masteringPeakNits: masteringPeakNits,
        timecode: timecode
    )
    let artifacts = try CMUExporter.write(
        document: document,
        sidecarBaseURL: outputURL
    )
    print("[CMU] XML -> \(artifacts.xmlURL.path)")
    return artifacts
}
