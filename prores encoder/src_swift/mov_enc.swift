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

/// Generated Dolby Vision PHDR timed metadata writer state.
private final class DolbyVisionMetadataPumpPair: @unchecked Sendable {
    let input: AVAssetWriterInput
    let writerAdaptor: AVAssetWriterInputMetadataAdaptor
    let metadata: DolbyVisionMetadataSource
    let fpsInfo: FramerateInfo

    init(
        input: AVAssetWriterInput,
        writerAdaptor: AVAssetWriterInputMetadataAdaptor,
        metadata: DolbyVisionMetadataSource,
        fpsInfo: FramerateInfo
    ) {
        self.input = input
        self.writerAdaptor = writerAdaptor
        self.metadata = metadata
        self.fpsInfo = fpsInfo
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

private final class DolbyVisionFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next(limit: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard value < limit else { return nil }
        let current = value
        value += 1
        return current
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

private enum DolbyVisionMDFStyle {
    case legacy205
    case integrated
}

private enum DolbyVisionColorPrimaries {
    case rec2020
    case p3
}

private struct DolbyVisionVideoColorProfile {
    let primaries: DolbyVisionColorPrimaries
    let label: String

    var integratedColorEncodingXML: String {
        switch primaries {
        case .rec2020:
            return """
      <ColorEncoding>
        <Primaries>
          <Red>0.708 0.292</Red>
          <Green>0.17 0.797</Green>
          <Blue>0.131 0.046</Blue>
        </Primaries>
        <WhitePoint>0.3127 0.329</WhitePoint>
        <PeakBrightness>10000</PeakBrightness>
        <MinimumBrightness>0</MinimumBrightness>
        <Encoding>pq</Encoding>
        <ColorSpace>ycbcr_bt2020</ColorSpace>
        <SignalRange>video</SignalRange>
      </ColorEncoding>
"""
        case .p3:
            return """
      <ColorEncoding>
        <Primaries>
          <Red>0.68 0.32</Red>
          <Green>0.265 0.69</Green>
          <Blue>0.15 0.06</Blue>
        </Primaries>
        <WhitePoint>0.3127 0.329</WhitePoint>
        <PeakBrightness>10000</PeakBrightness>
        <MinimumBrightness>0</MinimumBrightness>
        <Encoding>pq</Encoding>
        <ColorSpace>rgb</ColorSpace>
        <SignalRange>computer</SignalRange>
      </ColorEncoding>
"""
        }
    }

    var legacyColorEncodingXML: String {
        switch primaries {
        case .rec2020:
            return """
  <ColorEncoding>
    <Primaries>
      <Red>0.708,0.292</Red>
      <Green>0.17,0.797</Green>
      <Blue>0.131,0.046</Blue>
    </Primaries>
    <WhitePoint>0.3127,0.329</WhitePoint>
    <MinimumBrightness>0</MinimumBrightness>
    <PeakBrightness>10000</PeakBrightness>
    <Encoding>pq</Encoding>
    <ColorSpace>ycbcr_bt2020</ColorSpace>
    <SignalRange>video</SignalRange>
    <BitDepth>10</BitDepth>
    <ChromaFormat>422</ChromaFormat>
  </ColorEncoding>
"""
        case .p3:
            return """
  <ColorEncoding>
    <Primaries>
      <Red>0.68,0.32</Red>
      <Green>0.265,0.69</Green>
      <Blue>0.15,0.06</Blue>
    </Primaries>
    <WhitePoint>0.3127,0.329</WhitePoint>
    <MinimumBrightness>0</MinimumBrightness>
    <PeakBrightness>10000</PeakBrightness>
    <Encoding>pq</Encoding>
    <ColorSpace>rgb</ColorSpace>
    <SignalRange>computer</SignalRange>
    <BitDepth>10</BitDepth>
    <ChromaFormat>422</ChromaFormat>
  </ColorEncoding>
"""
        }
    }
}

private struct DolbyVisionShot {
    let recordIn: Int
    let duration: Int
    let xml: String

    func contains(frameNumber: Int) -> Bool {
        frameNumber >= recordIn && frameNumber < recordIn + duration
    }
}

private final class DolbyVisionMetadataSource: @unchecked Sendable {
    let version: String
    let versionToken: String
    let metadataKeyValue: String
    let metadataIdentifier: AVMetadataIdentifier
    let trackName: String?
    let frameCount: Int

    private let style: DolbyVisionMDFStyle
    private let schemaURL: String
    private let integratedSchemaURL: String
    private let globalXML: String
    private let shots: [DolbyVisionShot]

    init(xmlURL: URL, videoColorProfile: DolbyVisionVideoColorProfile) throws {
        let data = try Data(contentsOf: xmlURL)
        let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(),
              xmlLocalName(root) == "DolbyLabsMDF" else {
            throw NSError(
                domain: "DolbyVisionMetadata",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Dolby Vision XML root must be DolbyLabsMDF."]
            )
        }

        let parsedVersion = root.attribute(forName: "version")?.stringValue?.trimmedNonEmpty
            ?? textForXPath(".//*[local-name()='Version']", in: root)
        guard let parsedVersion else {
            throw NSError(
                domain: "DolbyVisionMetadata",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Dolby Vision XML has no readable metadata version."]
            )
        }

        version = parsedVersion
        versionToken = parsedVersion.replacingOccurrences(of: ".", with: "_")
        metadataKeyValue = "com.dolby.schemas.dvmd.\(versionToken)"
        metadataIdentifier = AVMetadataIdentifier(rawValue: "mdta/\(metadataKeyValue)")
        schemaURL = "http://www.dolby.com/schemas/dvmd/\(versionToken)"
        integratedSchemaURL = "http://www.dolby.com/schemas/dvmd-int/\(versionToken)"

        if parsedVersion == "2.0.5" || parsedVersion.hasPrefix("2.") {
            style = .legacy205
        } else if parsedVersion.hasPrefix("4.") || parsedVersion.hasPrefix("5.") {
            style = .integrated
        } else {
            throw NSError(
                domain: "DolbyVisionMetadata",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Unsupported Dolby Vision XML version \(parsedVersion). Supported sampled families are 2.x, 4.x, and 5.x."
                ]
            )
        }

        guard let output = firstElementForXPath(".//*[local-name()='Outputs']/*[local-name()='Output']", in: root),
              let track = firstElementForXPath(".//*[local-name()='Video']/*[local-name()='Track']", in: output) else {
            throw NSError(
                domain: "DolbyVisionMetadata",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Dolby Vision XML must contain Outputs/Output/Video/Track."]
            )
        }

        try Self.validateXMLColorEncoding(track: track)
        trackName = track.attribute(forName: "name")?.stringValue?.trimmedNonEmpty
            ?? textForXPath("./*[local-name()='TrackName']", in: track)

        switch style {
        case .legacy205:
            globalXML = try Self.makeLegacyGlobalXML(
                root: root,
                output: output,
                track: track,
                version: parsedVersion,
                videoColorProfile: videoColorProfile)
        case .integrated:
            globalXML = try Self.makeIntegratedGlobalXML(
                root: root,
                output: output,
                track: track,
                version: parsedVersion,
                schemaURL: schemaURL,
                videoColorProfile: videoColorProfile)
        }

        let parsedShots = try Self.makeShots(
            from: track,
            style: style,
            schemaURL: schemaURL)
        guard !parsedShots.isEmpty else {
            throw NSError(
                domain: "DolbyVisionMetadata",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Dolby Vision XML has no Shot metadata."]
            )
        }
        shots = parsedShots
        frameCount = parsedShots.map { $0.recordIn + $0.duration }.max() ?? 0
    }

    func makeFormatDescription() throws -> CMMetadataFormatDescription {
        var desc: CMMetadataFormatDescription?
        let keyData = metadataKeyValue.data(using: .utf8)! as CFData
        let key: [CFString: Any] = [
            kCMMetadataFormatDescriptionKey_Namespace: NSNumber(value: UInt32(0x6d647461)), // 'mdta'
            kCMMetadataFormatDescriptionKey_Value: keyData,
            kCMMetadataFormatDescriptionKey_LocalID: NSNumber(value: UInt32(0x50484452)) // 'PHDR'
        ]
        let status = CMMetadataFormatDescriptionCreateWithKeys(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            keys: [key] as CFArray,
            formatDescriptionOut: &desc)
        guard status == noErr, let desc else {
            throw NSError(
                domain: "DolbyVisionMetadata",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not create Dolby Vision PHDR metadata format description: \(status)"
                ]
            )
        }
        return desc
    }

    func timedMetadataGroup(frameNumber: Int, fpsInfo: FramerateInfo) -> AVTimedMetadataGroup {
        let item = AVMutableMetadataItem()
        item.identifier = metadataIdentifier
        item.dataType = kCMMetadataBaseDataType_RawData as String
        item.value = rawPayload(frameNumber: frameNumber) as NSData

        let start = CMTime(
            value: CMTimeValue(frameNumber) * CMTimeValue(fpsInfo.denominator),
            timescale: CMTimeScale(fpsInfo.numerator))
        let duration = CMTime(
            value: CMTimeValue(fpsInfo.denominator),
            timescale: CMTimeScale(fpsInfo.numerator))
        return AVTimedMetadataGroup(
            items: [item],
            timeRange: CMTimeRange(start: start, duration: duration))
    }

    private func rawPayload(frameNumber: Int) -> Data {
        let xml = sampleXML(frameNumber: frameNumber)
        var payload = Data([0, 0, 0, 0])
        payload.append(xml.data(using: .utf8)!)
        return payload
    }

    private func sampleXML(frameNumber: Int) -> String {
        let shotXML = shots.first(where: { $0.contains(frameNumber: frameNumber) })?.xml ?? shots[0].xml
        switch style {
        case .legacy205:
            return """
<?xml version="1.0" encoding="UTF-8"?>
<DolbyVisionIntegratedWrapper version="\(version)">
\(globalXML)
<DolbyVisionFrameData version="\(version)">
\(shotXML)
  <FrameNumber>\(frameNumber)</FrameNumber>
</DolbyVisionFrameData>
</DolbyVisionIntegratedWrapper>
"""
        case .integrated:
            return """
<?xml version="1.0" encoding="UTF-8"?>
<dvmd-int:DolbyVisionIntegratedData xmlns:dvmd-int="\(integratedSchemaURL)">
  <dvmd-int:Version>\(version)</dvmd-int:Version>
  <dvmd-int:DolbyVisionGlobalData>
\(globalXML)
  </dvmd-int:DolbyVisionGlobalData>
  <dvmd-int:DolbyVisionFrameData>
\(shotXML)
    <dvmd-int:FrameNumber>\(frameNumber)</dvmd-int:FrameNumber>
  </dvmd-int:DolbyVisionFrameData>
</dvmd-int:DolbyVisionIntegratedData>
"""
        }
    }

    private static func validateXMLColorEncoding(track: XMLElement) throws {
        guard let encoding = textForXPath("./*[local-name()='ColorEncoding']/*[local-name()='Encoding']", in: track)?.lowercased(),
              encoding == "pq" else {
            throw NSError(
                domain: "DolbyVisionMetadata",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Dolby Vision XML Track ColorEncoding must use PQ encoding."
                ]
            )
        }

        let red = parseNumberList(textForXPath("./*[local-name()='ColorEncoding']/*[local-name()='Primaries']/*[local-name()='Red']", in: track))
        let green = parseNumberList(textForXPath("./*[local-name()='ColorEncoding']/*[local-name()='Primaries']/*[local-name()='Green']", in: track))
        let blue = parseNumberList(textForXPath("./*[local-name()='ColorEncoding']/*[local-name()='Primaries']/*[local-name()='Blue']", in: track))
        guard matchesPrimaries(red: red, green: green, blue: blue, target: .rec2020)
                || matchesPrimaries(red: red, green: green, blue: blue, target: .p3) else {
            throw NSError(
                domain: "DolbyVisionMetadata",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Dolby Vision XML Track ColorEncoding primaries must be Rec.2020 or P3."
                ]
            )
        }
    }

    private static func makeLegacyGlobalXML(
        root: XMLElement,
        output: XMLElement,
        track: XMLElement,
        version: String,
        videoColorProfile: DolbyVisionVideoColorProfile
    ) throws -> String {
        var parts: [String] = ["<DolbyVisionGlobalData version=\"\(version)\">"]
        if let revision = firstElementForXPath("./*[local-name()='RevisionHistory']", in: root) {
            parts.append(indentedXML(revision, spaces: 2, addingCommentIfMissing: true))
        }
        if let canvas = textForXPath("./*[local-name()='CanvasAspectRatio']", in: output) {
            parts.append("  <CanvasAspectRatio>\(canvas)</CanvasAspectRatio>")
        }
        if let image = textForXPath("./*[local-name()='ImageAspectRatio']", in: output) {
            parts.append("  <ImageAspectRatio>\(image)</ImageAspectRatio>")
        }
        if let rate = firstElementForXPath("./*[local-name()='Rate']", in: track) {
            parts.append(indentedXML(rate, spaces: 2))
        }
        parts.append(videoColorProfile.legacyColorEncodingXML)
        if let level6 = firstElementForXPath("./*[local-name()='Level6']", in: track) {
            parts.append(indentedXML(level6, spaces: 2))
        }
        if let plugin = firstElementForXPath("./*[local-name()='PluginNode']", in: track) {
            parts.append(indentedXML(plugin, spaces: 2))
        }
        parts.append("</DolbyVisionGlobalData>")
        return parts.joined(separator: "\n")
    }

    private static func makeIntegratedGlobalXML(
        root: XMLElement,
        output: XMLElement,
        track: XMLElement,
        version: String,
        schemaURL: String,
        videoColorProfile: DolbyVisionVideoColorProfile
    ) throws -> String {
        var parts: [String] = []
        if let revision = firstElementForXPath(".//*[local-name()='RevisionHistory']", in: root) {
            parts.append(wrapElementWithPrefix(
                source: revision,
                prefixedName: "dvmd-int:RevisionHistory",
                namespaceURL: schemaURL,
                indentSpaces: 4,
                childPrefixNames: ["Revision"]))
        }
        if let composition = textForXPath("./*[local-name()='CompositionName']", in: output)
            ?? output.attribute(forName: "name")?.stringValue?.trimmedNonEmpty {
            parts.append("    <dvmd-int:CompositionName>\(composition)</dvmd-int:CompositionName>")
        }
        if let canvas = textForXPath("./*[local-name()='CanvasAspectRatio']", in: output) {
            parts.append("    <dvmd-int:CanvasAspectRatio>\(canvas)</dvmd-int:CanvasAspectRatio>")
        }
        if let image = textForXPath("./*[local-name()='ImageAspectRatio']", in: output) {
            parts.append("    <dvmd-int:ImageAspectRatio>\(image)</dvmd-int:ImageAspectRatio>")
        }

        let trackChildren = childXML(
            of: track,
            skippingElementNames: ["Shot"],
            replacingColorEncodingWith: videoColorProfile.integratedColorEncodingXML)
        parts.append("""
    <dvmd-int:Track xmlns="\(schemaURL)">
\(indentMultiline(trackChildren, spaces: 6))
    </dvmd-int:Track>
""")
        return parts.joined(separator: "\n")
    }

    private static func makeShots(
        from track: XMLElement,
        style: DolbyVisionMDFStyle,
        schemaURL: String
    ) throws -> [DolbyVisionShot] {
        let shotElements = (try? track.nodes(forXPath: "./*[local-name()='Shot']"))?.compactMap { $0 as? XMLElement } ?? []
        return try shotElements.map { shot in
            guard let durationText = textForXPath("./*[local-name()='Record']/*[local-name()='Duration']", in: shot),
                  let duration = Int(durationText) else {
                throw NSError(
                    domain: "DolbyVisionMetadata",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Each Dolby Vision Shot must have Record/Duration."]
                )
            }
            let recordIn = Int(textForXPath("./*[local-name()='Record']/*[local-name()='In']", in: shot) ?? "0") ?? 0
            let xml: String
            switch style {
            case .legacy205:
                let content = childXML(of: shot, skippingElementNames: ["Source"], replacingColorEncodingWith: nil)
                xml = indentMultiline(content, spaces: 2)
            case .integrated:
                let content = childXML(of: shot, skippingElementNames: [], replacingColorEncodingWith: nil)
                xml = """
    <dvmd-int:Shot xmlns="\(schemaURL)">
\(indentMultiline(content, spaces: 6))
    </dvmd-int:Shot>
"""
            }
            return DolbyVisionShot(recordIn: recordIn, duration: duration, xml: xml)
        }
    }
}

private func readUInt32BE(from data: Data, at offset: Int = 0) -> UInt32 {
    var value: UInt32 = 0
    for byte in data[offset..<(offset + 4)] {
        value = (value << 8) | UInt32(byte)
    }
    return value
}

private func xmlLocalName(_ node: XMLNode) -> String {
    let name = node.name ?? ""
    return name.split(separator: ":").last.map(String.init) ?? name
}

private func firstElementForXPath(_ xPath: String, in node: XMLNode) -> XMLElement? {
    (try? node.nodes(forXPath: xPath))?.first as? XMLElement
}

private func textForXPath(_ xPath: String, in node: XMLNode) -> String? {
    (try? node.nodes(forXPath: xPath))?.first?.stringValue?.trimmedNonEmpty
}

private func parseNumberList(_ text: String?) -> [Double] {
    guard let text else { return [] }
    return text
        .replacingOccurrences(of: ",", with: " ")
        .split { $0 == " " || $0 == "\n" || $0 == "\t" }
        .compactMap { Double($0) }
}

private func matchesPrimaries(
    red: [Double],
    green: [Double],
    blue: [Double],
    target: DolbyVisionColorPrimaries
) -> Bool {
    let expected: ([Double], [Double], [Double])
    switch target {
    case .rec2020:
        expected = ([0.708, 0.292], [0.17, 0.797], [0.131, 0.046])
    case .p3:
        expected = ([0.68, 0.32], [0.265, 0.69], [0.15, 0.06])
    }
    return numbersClose(red, expected.0) && numbersClose(green, expected.1) && numbersClose(blue, expected.2)
}

private func numbersClose(_ lhs: [Double], _ rhs: [Double], tolerance: Double = 0.01) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
}

private func childXML(
    of element: XMLElement,
    skippingElementNames: Set<String>,
    replacingColorEncodingWith colorEncodingXML: String?
) -> String {
    var parts: [String] = []
    for child in element.children ?? [] {
        if child.kind == .element, let childElement = child as? XMLElement {
            let localName = xmlLocalName(childElement)
            if skippingElementNames.contains(localName) { continue }
            if localName == "ColorEncoding", let colorEncodingXML {
                parts.append(colorEncodingXML)
                continue
            }
        }
        parts.append(child.xmlString(options: [.nodePrettyPrint]))
    }
    return parts.joined(separator: "\n")
}

private func indentedXML(
    _ element: XMLElement,
    spaces: Int,
    addingCommentIfMissing: Bool = false
) -> String {
    var xml = element.xmlString(options: [.nodePrettyPrint])
    if addingCommentIfMissing,
       !xml.contains("<Comment"),
       let closeRange = xml.range(of: "</Revision>") {
        xml.insert(contentsOf: "\n      <Comment/>", at: closeRange.lowerBound)
    }
    return indentMultiline(xml, spaces: spaces)
}

private func wrapElementWithPrefix(
    source: XMLElement,
    prefixedName: String,
    namespaceURL: String,
    indentSpaces: Int,
    childPrefixNames: Set<String>
) -> String {
    var children: [String] = []
    for child in source.children ?? [] {
        if child.kind == .element,
           let element = child as? XMLElement,
           childPrefixNames.contains(xmlLocalName(element)) {
            let content = childXML(of: element, skippingElementNames: [], replacingColorEncodingWith: nil)
            children.append("""
<dvmd-int:\(xmlLocalName(element))>
\(indentMultiline(content, spaces: 2))
</dvmd-int:\(xmlLocalName(element))>
""")
        } else {
            children.append(child.xmlString(options: [.nodePrettyPrint]))
        }
    }
    let body = children.joined(separator: "\n")
    return indentMultiline("""
<\(prefixedName) xmlns="\(namespaceURL)">
\(indentMultiline(body, spaces: 2))
</\(prefixedName)>
""", spaces: indentSpaces)
}

private func indentMultiline(_ text: String, spaces: Int) -> String {
    let prefix = String(repeating: " ", count: spaces)
    return text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : prefix + $0 }
        .joined(separator: "\n")
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func readUInt64BE(from data: Data, at offset: Int = 0) -> UInt64 {
    var value: UInt64 = 0
    for byte in data[offset..<(offset + 8)] {
        value = (value << 8) | UInt64(byte)
    }
    return value
}

private func writeUInt32BE(
    _ value: UInt32,
    to handle: FileHandle,
    at offset: UInt64
) throws {
    let bytes = Data([
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ])
    try handle.seek(toOffset: offset)
    handle.write(bytes)
}

private func atomType(in data: Data, at offset: Int) -> String? {
    guard offset + 8 <= data.count else { return nil }
    return String(data: data[(offset + 4)..<(offset + 8)], encoding: .isoLatin1)
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

private func validateDolbyVisionVideoColorProfile(from track: AVAssetTrack) async throws -> DolbyVisionVideoColorProfile {
    guard let fd = try? await track.load(.formatDescriptions).first else {
        throw NSError(
            domain: "DolbyVisionMetadata",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Dolby Vision encode requires readable source video color metadata."
            ]
        )
    }

    let primaries = CMFormatDescriptionGetExtension(
        fd,
        extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
    let transfer = CMFormatDescriptionGetExtension(
        fd,
        extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String

    guard transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) else {
        throw NSError(
            domain: "DolbyVisionMetadata",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Dolby Vision encode refused: source video EOTF must be PQ/SMPTE ST 2084, found \(transfer ?? "missing")."
            ]
        )
    }

    if primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
        return DolbyVisionVideoColorProfile(primaries: .rec2020, label: "Rec.2020 PQ")
    }
    if primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String)
        || primaries == (kCMFormatDescriptionColorPrimaries_DCI_P3 as String) {
        return DolbyVisionVideoColorProfile(primaries: .p3, label: "P3 PQ")
    }

    throw NSError(
        domain: "DolbyVisionMetadata",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey:
            "Dolby Vision encode refused: source video primaries must be Rec.2020 or P3, found \(primaries ?? "missing")."
        ]
    )
}

private func validateHDR10HEVCVideoColorProfile(from track: AVAssetTrack) async throws {
    guard let fd = try? await track.load(.formatDescriptions).first else {
        throw NSError(
            domain: "HEVCEncode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "HEVC HDR10 encode requires readable source video color metadata."
            ]
        )
    }

    let primaries = CMFormatDescriptionGetExtension(
        fd,
        extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
    let transfer = CMFormatDescriptionGetExtension(
        fd,
        extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    let matrix = CMFormatDescriptionGetExtension(
        fd,
        extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String

    guard transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) else {
        throw NSError(
            domain: "HEVCEncode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "HEVC HDR10 encode refused: source video EOTF must be PQ/SMPTE ST 2084, found \(transfer ?? "missing")."
            ]
        )
    }
    let isRec2020 = primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
    let isP3 = primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String)
        || primaries == (kCMFormatDescriptionColorPrimaries_DCI_P3 as String)
    guard isRec2020 || isP3 else {
        throw NSError(
            domain: "HEVCEncode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "HEVC HDR10 encode refused: source video primaries must be Rec.2020 or P3, found \(primaries ?? "missing")."
            ]
        )
    }
    if isRec2020,
       let matrix,
       matrix != (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) {
        throw NSError(
            domain: "HEVCEncode",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "HEVC HDR10 encode refused: source video YCbCr matrix must be BT.2020, found \(matrix)."
            ]
        )
    }
}

private func isDolbyVisionMetadataTrack(_ track: AVAssetTrack) async -> Bool {
    guard let formatDescriptions = try? await track.load(.formatDescriptions) else { return false }
    for fd in formatDescriptions {
        guard CMFormatDescriptionGetMediaType(fd) == kCMMediaType_Metadata,
              CMFormatDescriptionGetMediaSubType(fd) == kCMMetadataFormatType_Boxed,
              let extensions = CMFormatDescriptionGetExtensions(fd) as? [String: Any],
              let keyTable = extensions[kCMFormatDescriptionExtensionKey_MetadataKeyTable as String]
                as? [AnyHashable: Any]
        else {
            continue
        }
        for entry in keyTable.values {
            guard let dict = entry as? [String: Any],
                  let keyData = dict[kCMMetadataFormatDescriptionKey_Value as String] as? Data,
                  let key = String(data: keyData, encoding: .utf8),
                  key.hasPrefix("com.dolby.schemas.dvmd.")
            else {
                continue
            }
            return true
        }
    }
    return false
}

private func patchDolbyVisionMetadataSampleDescription(
    in handle: FileHandle,
    stsd: MOVAtomDescriptor,
    metadataKeyValue: String
) throws {
    let stsdData = try readExactData(
        from: handle,
        at: stsd.offset,
        count: Int(stsd.size))
    guard stsdData.range(of: metadataKeyValue.data(using: .utf8)!) != nil,
          stsdData.range(of: Data([0x50, 0x48, 0x44, 0x52])) != nil else {
        return
    }

    let entryCountOffset = Int(stsd.headerSize) + 4
    guard entryCountOffset + 4 <= stsdData.count,
          readUInt32BE(from: stsdData, at: entryCountOffset) == 1 else {
        return
    }

    let mebxOffset = Int(stsd.headerSize) + 8
    guard mebxOffset + 24 <= stsdData.count,
          atomType(in: stsdData, at: mebxOffset) == "mebx" else {
        return
    }

    let keysOffset = mebxOffset + 16
    guard keysOffset + 8 <= stsdData.count,
          atomType(in: stsdData, at: keysOffset) == "keys" else {
        return
    }

    let keyEntryOffset = keysOffset + 8
    let localIDOffset = keyEntryOffset + 4
    let keyDataOffset = keyEntryOffset + 8
    guard keyDataOffset + 8 <= stsdData.count,
          String(data: stsdData[localIDOffset..<(localIDOffset + 4)], encoding: .isoLatin1) == "PHDR",
          atomType(in: stsdData, at: keyDataOffset) == "keyd",
          Int(readUInt32BE(from: stsdData, at: keyDataOffset)) == stsdData.count - keyDataOffset else {
        return
    }

    let mebxSize = readUInt32BE(from: stsdData, at: mebxOffset)
    let keysSize = readUInt32BE(from: stsdData, at: keysOffset)
    let keyEntrySize = readUInt32BE(from: stsdData, at: keyEntryOffset)
    let correctedMebxSize = UInt32(stsdData.count - mebxOffset)
    let correctedKeysSize = UInt32(stsdData.count - keysOffset)
    let correctedKeyEntrySize = UInt32(stsdData.count - keyEntryOffset)

    guard mebxSize != correctedMebxSize
            || keysSize != correctedKeysSize
            || keyEntrySize != correctedKeyEntrySize else {
        return
    }

    try writeUInt32BE(
        correctedMebxSize,
        to: handle,
        at: stsd.offset + UInt64(mebxOffset))
    try writeUInt32BE(
        correctedKeysSize,
        to: handle,
        at: stsd.offset + UInt64(keysOffset))
    try writeUInt32BE(
        correctedKeyEntrySize,
        to: handle,
        at: stsd.offset + UInt64(keyEntryOffset))
}

private func patchDolbyVisionMetadataTrackAtoms(
    in movieURL: URL,
    metadataKeyValue: String
) throws {
    let handle = try FileHandle(forUpdating: movieURL)
    defer { try? handle.close() }

    let fileSize = try handle.seekToEnd()
    try handle.seek(toOffset: 0)

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
                  let hdlr = try findChildAtom(named: "hdlr", in: mdia, handle: handle),
                  let minf = try findChildAtom(named: "minf", in: mdia, handle: handle),
                  let stbl = try findChildAtom(named: "stbl", in: minf, handle: handle),
                  let stsd = try findChildAtom(named: "stsd", in: stbl, handle: handle)
            else {
                continue
            }

            let handlerTypeData = try readExactData(
                from: handle,
                at: hdlr.offset + hdlr.headerSize + 8,
                count: 4)
            let handlerType = String(data: handlerTypeData, encoding: .isoLatin1) ?? ""
            guard handlerType == "meta" else { continue }

            let stsdData = try readExactData(
                from: handle,
                at: stsd.offset,
                count: Int(stsd.size))
            guard stsdData.range(of: metadataKeyValue.data(using: .utf8)!) != nil,
                  stsdData.range(of: Data([0x50, 0x48, 0x44, 0x52])) != nil else {
                continue
            }

            try patchDolbyVisionMetadataSampleDescription(
                in: handle,
                stsd: stsd,
                metadataKeyValue: metadataKeyValue)

            let nameOffset = hdlr.offset + hdlr.headerSize + 24
            let nameLimit = hdlr.offset + hdlr.size
            guard nameOffset < nameLimit else { continue }
            let capacity = Int(nameLimit - nameOffset)
            let handlerName = Array("PHDR Media Handler".utf8)
            let replacement = [UInt8(handlerName.count)] + handlerName
            guard replacement.count <= capacity else { continue }
            var bytes = Data(replacement)
            if bytes.count < capacity {
                bytes.append(Data(repeating: 0, count: capacity - bytes.count))
            }
            try handle.seek(toOffset: nameOffset)
            handle.write(bytes)
        }
    }
}

private struct MOVSizeFieldPatch {
    let offset: UInt64
    let byteCount: Int
    let newValue: UInt64
}

private func sizeFieldPatch(for atom: MOVAtomDescriptor, growingBy delta: UInt64) -> MOVSizeFieldPatch {
    if atom.headerSize == 16 {
        return MOVSizeFieldPatch(offset: atom.offset + 8, byteCount: 8, newValue: atom.size + delta)
    }
    return MOVSizeFieldPatch(offset: atom.offset, byteCount: 4, newValue: atom.size + delta)
}

private func uint32BEData(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ])
}

private func uint64BEData(_ value: UInt64) -> Data {
    Data([
        UInt8((value >> 56) & 0xff),
        UInt8((value >> 48) & 0xff),
        UInt8((value >> 40) & 0xff),
        UInt8((value >> 32) & 0xff),
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ])
}

private func data(for patch: MOVSizeFieldPatch) throws -> Data {
    switch patch.byteCount {
    case 4:
        guard patch.newValue <= UInt64(UInt32.max) else {
            throw NSError(
                domain: "encodeMOV",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "MOV atom grew beyond 32-bit size field."]
            )
        }
        return uint32BEData(UInt32(patch.newValue))
    case 8:
        return uint64BEData(patch.newValue)
    default:
        throw NSError(
            domain: "encodeMOV",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported MOV size field width \(patch.byteCount)."]
        )
    }
}

private func dolbyVisionHEVCLevel(width: Int, height: Int, fps: Double) -> UInt8 {
    let pixels = width * height
    if pixels >= 3840 * 2160 {
        return fps > 30.0 ? 9 : 7
    }
    if pixels >= 1920 * 1080 {
        return fps > 30.0 ? 6 : 4
    }
    return 3
}

private func makeDolbyVisionHEVCConfigurationBox(
    profile: DolbyVisionHEVCProfile,
    width: Int,
    height: Int,
    fps: Double
) -> Data {
    let dvProfile: UInt8
    let compatibilityID: UInt8
    switch profile {
    case .profile81:
        dvProfile = 8
        compatibilityID = 1
    }
    let dvLevel = dolbyVisionHEVCLevel(width: width, height: height, fps: fps)
    let byte2 = dvProfile << 1 | ((dvLevel >> 5) & 0x01)
    let byte3 = ((dvLevel & 0x1f) << 3) | 0x04 | 0x01
    let byte4 = compatibilityID << 4

    var box = Data()
    box.append(uint32BEData(32))
    box.append(Data("dvvC".utf8))
    box.append(contentsOf: [0x01, 0x00, byte2, byte3, byte4])
    box.append(Data(repeating: 0, count: 19))
    return box
}

private func findHEVCSampleEntryPatchTargets(
    in movieURL: URL
) throws -> (insertOffset: UInt64, sizePatches: [MOVSizeFieldPatch])? {
    let handle = try FileHandle(forReadingFrom: movieURL)
    defer { try? handle.close() }

    let fileSize = try handle.seekToEnd()
    try handle.seek(toOffset: 0)

    var topLevelAtoms: [MOVAtomDescriptor] = []
    var topLevelCursor: UInt64 = 0
    while topLevelCursor < fileSize {
        guard let atom = try readAtomDescriptor(from: handle, at: topLevelCursor, limit: fileSize) else {
            break
        }
        topLevelAtoms.append(atom)
        topLevelCursor += atom.size
    }

    guard let moov = topLevelAtoms.first(where: { $0.type == "moov" }) else {
        return nil
    }
    if topLevelAtoms.contains(where: { $0.type == "mdat" && $0.offset > moov.offset }) {
        throw NSError(
            domain: "encodeMOV",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Cannot insert Dolby Vision dvvC into a front-moov file without rewriting chunk offsets."
            ]
        )
    }

    var moovCursor = moov.offset + moov.headerSize
    let moovLimit = moov.offset + moov.size
    while moovCursor < moovLimit {
        guard let trak = try readAtomDescriptor(from: handle, at: moovCursor, limit: moovLimit) else {
            break
        }
        defer { moovCursor += trak.size }
        guard trak.type == "trak",
              let mdia = try findChildAtom(named: "mdia", in: trak, handle: handle),
              let hdlr = try findChildAtom(named: "hdlr", in: mdia, handle: handle),
              let minf = try findChildAtom(named: "minf", in: mdia, handle: handle),
              let stbl = try findChildAtom(named: "stbl", in: minf, handle: handle),
              let stsd = try findChildAtom(named: "stsd", in: stbl, handle: handle)
        else {
            continue
        }

        let handlerTypeData = try readExactData(
            from: handle,
            at: hdlr.offset + hdlr.headerSize + 8,
            count: 4
        )
        let handlerType = String(data: handlerTypeData, encoding: .isoLatin1) ?? ""
        guard handlerType == "vide" else { continue }

        let entryCountData = try readExactData(
            from: handle,
            at: stsd.offset + stsd.headerSize + 4,
            count: 4
        )
        guard readUInt32BE(from: entryCountData) >= 1 else { continue }

        guard let entry = try readAtomDescriptor(
            from: handle,
            at: stsd.offset + stsd.headerSize + 8,
            limit: stsd.offset + stsd.size
        ), ["hvc1", "hev1", "dvh1", "dvhe"].contains(entry.type) else {
            continue
        }

        let childStart = entry.offset + 86
        let entryLimit = entry.offset + entry.size
        guard childStart < entryLimit else { continue }

        var childCursor = childStart
        var insertOffset: UInt64?
        while childCursor < entryLimit {
            guard let child = try readAtomDescriptor(from: handle, at: childCursor, limit: entryLimit) else {
                break
            }
            if child.type == "dvvC" || child.type == "dvcC" {
                return nil
            }
            if child.type == "hvcC" || child.type == "colr" {
                insertOffset = child.offset + child.size
            }
            childCursor += child.size
        }

        guard let insertOffset else { continue }
        let delta = UInt64(32)
        let patches = [moov, trak, mdia, minf, stbl, stsd, entry].map {
            sizeFieldPatch(for: $0, growingBy: delta)
        }
        return (insertOffset, patches)
    }

    return nil
}

private func copyBytes(
    from input: FileHandle,
    to output: FileHandle,
    count: UInt64
) throws {
    var remaining = count
    let chunkSize = 1024 * 1024
    while remaining > 0 {
        let readSize = Int(min(UInt64(chunkSize), remaining))
        guard let chunk = try input.read(upToCount: readSize), !chunk.isEmpty else {
            throw NSError(
                domain: "encodeMOV",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF while patching MOV."]
            )
        }
        output.write(chunk)
        remaining -= UInt64(chunk.count)
    }
}

private func rewriteMovieFile(
    movieURL: URL,
    insertionOffset: UInt64,
    insertionData: Data,
    sizePatches: [MOVSizeFieldPatch]
) throws {
    let fm = FileManager.default
    let tempURL = movieURL.deletingLastPathComponent()
        .appendingPathComponent(".\(movieURL.lastPathComponent).dvpatch.\(UUID().uuidString).tmp")
    defer { try? fm.removeItem(at: tempURL) }

    let input = try FileHandle(forReadingFrom: movieURL)
    fm.createFile(atPath: tempURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: tempURL)
    defer {
        try? input.close()
        try? output.close()
    }

    let fileSize = try input.seekToEnd()
    try input.seek(toOffset: 0)

    let sortedPatches = try sizePatches
        .map { ($0.offset, try data(for: $0)) }
        .sorted { $0.0 < $1.0 }
    var cursor: UInt64 = 0

    for (offset, patchData) in sortedPatches {
        guard offset >= cursor else { continue }
        try copyBytes(from: input, to: output, count: offset - cursor)
        output.write(patchData)
        try input.seek(toOffset: offset + UInt64(patchData.count))
        cursor = offset + UInt64(patchData.count)
    }

    guard insertionOffset >= cursor else {
        throw NSError(
            domain: "encodeMOV",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid Dolby Vision dvvC insertion offset."]
        )
    }
    try copyBytes(from: input, to: output, count: insertionOffset - cursor)
    output.write(insertionData)
    cursor = insertionOffset
    try input.seek(toOffset: cursor)
    try copyBytes(from: input, to: output, count: fileSize - cursor)

    try output.close()
    try input.close()
    try fm.removeItem(at: movieURL)
    try fm.moveItem(at: tempURL, to: movieURL)
}

private func patchDolbyVisionHEVCConfigurationAtom(
    in movieURL: URL,
    profile: DolbyVisionHEVCProfile,
    width: Int,
    height: Int,
    fps: Double
) throws {
    guard let targets = try findHEVCSampleEntryPatchTargets(in: movieURL) else {
        return
    }
    let box = makeDolbyVisionHEVCConfigurationBox(
        profile: profile,
        width: width,
        height: height,
        fps: fps
    )
    try rewriteMovieFile(
        movieURL: movieURL,
        insertionOffset: targets.insertOffset,
        insertionData: box,
        sizePatches: targets.sizePatches
    )
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

private func startDolbyVisionMetadataPump(
    _ pair: DolbyVisionMetadataPumpPair,
    queueLabel: String,
    writer: AVAssetWriter,
    cont: CheckedContinuation<Void, Error>
) {
    enum PumpStep {
        case appended
        case finished
        case failed(Error)
    }

    let once = OnceGuard()
    let counter = DolbyVisionFrameCounter()
    pair.input.requestMediaDataWhenReady(on: DispatchQueue(label: queueLabel, qos: .utility)) {
        while pair.input.isReadyForMoreMediaData {
            let step: PumpStep = autoreleasepool {
                guard let frameNumber = counter.next(limit: pair.metadata.frameCount) else { return .finished }
                let group = pair.metadata.timedMetadataGroup(
                    frameNumber: frameNumber,
                    fpsInfo: pair.fpsInfo)
                guard pair.writerAdaptor.append(group) else {
                    return .failed(makeWriterFailure(
                        stage: "Dolby Vision metadata append failed",
                        writer: writer))
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
    dolbyVisionXMLURL: URL?,
    hevcOptions: HEVCEncodeOptions?,
    colorSpace: SourceColorSpace?,
    fpsInfo: FramerateInfo
) async -> Bool {

    let isPassthrough = (quality == "pass")
    let isHEVC = isHEVCQuality(quality)
    guard !audioReplace || extraAudioURL != nil else {
        print("[Error] --audio-replace requires -aa <audio_file>.")
        return false
    }

    guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
        print("[Error] No video track found."); return false
    }
    let audioTrack     = audioReplace ? nil : (try? await asset.loadTracks(withMediaType: .audio).first)
    let timecodeTrack  = try? await asset.loadTracks(withMediaType: .timecode).first
    let sourceMetadataTracks = (try? await asset.loadTracks(withMediaType: .metadata)) ?? []
    let estimatedFrames = await estimateFrameCount(asset: asset)

    let dolbyVisionMetadata: DolbyVisionMetadataSource?
    let dolbyVisionRPUProvider: DolbyVisionRPUProvider?
    do {
        if isHEVC {
            guard hevcOptions != nil else {
                throw NSError(
                    domain: "HEVCEncode",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "HEVC encode requires --bitrate / -b options."]
                )
            }
            try await validateHDR10HEVCVideoColorProfile(from: videoTrack)
        }
        if let dolbyVisionXMLURL {
            let videoColorProfile = try await validateDolbyVisionVideoColorProfile(from: videoTrack)
            let metadata = try DolbyVisionMetadataSource(
                xmlURL: dolbyVisionXMLURL,
                videoColorProfile: videoColorProfile)
            if estimatedFrames > 0, metadata.frameCount != Int(estimatedFrames) {
                throw NSError(
                    domain: "DolbyVisionMetadata",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Dolby Vision XML duration is \(metadata.frameCount) frames, but source video is estimated at \(estimatedFrames) frames."
                    ]
                )
            }
            if isHEVC {
                guard let profile = hevcOptions?.dvProfile else {
                    throw NSError(
                        domain: "DolbyVisionRPU",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "HEVC Dolby Vision encode requires --dv-profile 81 / -dp 81."
                        ]
                    )
                }
                print("[DoVi] Generating Profile \(profile.displayName) RPU from XML \(metadata.version) (\(metadata.frameCount) frames) while VT encodes HEVC.")
                dolbyVisionMetadata = nil
                dolbyVisionRPUProvider = DolbyVisionRPUProvider(
                    xmlURL: dolbyVisionXMLURL,
                    profile: profile,
                    expectedFrameCount: estimatedFrames)
            } else {
                print("[DoVi] Embedding metadata \(metadata.version) as \(metadata.metadataKeyValue) (\(metadata.frameCount) frames, \(videoColorProfile.label))")
                dolbyVisionMetadata = metadata
                dolbyVisionRPUProvider = nil
            }
        } else {
            dolbyVisionMetadata = nil
            dolbyVisionRPUProvider = nil
        }
    } catch {
        print("[Error] \(error.localizedDescription)")
        return false
    }

    var metadataTracks: [AVAssetTrack] = []
    if dolbyVisionMetadata != nil || dolbyVisionRPUProvider != nil {
        for track in sourceMetadataTracks {
            if await isDolbyVisionMetadataTrack(track) {
                print("[DoVi] Replacing source Dolby Vision metadata track \(track.trackID).")
            } else {
                metadataTracks.append(track)
            }
        }
    } else {
        metadataTracks = sourceMetadataTracks
    }

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
                colorSpace: colorSpace,
                hevcOptions: hevcOptions)
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

        var dolbyVisionPair: DolbyVisionMetadataPumpPair? = nil
        if let dolbyVisionMetadata {
            let doviFmt = try dolbyVisionMetadata.makeFormatDescription()
            let doviIn = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: doviFmt)
            doviIn.expectsMediaDataInRealTime = false
            doviIn.languageCode = "eng"
            if let trackName = dolbyVisionMetadata.trackName {
                let title = AVMutableMetadataItem()
                title.identifier = .commonIdentifierTitle
                title.value = trackName as NSString
                doviIn.metadata = [title]
            }
            guard writer.canAdd(doviIn) else {
                throw makeMetadataProbeFailure(
                    stage: "Dolby Vision metadata writer input cannot be added"
                )
            }
            writer.add(doviIn)
            let metadataReferentType = AVAssetTrack.AssociationType.metadataReferent.rawValue
            if doviIn.canAddTrackAssociation(withTrackOf: videoIn, type: metadataReferentType) {
                doviIn.addTrackAssociation(withTrackOf: videoIn, type: metadataReferentType)
            }
            dolbyVisionPair = DolbyVisionMetadataPumpPair(
                input: doviIn,
                writerAdaptor: AVAssetWriterInputMetadataAdaptor(assetWriterInput: doviIn),
                metadata: dolbyVisionMetadata,
                fpsInfo: fpsInfo)
            if #available(macOS 26.0, *) {
                doviIn.mediaDataLocation = .sparselyInterleavedWithMainMediaData
            }
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

        let estFrames = estimatedFrames
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
                if let pair = dolbyVisionPair {
                    group.addTask(priority: .utility) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startDolbyVisionMetadataPump(pair,
                                                             queueLabel: "enc.doviQ",
                                                             writer: writerRef.value,
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
            let rpuProviderRef = dolbyVisionRPUProvider.map(SendableRef.init)

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
                    var frameIndex: Int64 = 0
                    for await wrapped in compressedChannel {
                        let sampleToAppend: CMSampleBuffer
                        if let rpuProvider = rpuProviderRef?.value {
                            do {
                                let rpu = try await rpuProvider.rpu(forFrame: frameIndex)
                                sampleToAppend = try sampleBufferByInjectingHEVCRPU(
                                    wrapped.buf,
                                    rpuNALUnit: rpu
                                )
                            } catch {
                                failureBox.store(error)
                                compressedChannel.finish()
                                vIn.markAsFinished()
                                return
                            }
                        } else {
                            sampleToAppend = wrapped.buf
                        }

                        // Wait until writer input is ready (spin-yield pattern)
                        while !vIn.isReadyForMoreMediaData {
                            await Task.yield()
                        }
                        guard vIn.append(sampleToAppend) else {
                            failureBox.store(makeWriterFailure(stage: "Video append failed", writer: writerRef.value, reader: readerRef.value))
                            compressedChannel.finish()
                            vIn.markAsFinished()
                            return
                        }
                        progress?.increment()
                        frameIndex += 1
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
                if let pair = dolbyVisionPair {
                    group.addTask(priority: .utility) {
                        do {
                            try await withCheckedThrowingContinuation { cont in
                                startDolbyVisionMetadataPump(pair,
                                                             queueLabel: "enc.doviQ",
                                                             writer: writerRef.value,
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
        if let dolbyVisionMetadata {
            try patchDolbyVisionMetadataTrackAtoms(
                in: outputURL,
                metadataKeyValue: dolbyVisionMetadata.metadataKeyValue)
        }
        if let profile = hevcOptions?.dvProfile,
           dolbyVisionRPUProvider != nil {
            let rpuCount = try await dolbyVisionRPUProvider?.waitForCompletion() ?? 0
            print("[DoVi] Injected \(rpuCount) RPU frames; patching HEVC sample description with dvvC.")
            try patchDolbyVisionHEVCConfigurationAtom(
                in: outputURL,
                profile: profile,
                width: width,
                height: height,
                fps: fpsInfo.fps
            )
        }
        if isPassthrough,
           dolbyVisionMetadata == nil,
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
