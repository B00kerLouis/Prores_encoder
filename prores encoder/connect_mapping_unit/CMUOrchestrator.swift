import Foundation
@preconcurrency import AVFoundation

func cmuPreflight(
    inputAsset: AVAsset,
    quality: String,
    colorTransform: ColorTransformRequest?,
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
                let preservesAnalyzedPixels =
                    colorTransform.outputGamut == resolved.input.gamut
                    && colorTransform.outputGamut != .rec2020LimitedToP3D65
                    && abs(colorTransform.targetNits - resolved.input.peakNits) < 0.5
                guard preservesAnalyzedPixels else {
                    throw CMUError.unsupportedColorSpace(
                        "For compressed Profile 8.1/10.1 output, CMU can use the input " +
                        "directly only when --gamunt, --oetf pq, and --nit preserve the " +
                        "source gamut and mastering peak."
                    )
                }
                print(
                    "[CMU] \(quality.uppercased()) PQ conversion preserves the analyzed " +
                    "source gamut and mastering peak; generated metadata can drive the encode directly."
                )
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
func runCMUAnalysisBeforeCompressedEncode(
    inputAsset: AVAsset,
    sidecarBaseURL: URL,
    quality: String,
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
    let descriptor = try await CMUAssetDescriptor.inspect(url: inputURL)
    print("[CMU] Generating Dolby Vision metadata before \(quality.uppercased()) encode.")
    return try await runCMUAnalysis(
        selectedURL: inputURL,
        descriptor: descriptor,
        source: .input,
        fallbackInputURL: inputURL,
        sidecarBaseURL: sidecarBaseURL,
        masteringPeakNits: masteringPeakNits,
        forcedStartTimecode: forcedStartTimecode
    )
}

private func runCMUAnalysis(
    selectedURL: URL,
    descriptor: CMUAssetDescriptor,
    source: CMUAnalysisSource,
    fallbackInputURL: URL?,
    sidecarBaseURL: URL,
    masteringPeakNits: Float,
    forcedStartTimecode: String?
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
        timecode: timecode
    )
    let artifacts = try CMUExporter.write(
        document: document,
        sidecarBaseURL: sidecarBaseURL
    )
    print(
        "[CMU] Analyzed \(document.durationFrames) actual decoded frames " +
        "(\(document.recordIn)...\(document.recordOut)); MaxCLL \(document.maxCLL), MaxFALL \(document.maxFALL)."
    )
    print("[CMU] XML -> \(artifacts.xmlURL.path)")
    return artifacts
}

@discardableResult
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
