// Rewrites a completed ProRes MOV to include generated timed metadata without
// re-encoding its video samples.

import Foundation
@preconcurrency import AVFoundation

/// Writes metadata into a temporary passthrough MOV and atomically replaces the
/// original output after the writer succeeds.
func includeGeneratedCMUXMLInProResMOV(
    outputURL: URL,
    xmlURL: URL
) async -> Bool {
    let fileManager = FileManager.default
    let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
        ".\(outputURL.deletingPathExtension().lastPathComponent).cmu-include-\(UUID().uuidString).mov"
    )
    defer { try? fileManager.removeItem(at: temporaryURL) }

    let encodedAsset = AVURLAsset(
        url: outputURL,
        options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    )
    print("[CMU] Including generated XML as ProRes PHDR metadata without re-encoding video.")
    let success = await encodeMOV(
        asset: encodedAsset,
        outputURL: temporaryURL,
        quality: "pass",
        extraAudioURL: nil,
        audioReplace: false,
        deleteSourceAudio: false,
        forcedOutputStartTimecode: nil,
        dolbyVisionXMLURL: xmlURL,
        hevcOptions: nil,
        av1Options: nil,
        colorSpace: nil,
        fpsInfo: await framerateInfo(from: encodedAsset),
        colorTransform: nil
    )
    guard success else {
        print("[Failed] Could not include generated CMU XML in \(outputURL.lastPathComponent).")
        return false
    }

    do {
        _ = try fileManager.replaceItemAt(
            outputURL,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: []
        )
        print("[CMU] Included XML -> \(outputURL.path)")
        return true
    } catch {
        print("[Failed] Could not replace MOV after CMU metadata inclusion: \(error.localizedDescription)")
        return false
    }
}
