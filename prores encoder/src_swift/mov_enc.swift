// mov_enc.swift — MOV container writer using AVAssetWriter
// Handles:
//  - Video pump driven by VideoFrameSource (VT encoded or passthrough)
//  - Audio passthrough pump
//  - Extra external audio pump
//  - Timecode & metadata passthrough pumps
//  - Concurrent pump coordination via TaskGroup
//
// Memory model: dispatch-queue-per-track, one sample at a time,
// autoreleasepool per iteration — safe for 4 h+ files.

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - Sendable Utility Wrappers

/// Wraps a non-Sendable value for safe transfer across isolation boundaries.
final class SendableRef<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// Bundles an AVAssetWriterInput + AVAssetReaderOutput pair for pump-based writing.
final class MediaPumpPair: @unchecked Sendable {
    let input:  AVAssetWriterInput
    let output: AVAssetReaderOutput
    init(input: AVAssetWriterInput, output: AVAssetReaderOutput) {
        self.input  = input; self.output = output
    }
}

/// Bundles timed metadata reader/writer adaptors for pump-based writing.
final class TimedMetadataPumpPair: @unchecked Sendable {
    let input: AVAssetWriterInput
    let writerAdaptor: AVAssetWriterInputMetadataAdaptor
    let readerAdaptor: AVAssetReaderOutputMetadataAdaptor

    init(
        input: AVAssetWriterInput,
        writerAdaptor: AVAssetWriterInputMetadataAdaptor,
        readerAdaptor: AVAssetReaderOutputMetadataAdaptor
    ) {
        self.input = input
        self.writerAdaptor = writerAdaptor
        self.readerAdaptor = readerAdaptor
    }
}

/// One-shot guard, claimable at most once across concurrent callers.
final class OnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true; return true
    }
}

final class PipelineFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    func store(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
        lock.unlock()
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Thread-safe terminal progress bar.
final class ProgressBar: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private let total: Int
    private var lastPercent = -1

    init(total: Int) { self.total = max(total, 1) }

    func increment() {
        lock.lock()
        current += 1
        let pct = min(current * 100 / total, 100)
        if pct != lastPercent {
            lastPercent = pct
            let w = 40; let f = pct * w / 100; let e = w - f
            let bar = String(repeating: "█", count: f) + String(repeating: "░", count: e)
            print("\r  [\(bar)] \(pct)% (\(current)/\(total))", terminator: "")
            fflush(stdout)
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let bar = String(repeating: "█", count: 40)
        print("\r  [\(bar)] 100% (\(total)/\(total))")
        fflush(stdout)
        lock.unlock()
    }
}

private func writerStatusName(_ status: AVAssetWriter.Status) -> String {
    switch status {
    case .unknown: return "unknown"
    case .writing: return "writing"
    case .completed: return "completed"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

private func readerStatusName(_ status: AVAssetReader.Status) -> String {
    switch status {
    case .unknown: return "unknown"
    case .reading: return "reading"
    case .completed: return "completed"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

private func makeWriterFailure(
    stage: String,
    writer: AVAssetWriter,
    reader: AVAssetReader? = nil
) -> NSError {
    var parts = ["\(stage)"]
    parts.append("writer.status=\(writerStatusName(writer.status))")
    if let error = writer.error?.localizedDescription {
        parts.append("writer.error=\(error)")
    }
    if let reader {
        parts.append("reader.status=\(readerStatusName(reader.status))")
        if let error = reader.error?.localizedDescription {
            parts.append("reader.error=\(error)")
        }
    }
    return NSError(
        domain: "encodeMOV",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: parts.joined(separator: "; ")]
    )
}

private func makeMetadataProbeFailure(stage: String, reader: AVAssetReader? = nil) -> NSError {
    var parts = ["\(stage)"]
    if let reader {
        parts.append("reader.status=\(readerStatusName(reader.status))")
        if let error = reader.error?.localizedDescription {
            parts.append("reader.error=\(error)")
        }
    }
    return NSError(
        domain: "encodeMOV",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: parts.joined(separator: "; ")]
    )
}

private func probeTimedMetadataFormatHint(
    asset: AVAsset,
    track: AVAssetTrack
) async throws -> CMMetadataFormatDescription {
    let probeReader = try AVAssetReader(asset: asset)
    let probeOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    probeOutput.alwaysCopiesSampleData = false

    guard probeReader.canAdd(probeOutput) else {
        throw makeMetadataProbeFailure(
            stage: "Metadata track \(track.trackID) probe output cannot be added"
        )
    }
    probeReader.add(probeOutput)

    let probeAdaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: probeOutput)
    guard probeReader.startReading() else {
        throw makeMetadataProbeFailure(
            stage: "Metadata track \(track.trackID) probe reader failed to start",
            reader: probeReader
        )
    }
    guard let firstGroup = probeAdaptor.nextTimedMetadataGroup() else {
        throw makeMetadataProbeFailure(
            stage: "Metadata track \(track.trackID) produced no timed metadata groups",
            reader: probeReader
        )
    }
    guard let formatHint = firstGroup.copyFormatDescription() else {
        throw makeMetadataProbeFailure(
            stage: "Metadata track \(track.trackID) could not build a boxed metadata format hint"
        )
    }
    return formatHint
}

private func copyTrackLanguageIfPresent(
    from sourceTrack: AVAssetTrack,
    to writerInput: AVAssetWriterInput
) async {
    if let extendedLanguageTag = try? await sourceTrack.load(.extendedLanguageTag),
       !extendedLanguageTag.isEmpty {
        writerInput.extendedLanguageTag = extendedLanguageTag
        return
    }
    if let languageCode = try? await sourceTrack.load(.languageCode),
       !languageCode.isEmpty {
        writerInput.languageCode = languageCode
    }
}

private func addMetadataReferentAssociations(
    from sourceTrack: AVAssetTrack,
    to metadataInput: AVAssetWriterInput,
    inputMap: [CMPersistentTrackID: AVAssetWriterInput]
) async {
    guard let associationTypes = try? await sourceTrack.load(.availableTrackAssociationTypes) else {
        return
    }
    let metadataReferentType = AVAssetTrack.AssociationType.metadataReferent
    guard associationTypes.contains(metadataReferentType),
          let referentTracks = try? await sourceTrack.loadAssociatedTracks(ofType: metadataReferentType)
    else {
        return
    }

    for referentTrack in referentTracks {
        guard let referentInput = inputMap[referentTrack.trackID] else { continue }
        let associationType = metadataReferentType.rawValue
        if metadataInput.canAddTrackAssociation(withTrackOf: referentInput, type: associationType) {
            metadataInput.addTrackAssociation(withTrackOf: referentInput, type: associationType)
        }
    }
}

private struct MOVAtomDescriptor {
    let offset: UInt64
    let size: UInt64
    let headerSize: UInt64
    let type: String
}

private struct MetadataTrackSampleDescription {
    let stsdOffset: UInt64
    let stsdSize: UInt64
}

private func readUInt32BE(from data: Data, at offset: Int = 0) -> UInt32 {
    var value: UInt32 = 0
    for byte in data[offset..<(offset + 4)] {
        value = (value << 8) | UInt32(byte)
    }
    return value
}

private func readUInt64BE(from data: Data, at offset: Int = 0) -> UInt64 {
    var value: UInt64 = 0
    for byte in data[offset..<(offset + 8)] {
        value = (value << 8) | UInt64(byte)
    }
    return value
}

private func readExactData(
    from handle: FileHandle,
    at offset: UInt64,
    count: Int
) throws -> Data {
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: count), data.count == count else {
        throw NSError(
            domain: "encodeMOV",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to read \(count) bytes at offset \(offset)"]
        )
    }
    return data
}

private func readAtomDescriptor(
    from handle: FileHandle,
    at offset: UInt64,
    limit: UInt64
) throws -> MOVAtomDescriptor? {
    guard offset + 8 <= limit else { return nil }

    let header = try readExactData(from: handle, at: offset, count: 8)
    var size = UInt64(readUInt32BE(from: header))
    let type = String(data: header[4..<8], encoding: .isoLatin1) ?? ""
    var headerSize: UInt64 = 8

    if size == 1 {
        let extendedSize = try readExactData(from: handle, at: offset + 8, count: 8)
        size = readUInt64BE(from: extendedSize)
        headerSize = 16
    } else if size == 0 {
        size = limit - offset
    }

    guard size >= headerSize, offset + size <= limit else {
        throw NSError(
            domain: "encodeMOV",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid atom '\(type)' at offset \(offset)"]
        )
    }

    return MOVAtomDescriptor(offset: offset, size: size, headerSize: headerSize, type: type)
}

private func findChildAtom(
    named type: String,
    in parent: MOVAtomDescriptor,
    handle: FileHandle
) throws -> MOVAtomDescriptor? {
    var cursor = parent.offset + parent.headerSize
    let limit = parent.offset + parent.size

    while cursor < limit {
        guard let atom = try readAtomDescriptor(from: handle, at: cursor, limit: limit) else {
            return nil
        }
        if atom.type == type { return atom }
        cursor += atom.size
    }
    return nil
}

private func metadataTrackSampleDescriptions(in movieURL: URL) throws -> [MetadataTrackSampleDescription] {
    let handle = try FileHandle(forReadingFrom: movieURL)
    defer {
        try? handle.close()
    }

    let fileSize = try handle.seekToEnd()
    try handle.seek(toOffset: 0)

    var results: [MetadataTrackSampleDescription] = []
    var topLevelCursor: UInt64 = 0

    while topLevelCursor < fileSize {
        guard let atom = try readAtomDescriptor(from: handle, at: topLevelCursor, limit: fileSize) else {
            break
        }
        defer { topLevelCursor += atom.size }
        guard atom.type == "moov" else { continue }

        var moovCursor = atom.offset + atom.headerSize
        let moovLimit = atom.offset + atom.size
        while moovCursor < moovLimit {
            guard let trak = try readAtomDescriptor(from: handle, at: moovCursor, limit: moovLimit) else {
                break
            }
            defer { moovCursor += trak.size }
            guard trak.type == "trak",
                  let mdia = try findChildAtom(named: "mdia", in: trak, handle: handle),
                  let hdlr = try findChildAtom(named: "hdlr", in: mdia, handle: handle)
            else {
                continue
            }

            let handlerTypeData = try readExactData(
                from: handle,
                at: hdlr.offset + hdlr.headerSize + 8,
                count: 4
            )
            let handlerType = String(data: handlerTypeData, encoding: .isoLatin1) ?? ""
            guard handlerType == "meta",
                  let minf = try findChildAtom(named: "minf", in: mdia, handle: handle),
                  let stbl = try findChildAtom(named: "stbl", in: minf, handle: handle),
                  let stsd = try findChildAtom(named: "stsd", in: stbl, handle: handle)
            else {
                continue
            }

            results.append(
                MetadataTrackSampleDescription(
                    stsdOffset: stsd.offset,
                    stsdSize: stsd.size
                )
            )
        }
    }

    return results
}

private func patchPassthroughMetadataSampleDescriptions(
    sourceURL: URL,
    outputURL: URL
) throws {
    let sourceDescriptions = try metadataTrackSampleDescriptions(in: sourceURL)
    guard !sourceDescriptions.isEmpty else { return }

    let outputDescriptions = try metadataTrackSampleDescriptions(in: outputURL)
    guard sourceDescriptions.count == outputDescriptions.count else {
        throw NSError(
            domain: "encodeMOV",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Metadata track count mismatch while patching sample descriptions (source \(sourceDescriptions.count), output \(outputDescriptions.count))"
            ]
        )
    }

    let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer {
        try? sourceHandle.close()
        try? outputHandle.close()
    }

    for (index, (sourceDescription, outputDescription)) in zip(sourceDescriptions, outputDescriptions).enumerated() {
        guard sourceDescription.stsdSize == outputDescription.stsdSize else {
            throw NSError(
                domain: "encodeMOV",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Metadata track \(index + 1) sample description size mismatch (source \(sourceDescription.stsdSize), output \(outputDescription.stsdSize))"
                ]
            )
        }
        let stsdData = try readExactData(
            from: sourceHandle,
            at: sourceDescription.stsdOffset,
            count: Int(sourceDescription.stsdSize)
        )
        try outputHandle.seek(toOffset: outputDescription.stsdOffset)
        outputHandle.write(stsdData)
    }
}

// MARK: - Pump drivers

/// Drives a plain passthrough pump (audio / timecode / metadata).
private func startPassthroughPump(
    _ pair: MediaPumpPair,
    queueLabel: String,
    trackLabel: String,
    writer: AVAssetWriter,
    reader: AVAssetReader,
    progress: ProgressBar? = nil,
    cont: CheckedContinuation<Void, Error>
) {
    enum PumpStep {
        case appended
        case finished
        case failed(Error)
    }

    let once = OnceGuard()
    pair.input.requestMediaDataWhenReady(on: DispatchQueue(label: queueLabel, qos: .userInitiated)) {
        while pair.input.isReadyForMoreMediaData {
            let step: PumpStep = autoreleasepool {
                guard let buf = pair.output.copyNextSampleBuffer() else { return .finished }
                guard pair.input.append(buf) else {
                    return .failed(makeWriterFailure(
                        stage: "\(trackLabel) append failed",
                        writer: writer,
                        reader: reader
                    ))
                }
                progress?.increment()
                return .appended
            }
            switch step {
            case .appended:
                continue
            case .finished:
                pair.input.markAsFinished()
                if once.claim() { cont.resume() }
                return
            case .failed(let error):
                pair.input.markAsFinished()
                if once.claim() { cont.resume(throwing: error) }
                return
            }
        }
    }
}

/// Drives a timed metadata pump, preserving a real metadata track in the output MOV.
private func startTimedMetadataPump(
    _ pair: TimedMetadataPumpPair,
    queueLabel: String,
    trackLabel: String,
    writer: AVAssetWriter,
    reader: AVAssetReader,
    cont: CheckedContinuation<Void, Error>
) {
    enum PumpStep {
        case appended
        case finished
        case failed(Error)
    }

    let once = OnceGuard()
    pair.input.requestMediaDataWhenReady(on: DispatchQueue(label: queueLabel, qos: .utility)) {
        while pair.input.isReadyForMoreMediaData {
            let step: PumpStep = autoreleasepool {
                guard let group = pair.readerAdaptor.nextTimedMetadataGroup() else { return .finished }
                guard pair.writerAdaptor.append(group) else {
                    return .failed(makeWriterFailure(
                        stage: "\(trackLabel) append failed",
                        writer: writer,
                        reader: reader
                    ))
                }
                return .appended
            }
            switch step {
            case .appended:
                continue
            case .finished:
                pair.input.markAsFinished()
                if once.claim() { cont.resume() }
                return
            case .failed(let error):
                pair.input.markAsFinished()
                if once.claim() { cont.resume(throwing: error) }
                return
            }
        }
    }
}

/// Drives the video pump, pulling compressed frames from a VideoFrameSource.
private func startVideoSourcePump(
    _ source: VideoFrameSource,
    input: AVAssetWriterInput,
    queueLabel: String,
    writer: AVAssetWriter,
    progress: ProgressBar? = nil,
    cont: CheckedContinuation<Void, Error>
) {
    enum PumpStep {
        case appended
        case finished
        case failed(Error)
    }

    let once = OnceGuard()
    input.requestMediaDataWhenReady(on: DispatchQueue(label: queueLabel, qos: .userInitiated)) {
        while input.isReadyForMoreMediaData {
            let step: PumpStep = autoreleasepool {
                guard let buf = source.next() else { return .finished }
                guard input.append(buf) else {
                    return .failed(makeWriterFailure(stage: "Video append failed", writer: writer))
                }
                progress?.increment()
                return .appended
            }
            switch step {
            case .appended:
                continue
            case .finished:
                source.finish()
                input.markAsFinished()
                if once.claim() { cont.resume() }
                return
            case .failed(let error):
                source.finish()
                input.markAsFinished()
                if once.claim() { cont.resume(throwing: error) }
                return
            }
        }
    }
}

// MARK: - MOV Encode Pipeline

/// Encode an AVAsset to MOV using VTCompressionSession (or passthrough).
func encodeMOV(
    asset: AVAsset,
    outputURL: URL,
    quality: String,
    extraAudioURL: URL?,
    audioReplace: Bool,
    colorSpace: SourceColorSpace?,
    fpsInfo: FramerateInfo
) async -> Bool {

    let isPassthrough = (quality == "pass")
    guard !audioReplace || extraAudioURL != nil else {
        print("[Error] --audio-replace requires -aa <audio_file>.")
        return false
    }

    guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
        print("[Error] No video track found."); return false
    }
    let audioTrack     = audioReplace ? nil : (try? await asset.loadTracks(withMediaType: .audio).first)
    let timecodeTrack  = try? await asset.loadTracks(withMediaType: .timecode).first
    let metadataTracks = (try? await asset.loadTracks(withMediaType: .metadata)) ?? []

    var metadataFormatHints: [CMPersistentTrackID: CMMetadataFormatDescription] = [:]
    for metadataTrack in metadataTracks {
        metadataFormatHints[metadataTrack.trackID] = try? await probeTimedMetadataFormatHint(
            asset: asset,
            track: metadataTrack
        )
    }

    // Dimensions
    let (width, height) = await videoSize(from: asset)

    // Extra audio
    var extraAudioReader: AVAssetReader? = nil
    var extraAudioTrack:  AVAssetTrack?  = nil
    if let eaURL = extraAudioURL {
        let eaAsset = AVURLAsset(url: eaURL)
        guard let track = try? await eaAsset.loadTracks(withMediaType: .audio).first else {
            print("[Error] Extra audio file has no audio track: \(eaURL.path)")
            return false
        }
        extraAudioTrack = track
        do {
            extraAudioReader = try AVAssetReader(asset: eaAsset)
        } catch {
            print("[Error] Extra audio reader could not be created: \(error.localizedDescription)")
            return false
        }
    }

    do {
        // ── Reader ──
        let reader = try AVAssetReader(asset: asset)

        let vidSettings: [String: Any]? = isPassthrough ? nil : proResReaderOutputSettings(quality)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: vidSettings)
        videoOut.alwaysCopiesSampleData = false
        if reader.canAdd(videoOut) { reader.add(videoOut) }

        var audioOut: AVAssetReaderTrackOutput? = nil
        if let aTrack = audioTrack {
            audioOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            if reader.canAdd(audioOut!) { reader.add(audioOut!) }
        }

        var tcOut: AVAssetReaderTrackOutput? = nil
        if let tTrack = timecodeTrack {
            tcOut = AVAssetReaderTrackOutput(track: tTrack, outputSettings: nil)
            if reader.canAdd(tcOut!) { reader.add(tcOut!) }
        }

        var metaOutputAdaptors: [AVAssetReaderOutputMetadataAdaptor] = []
        for mTrack in metadataTracks {
            let mOut = AVAssetReaderTrackOutput(track: mTrack, outputSettings: nil)
            mOut.alwaysCopiesSampleData = false
            guard reader.canAdd(mOut) else {
                throw makeMetadataProbeFailure(
                    stage: "Metadata track \(mTrack.trackID) reader output cannot be added"
                )
            }
            reader.add(mOut)
            metaOutputAdaptors.append(
                AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: mOut)
            )
        }

        var extraAudioOut: AVAssetReaderTrackOutput? = nil
        if let eaReader = extraAudioReader, let eaTrack = extraAudioTrack {
            extraAudioOut = AVAssetReaderTrackOutput(track: eaTrack, outputSettings: nil)
            if eaReader.canAdd(extraAudioOut!) { eaReader.add(extraAudioOut!) }
        }

        // ── VT Session (if re-encoding) ──
        var vtSession: ProResSession? = nil
        if !isPassthrough {
            vtSession = try ProResSession(
                width: width, height: height,
                codecType: proResCodecType(quality),
                fpsHint: Int(fpsInfo.fps.rounded()),
                colorSpace: colorSpace)
        }

        // For passthrough, keep VideoFrameSource for the DispatchQueue pump.
        let videoSource: VideoFrameSource? = isPassthrough
            ? VideoFrameSource(output: videoOut, vtSession: nil,
                               fpsNum: fpsInfo.numerator, fpsDen: fpsInfo.denominator)
            : nil

        // ── Writer ──
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        // Video input: nil outputSettings = passthrough of compressed data.
        let vFmtDesc = isPassthrough
            ? (try? await videoTrack.load(.formatDescriptions).first)
            : nil
        let videoIn = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: vFmtDesc)
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        if writer.canAdd(videoIn) { writer.add(videoIn) }

        var sourceTrackInputMap: [CMPersistentTrackID: AVAssetWriterInput] = [
            videoTrack.trackID: videoIn
        ]

        var audioIn: AVAssetWriterInput? = nil
        if audioOut != nil, let aTrack = audioTrack {
            audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            audioIn!.expectsMediaDataInRealTime = false
            if writer.canAdd(audioIn!) {
                writer.add(audioIn!)
                sourceTrackInputMap[aTrack.trackID] = audioIn!
            }
        }

        var extraAudioIn: AVAssetWriterInput? = nil
        if extraAudioOut != nil {
            extraAudioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            extraAudioIn!.expectsMediaDataInRealTime = false
            if writer.canAdd(extraAudioIn!) { writer.add(extraAudioIn!) }
        }

        var tcIn: AVAssetWriterInput? = nil
        if tcOut != nil, let tTrack = timecodeTrack {
            let tcFmt = try? await tTrack.load(.formatDescriptions).first
            tcIn = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil,
                                      sourceFormatHint: tcFmt)
            tcIn!.expectsMediaDataInRealTime = false
            if writer.canAdd(tcIn!) {
                writer.add(tcIn!)
                sourceTrackInputMap[tTrack.trackID] = tcIn!
            }
            let timecodeAssociationType = AVAssetTrack.AssociationType.timecode.rawValue
            if videoIn.canAddTrackAssociation(withTrackOf: tcIn!, type: timecodeAssociationType) {
                videoIn.addTrackAssociation(withTrackOf: tcIn!, type: timecodeAssociationType)
            }
        }

        var metaIns: [AVAssetWriterInput] = []
        var metaInputAdaptors: [AVAssetWriterInputMetadataAdaptor] = []
        for mTrack in metadataTracks {
            guard let mFmt = metadataFormatHints[mTrack.trackID] else {
                throw makeMetadataProbeFailure(
                    stage: "Metadata track \(mTrack.trackID) could not build a boxed metadata format hint"
                )
            }
            let mIn = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                         sourceFormatHint: mFmt)
            mIn.expectsMediaDataInRealTime = false
            await copyTrackLanguageIfPresent(from: mTrack, to: mIn)
            guard writer.canAdd(mIn) else {
                throw makeMetadataProbeFailure(
                    stage: "Metadata track \(mTrack.trackID) writer input cannot be added"
                )
            }
            writer.add(mIn)
            metaIns.append(mIn)
            metaInputAdaptors.append(AVAssetWriterInputMetadataAdaptor(assetWriterInput: mIn))
            sourceTrackInputMap[mTrack.trackID] = mIn
        }

        for (index, mTrack) in metadataTracks.enumerated() where index < metaIns.count {
            await addMetadataReferentAssociations(
                from: mTrack,
                to: metaIns[index],
                inputMap: sourceTrackInputMap
            )
        }

        if #available(macOS 26.0, *) {
            tcIn?.mediaDataLocation = .sparselyInterleavedWithMainMediaData
            metaIns.forEach { $0.mediaDataLocation = .sparselyInterleavedWithMainMediaData }
        }

        // ── Start ──
        guard reader.startReading() else {
            throw makeWriterFailure(stage: "Reader start failed", writer: writer, reader: reader)
        }
        if let extraAudioReader, !extraAudioReader.startReading() {
            throw makeWriterFailure(stage: "Extra audio reader start failed", writer: writer, reader: extraAudioReader)
        }
        guard writer.startWriting() else {
            throw makeWriterFailure(stage: "Writer start failed", writer: writer, reader: reader)
        }
        writer.startSession(atSourceTime: .zero)

        let estFrames = await estimateFrameCount(asset: asset)
        let progress: ProgressBar? = estFrames > 0 ? ProgressBar(total: Int(estFrames)) : nil

        // Build pump pairs for passthrough tracks
        let audioPair = audioIn.flatMap { i in audioOut.map { o in MediaPumpPair(input: i, output: o) } }
        let extraAudioPair = extraAudioIn.flatMap { i in extraAudioOut.map { o in MediaPumpPair(input: i, output: o) } }
        let extraAudioTrackLabel = audioReplace ? "Replacement audio track" : "Injected audio track"
        let tcPair = tcIn.flatMap { i in tcOut.map { o in MediaPumpPair(input: i, output: o) } }
        let metaPairCount = min(metaIns.count, min(metaInputAdaptors.count, metaOutputAdaptors.count))
        let metaPairs = (0..<metaPairCount).map {
            TimedMetadataPumpPair(
                input: metaIns[$0],
                writerAdaptor: metaInputAdaptors[$0],
                readerAdaptor: metaOutputAdaptors[$0]
            )
        }

        // Wrap non-Sendable AVAssetWriterInput for safe transfer into task group
        let videoInRef = SendableRef(videoIn)
        let writerRef = SendableRef(writer)
        let readerRef = SendableRef(reader)
        let extraAudioReaderRef = extraAudioReader.map(SendableRef.init)
        let pipelineCapacity = proResPipelineChannelCapacity(width: width, height: height, quality: quality)
        let failureBox = PipelineFailureBox()

        if isPassthrough {
            // ── Passthrough: DispatchQueue pump coordination (unchanged) ──
            await withTaskGroup(of: Void.self) { group in
                group.addTask(priority: .userInitiated) {
                    do {
                        try await withCheckedThrowingContinuation { cont in
                            startVideoSourcePump(videoSource!, input: videoInRef.value,
                                                 queueLabel: "enc.videoQ",
                                                 writer: writerRef.value,
                                                 progress: progress, cont: cont)
                        }
                    } catch {
                        failureBox.store(error)
                    }
                }
                if let pair = audioPair {
                    group.addTask(priority: .userInitiated) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startPassthroughPump(pair, queueLabel: "enc.audioQ",
                                                     trackLabel: "Audio track",
                                                     writer: writerRef.value,
                                                     reader: readerRef.value,
                                                     cont: cont)
                            }
                        } catch {
                            failureBox.store(error)
                        }
                    }
                }
                if let pair = extraAudioPair {
                    group.addTask(priority: .userInitiated) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startPassthroughPump(pair, queueLabel: "enc.extraAudioQ",
                                                     trackLabel: extraAudioTrackLabel,
                                                     writer: writerRef.value,
                                                     reader: extraAudioReaderRef!.value,
                                                     cont: cont)
                            }
                        } catch {
                            failureBox.store(error)
                        }
                    }
                }
                if let pair = tcPair {
                    group.addTask(priority: .userInitiated) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startPassthroughPump(pair, queueLabel: "enc.tcQ",
                                                     trackLabel: "Timecode track",
                                                     writer: writerRef.value,
                                                     reader: readerRef.value,
                                                     cont: cont)
                            }
                        } catch {
                            failureBox.store(error)
                        }
                    }
                }
                for (idx, pair) in metaPairs.enumerated() {
                    group.addTask(priority: .utility) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startTimedMetadataPump(pair, queueLabel: "enc.metaQ\(idx)",
                                                       trackLabel: "Metadata track \(idx + 1)",
                                                       writer: writerRef.value,
                                                       reader: readerRef.value,
                                                       cont: cont)
                            }
                        } catch {
                            failureBox.store(error)
                        }
                    }
                }
            }
        } else {
            // ── Re-encode: 3-stage async pipeline ──
            //
            // Stage 1 (readerTask):  AVAssetReader → pixelChannel (capacity 4)
            // Stage 2 (encoderTask): pixelChannel → VT submit (async)
            // Stage 2b (drainTask):  VT output → compressedChannel (capacity 4)
            // Stage 3 (writerTask):  compressedChannel → AVAssetWriterInput.append
            //
            // Audio/timecode/metadata pumps run concurrently alongside.

            let pixelChannel = AsyncChannel<SendablePixelBuffer>(capacity: pipelineCapacity)
            let compressedChannel = AsyncChannel<SendableSampleBuffer>(capacity: pipelineCapacity)
            let videoOutRef = SendableRef(videoOut)

            vtSession!.enableAsyncMode(channelCapacity: pipelineCapacity)
            let vtRef = SendableRef(vtSession!)
            let fpsInfoRef = SendableRef(fpsInfo)

            await withTaskGroup(of: Void.self) { group in
                // Stage 1 — Reader
                group.addTask(priority: .userInitiated) {
                    let vOut = videoOutRef.value
                    while true {
                        let wrapped: SendablePixelBuffer? = autoreleasepool {
                            guard let sample = vOut.copyNextSampleBuffer(),
                                  let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
                            return SendablePixelBuffer(buf: pb)
                        }
                        guard let wrapped else { break }
                        await pixelChannel.sendAsync(wrapped)
                    }
                    pixelChannel.finish()
                }

                // Stage 2 — Encoder (VT async)
                group.addTask(priority: .userInitiated) {
                    let vt = vtRef.value
                    if let outCh = vt.outputChannel {
                        for await wrapped in outCh {
                            await compressedChannel.sendAsync(wrapped)
                        }
                    }
                    compressedChannel.finish()
                }

                // Stage 2 — Encoder (VT async submission)
                group.addTask(priority: .userInitiated) {
                    let vt = vtRef.value
                    let fi = fpsInfoRef.value
                    var frameIdx: Int64 = 0
                    for await spb in pixelChannel {
                        let pts = CMTime(value: CMTimeValue(frameIdx) * CMTimeValue(fi.denominator),
                                         timescale: CMTimeScale(fi.numerator))
                        let dur = CMTime(value: CMTimeValue(fi.denominator),
                                         timescale: CMTimeScale(fi.numerator))
                        guard vt.submit(pixelBuffer: spb.buf, pts: pts, duration: dur) else {
                            failureBox.store(makeWriterFailure(stage: "VT submit failed", writer: writerRef.value, reader: readerRef.value))
                            pixelChannel.finish()
                            compressedChannel.finish()
                            vt.flushAsync()
                            return
                        }
                        frameIdx += 1
                    }
                    // Flush VT; the drain task forwards output concurrently.
                    vt.flushAsync()
                }

                // Stage 3 — Writer
                group.addTask(priority: .userInitiated) {
                    let vIn = videoInRef.value
                    for await wrapped in compressedChannel {
                        // Wait until writer input is ready (spin-yield pattern)
                        while !vIn.isReadyForMoreMediaData {
                            await Task.yield()
                        }
                        guard vIn.append(wrapped.buf) else {
                            failureBox.store(makeWriterFailure(stage: "Video append failed", writer: writerRef.value, reader: readerRef.value))
                            compressedChannel.finish()
                            vIn.markAsFinished()
                            return
                        }
                        progress?.increment()
                    }
                    vIn.markAsFinished()
                }

                // Audio / timecode / metadata pumps (unchanged)
                if let pair = audioPair {
                    group.addTask(priority: .userInitiated) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startPassthroughPump(pair, queueLabel: "enc.audioQ",
                                                     trackLabel: "Audio track",
                                                     writer: writerRef.value,
                                                     reader: readerRef.value,
                                                     cont: cont)
                            }
                        } catch {
                            failureBox.store(error)
                        }
                    }
                }
                if let pair = extraAudioPair {
                    group.addTask(priority: .userInitiated) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startPassthroughPump(pair, queueLabel: "enc.extraAudioQ",
                                                     trackLabel: extraAudioTrackLabel,
                                                     writer: writerRef.value,
                                                     reader: extraAudioReaderRef!.value,
                                                     cont: cont)
                            }
                        } catch {
                            failureBox.store(error)
                        }
                    }
                }
                if let pair = tcPair {
                    group.addTask(priority: .utility) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startPassthroughPump(pair, queueLabel: "enc.tcQ",
                                                     trackLabel: "Timecode track",
                                                     writer: writerRef.value,
                                                     reader: readerRef.value,
                                                     cont: cont)
                            }
                        } catch {
                            failureBox.store(error)
                        }
                    }
                }
                for (idx, pair) in metaPairs.enumerated() {
                    group.addTask(priority: .utility) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startTimedMetadataPump(pair, queueLabel: "enc.metaQ\(idx)",
                                                       trackLabel: "Metadata track \(idx + 1)",
                                                       writer: writerRef.value,
                                                       reader: readerRef.value,
                                                       cont: cont)
                            }
                        } catch {
                            failureBox.store(error)
                        }
                    }
                }
            }
            vtSession?.invalidate()
        }

        progress?.finish()
        if let error = failureBox.error {
            throw error
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw makeWriterFailure(stage: "Writer finalize failed", writer: writer, reader: reader)
        }
        if isPassthrough,
           !metadataTracks.isEmpty,
           let sourceURL = (asset as? AVURLAsset)?.url {
            try patchPassthroughMetadataSampleDescriptions(
                sourceURL: sourceURL,
                outputURL: outputURL
            )
        }
        return true

    } catch {
        print("[Error] MOV encode error: \(error.localizedDescription)")
        return false
    }
}

private func timelineFrameCount(from descriptor: TimelineDescriptor) -> Int {
    let fps = descriptor.frameRate.value != 0
        ? Double(descriptor.frameRate.timescale) / Double(descriptor.frameRate.value)
        : 24.0
    return descriptor.clips.reduce(0) { current, clip in
        let end = CMTimeAdd(clip.timelineRange.start, clip.timelineRange.duration)
        let frames = Int(round(CMTimeGetSeconds(end) * fps))
        return max(current, frames)
    }
}

private func timelineAudioPCMSettings(channelCount: Int) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: max(channelCount, 1),
        AVLinearPCMBitDepthKey: 24,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
}

func encodeTimelineMOV(
    composition: AVMutableComposition,
    descriptor: TimelineDescriptor,
    outputURL: URL,
    quality: String
) async -> Bool {
    let requestedQuality = normalizedProResQuality(quality)
    let effectiveQuality = requestedQuality == "pass" ? "422hq" : requestedQuality

    let videoTracks = composition.tracks(withMediaType: .video)
    guard !videoTracks.isEmpty else {
        print("[Error] No video tracks found in timeline composition.")
        return false
    }
    let audioTracks = composition.tracks(withMediaType: .audio)

    let width = max(Int(descriptor.resolution.width.rounded()), 2)
    let height = max(Int(descriptor.resolution.height.rounded()), 2)
    let fps = descriptor.frameRate.value != 0
        ? Double(descriptor.frameRate.timescale) / Double(descriptor.frameRate.value)
        : 24.0
    let fpsHint = max(Int(fps.rounded()), 1)
    let fpsNum = max(descriptor.frameRate.timescale, 1)
    let fpsDen = max(Int32(descriptor.frameRate.value), 1)

    do {
        let vtSession = try ProResSession(
            width: width,
            height: height,
            codecType: proResCodecType(effectiveQuality),
            fpsHint: fpsHint,
            colorSpace: nil)

        let reader = try AVAssetReader(asset: composition)

        let videoComposition = buildTimelineVideoComposition(
            composition: composition,
            descriptor: descriptor)

        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: proResReaderOutputSettings(effectiveQuality))
        videoOut.alwaysCopiesSampleData = false
        videoOut.videoComposition = videoComposition
        if reader.canAdd(videoOut) { reader.add(videoOut) }

        let audioSettings = timelineAudioPCMSettings(channelCount: 2)
        var audioOut: AVAssetReaderAudioMixOutput? = nil
        if !audioTracks.isEmpty {
            let mixed = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: audioSettings)
            mixed.alwaysCopiesSampleData = false
            if reader.canAdd(mixed) {
                reader.add(mixed)
                audioOut = mixed
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoIn.expectsMediaDataInRealTime = false
        if writer.canAdd(videoIn) { writer.add(videoIn) }

        var audioIn: AVAssetWriterInput? = nil
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioIn = input
            }
        }

        guard reader.startReading() else {
            throw makeWriterFailure(stage: "Timeline reader start failed", writer: writer, reader: reader)
        }
        guard writer.startWriting() else {
            throw makeWriterFailure(stage: "Timeline writer start failed", writer: writer, reader: reader)
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(timelineFrameCount(from: descriptor), 1)
        let progress = ProgressBar(total: totalFrames)
        let failureBox = PipelineFailureBox()
        let pipelineCapacity = proResPipelineChannelCapacity(width: width, height: height, quality: effectiveQuality)

        let pixelChannel = AsyncChannel<SendablePixelBuffer>(capacity: pipelineCapacity)
        let compressedChannel = AsyncChannel<SendableSampleBuffer>(capacity: pipelineCapacity)
        vtSession.enableAsyncMode(channelCapacity: pipelineCapacity)
        let videoOutRef = SendableRef(videoOut as AVAssetReaderOutput)
        let vtRef = SendableRef(vtSession)
        let videoInRef = SendableRef(videoIn)
        let writerRef = SendableRef(writer)
        let readerRef = SendableRef(reader)
        let audioPair = audioIn.flatMap { input in
            audioOut.map { output in
                MediaPumpPair(input: input, output: output)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask(priority: .userInitiated) {
                let vOut = videoOutRef.value
                while true {
                    let wrapped: SendablePixelBuffer? = autoreleasepool {
                        guard let sample = vOut.copyNextSampleBuffer(),
                              let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
                        return SendablePixelBuffer(buf: pb)
                    }
                    guard let wrapped else { break }
                    await pixelChannel.sendAsync(wrapped)
                }
                pixelChannel.finish()
            }

            group.addTask(priority: .userInitiated) {
                let vt = vtRef.value
                if let outCh = vt.outputChannel {
                    for await compressed in outCh {
                        await compressedChannel.sendAsync(compressed)
                    }
                }
                compressedChannel.finish()
            }

            group.addTask(priority: .userInitiated) {
                let vt = vtRef.value
                var frameIdx: Int64 = 0
                for await wrapped in pixelChannel {
                    let pts = CMTime(value: CMTimeValue(frameIdx) * CMTimeValue(fpsDen),
                                     timescale: fpsNum)
                    let dur = CMTime(value: CMTimeValue(fpsDen), timescale: fpsNum)
                    guard vt.submit(pixelBuffer: wrapped.buf, pts: pts, duration: dur) else {
                        failureBox.store(makeWriterFailure(stage: "Timeline VT submit failed", writer: writerRef.value, reader: readerRef.value))
                        pixelChannel.finish()
                        compressedChannel.finish()
                        vt.flushAsync()
                        return
                    }
                    frameIdx += 1
                }
                vt.flushAsync()
            }

            group.addTask(priority: .userInitiated) {
                let vIn = videoInRef.value
                for await wrapped in compressedChannel {
                    while !vIn.isReadyForMoreMediaData {
                        await Task.yield()
                    }
                    guard vIn.append(wrapped.buf) else {
                        failureBox.store(makeWriterFailure(stage: "Timeline video append failed", writer: writerRef.value, reader: readerRef.value))
                        compressedChannel.finish()
                        vIn.markAsFinished()
                        return
                    }
                    progress.increment()
                }
                vIn.markAsFinished()
            }

            if let pair = audioPair {
                group.addTask(priority: .userInitiated) {
                    do {
                        try await withCheckedThrowingContinuation { cont in
                            startPassthroughPump(pair, queueLabel: "timeline.audioQ",
                                                 trackLabel: "Timeline audio track",
                                                 writer: writerRef.value,
                                                 reader: readerRef.value,
                                                 cont: cont)
                        }
                    } catch {
                        failureBox.store(error)
                    }
                }
            }
        }

        vtSession.invalidate()
        progress.finish()
        if let error = failureBox.error {
            throw error
        }
        await writer.finishWriting()
        if writer.status != .completed {
            if let error = writer.error {
                print("[Error] Timeline MOV write failed: \(error.localizedDescription)")
            }
            return false
        }
        return true
    } catch {
        print("[Error] Timeline MOV encode error: \(error.localizedDescription)")
        return false
    }
}
