// XMLTimelineParser.swift
// Parses supported XML timeline roots.
// into a unified TimelineDescriptor for use by CompositionBuilder.

import Foundation
import AVFoundation
import CoreMedia

// MARK: - XMLElement XPath helper
// Foundation's XMLElement provides elements(forName:) for direct children only.
// This extension adds a non-throwing elements(forXPath:) wrapper around
// XMLNode.nodes(forXPath:throws:) that returns [XMLElement].
private extension XMLNode {
    func elements(forXPath xPath: String) -> [XMLElement] {
        (try? nodes(forXPath: xPath))?.compactMap { $0 as? XMLElement } ?? []
    }
}

// MARK: - Data Model

public struct ClipDescriptor {
    public let sourceURL:      URL
    public let timelineRange:  CMTimeRange   // position + duration on output timeline
    public let sourceRange:    CMTimeRange   // in/out points within the source asset
    public let trackIndex:     Int           // 0 = primary video, 1 = primary audio, 2+ = extra audio lanes
    public let mediaType:      AVMediaType
}

public struct TimelineDescriptor {
    public let name:           String
    public let frameRate:      CMTime         // as a rational fraction (value/timescale = 1/fps)
    public let isDropFrame:    Bool
    public let startTimecode:  String         // HH:MM:SS:FF or HH:MM:SS;FF
    public let resolution:     CGSize
    public let clips:          [ClipDescriptor]
}

// MARK: - Parser

public final class XMLTimelineParser: NSObject {

    // Cache for compound clip / media element parsing to avoid infinite recursion
    private var parsedMediaCache: [String: [ClipDescriptor]] = [:]

    // Shared resource table built from the XML header
    private var assetsByID:  [String: String] = [:]   // id → src URL string
    private var formatsByID: [String: FCPXMLFormat] = [:]
    private var mediasByID:  [String: XMLElement] = [:]
    private var fcp7FilePathsByID: [String: String] = [:]

    private struct FCPXMLFormat {
        var frameDuration: CMTime
        var width: Int
        var height: Int
        var colorSpace: String?
    }

    // MARK: - Public entry point

    public func parse(url: URL) -> TimelineDescriptor? {
        parsedMediaCache.removeAll()
        assetsByID.removeAll()
        formatsByID.removeAll()
        mediasByID.removeAll()
        fcp7FilePathsByID.removeAll()

        guard let data = try? Data(contentsOf: url),
              let doc  = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) else {
            print("[XMLParser] Cannot read XML file at \(url.path)")
            return nil
        }
        let root = doc.rootElement()
        switch root?.name {
        case "fcpxml":  return parseFCPXML(root: root!, baseURL: url)
        case "xmeml":   return parseFCP7XML(root: root!, baseURL: url)
        default:
            print("[XMLParser] Unknown XML root element '\(root?.name ?? "<nil>")'")
            return nil
        }
    }

    // MARK: - XML timeline parsing

    private func parseFCPXML(root: XMLElement, baseURL: URL) -> TimelineDescriptor? {
        // 1. Build resource tables
        buildResourceTables(root: root, baseURL: baseURL)

        // 2. Navigate to sequence
        guard let sequence = root.elements(
                forXPath: "library/event/project/sequence").first
                ?? root.elements(forXPath: ".//sequence").first else {
            print("[XMLParser] No <sequence> found in XML timeline.")
            return nil
        }

        // 3. Read sequence parameters
        let seqName = root.elements(forXPath: "library/event/project").first?
            .attribute(forName: "name")?.stringValue
            ?? root.elements(forXPath: "library/event/project").first?
            .elements(forXPath: "name").first?.stringValue
            ?? ""

        let formatRef  = sequence.attribute(forName: "format")?.stringValue ?? ""
        let fmt        = formatsByID[formatRef]
        let frameDur   = fmt?.frameDuration ?? CMTime(value: 1001, timescale: 24000)
        let resolution = CGSize(width: fmt?.width ?? 1920, height: fmt?.height ?? 1080)
        let tcStart    = sequence.attribute(forName: "tcStart")?.stringValue ?? "0s"
        let tcString   = timecodeStringFromFCPXMLValue(tcStart, frameRate: frameDur)

        // 4. Parse spine
        guard let spine = sequence.elements(forXPath: "spine").first else {
            print("[XMLParser] No <spine> found in XML timeline.")
            return nil
        }

        var clips: [ClipDescriptor] = []
        parseFCPXMLSpine(spine, outputOffset: .zero, clips: &clips)

        // 5. Determine drop-frame from frameDuration
        let fps = frameDur.timescale > 0
            ? Double(frameDur.timescale) / Double(frameDur.value)
            : 24.0
        let isDF = abs(fps - 29.97) < 0.05 || abs(fps - 59.94) < 0.05

        return TimelineDescriptor(
            name:          seqName,
            frameRate:     frameDur,
            isDropFrame:   isDF,
            startTimecode: tcString,
            resolution:    resolution,
            clips:         clips)
    }

    private func buildResourceTables(root: XMLElement, baseURL: URL) {
        // <asset id="r1" src="file:///..." />
        for asset in root.elements(forXPath: ".//resources/asset") {
            guard let assetID = asset.attribute(forName: "id")?.stringValue else { continue }
            if let src = asset.attribute(forName: "src")?.stringValue {
                assetsByID[assetID] = resolveFilePath(src, baseURL: baseURL)
            }
        }
        // <format id="r2" frameDuration="..." width="..." height="..." />
        for fmt in root.elements(forXPath: ".//resources/format") {
            guard let fmtID = fmt.attribute(forName: "id")?.stringValue else { continue }
            let fd = fmt.attribute(forName: "frameDuration")?.stringValue ?? "1001/24000s"
            formatsByID[fmtID] = FCPXMLFormat(
                frameDuration: parseFCPXMLTime(fd),
                width:  Int(fmt.attribute(forName: "width")?.stringValue  ?? "1920") ?? 1920,
                height: Int(fmt.attribute(forName: "height")?.stringValue ?? "1080") ?? 1080,
                colorSpace: fmt.attribute(forName: "colorSpace")?.stringValue)
        }
        // <media id="r3" ...><sequence>...</sequence></media>
        for media in root.elements(forXPath: ".//resources/media") {
            guard let mediaID = media.attribute(forName: "id")?.stringValue else { continue }
            mediasByID[mediaID] = media
        }
    }

    // Parse all children of <spine>
    private func parseFCPXMLSpine(
        _ spine: XMLElement,
        outputOffset: CMTime,
        clips: inout [ClipDescriptor]
    ) {
        var cursor = outputOffset
        guard let children = spine.children else { return }
        var i = 0
        while i < children.count {
            guard let elem = children[i] as? XMLElement else { i += 1; continue }

            // Peek ahead for <transition> elements to compute overlap
            let nextElem = (i + 1 < children.count) ? children[i + 1] as? XMLElement : nil
            let prevElem = (i - 1 >= 0) ? children[i - 1] as? XMLElement : nil

            switch elem.name {
            case "asset-clip":
                if let clipOffset = elem.attribute(forName: "offset")?.stringValue {
                    cursor = parseFCPXMLTime(clipOffset)
                }
                let rawDur = parseFCPXMLTime(elem.attribute(forName: "duration")?.stringValue ?? "0s")
                // Trim duration if adjacent transitions exist
                var dur = rawDur
                if let pre = prevElem, pre.name == "transition" {
                    let td = parseFCPXMLTime(pre.attribute(forName: "duration")?.stringValue ?? "0s")
                    dur = CMTimeSubtract(dur, CMTimeMultiplyByFloat64(td, multiplier: 0.5))
                }
                if let nxt = nextElem, nxt.name == "transition" {
                    let td = parseFCPXMLTime(nxt.attribute(forName: "duration")?.stringValue ?? "0s")
                    dur = CMTimeSubtract(dur, CMTimeMultiplyByFloat64(td, multiplier: 0.5))
                }

                let ref    = elem.attribute(forName: "ref")?.stringValue ?? ""
                let start  = parseFCPXMLTime(elem.attribute(forName: "start")?.stringValue ?? "0s")
                let lane   = Int(elem.attribute(forName: "lane")?.stringValue ?? "0") ?? 0

                if let srcPath = assetsByID[ref] {
                    let srcURL  = URL(fileURLWithPath: srcPath)
                    let tlRange = CMTimeRange(start: cursor, duration: dur)
                    let srcRange = CMTimeRange(start: start, duration: dur)
                    let (vIdx, aIdx) = trackIndices(forLane: lane)
                    clips.append(ClipDescriptor(sourceURL: srcURL, timelineRange: tlRange,
                        sourceRange: srcRange, trackIndex: vIdx, mediaType: .video))
                    clips.append(ClipDescriptor(sourceURL: srcURL, timelineRange: tlRange,
                        sourceRange: srcRange, trackIndex: aIdx, mediaType: .audio))
                }
                cursor = CMTimeAdd(cursor, dur)

            case "clip":
                if let clipOffset = elem.attribute(forName: "offset")?.stringValue {
                    cursor = parseFCPXMLTime(clipOffset)
                }
                let dur  = parseFCPXMLTime(elem.attribute(forName: "duration")?.stringValue ?? "0s")
                let lane = Int(elem.attribute(forName: "lane")?.stringValue ?? "0") ?? 0
                parseClipElement(elem, timelineStart: cursor, dur: dur, lane: lane, clips: &clips)
                cursor = CMTimeAdd(cursor, dur)

            case "ref-clip":
                if let clipOffset = elem.attribute(forName: "offset")?.stringValue {
                    cursor = parseFCPXMLTime(clipOffset)
                }
                let dur = parseFCPXMLTime(elem.attribute(forName: "duration")?.stringValue ?? "0s")
                let ref = elem.attribute(forName: "ref")?.stringValue ?? ""
                parseRefClip(ref: ref, timelineStart: cursor, duration: dur, clips: &clips)
                cursor = CMTimeAdd(cursor, dur)

            case "sync-clip":
                if let clipOffset = elem.attribute(forName: "offset")?.stringValue {
                    cursor = parseFCPXMLTime(clipOffset)
                }
                let dur = parseFCPXMLTime(elem.attribute(forName: "duration")?.stringValue ?? "0s")
                parseSyncClip(elem, timelineStart: cursor, duration: dur, clips: &clips)
                cursor = CMTimeAdd(cursor, dur)

            case "gap":
                let dur = parseFCPXMLTime(elem.attribute(forName: "duration")?.stringValue ?? "0s")
                cursor = CMTimeAdd(cursor, dur)

            case "transition":
                break  // Handled implicitly by adjacent clip trimming

            default:
                break
            }
            i += 1
        }
    }

    private func parseClipElement(
        _ elem: XMLElement,
        timelineStart: CMTime,
        dur: CMTime,
        lane: Int,
        clips: inout [ClipDescriptor]
    ) {
        let (vIdx, aIdx) = trackIndices(forLane: lane)
        // Try video child
        for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
            if child.name == "video" || child.name == "audio" {
                let ref   = child.attribute(forName: "ref")?.stringValue ?? ""
                let start = parseFCPXMLTime(child.attribute(forName: "offset")?.stringValue ?? "0s")
                if let srcPath = assetsByID[ref] {
                    let mt: AVMediaType = child.name == "video" ? .video : .audio
                    let ti  = mt == .video ? vIdx : aIdx
                    let tlR = CMTimeRange(start: timelineStart, duration: dur)
                    let srR = CMTimeRange(start: start, duration: dur)
                    clips.append(ClipDescriptor(sourceURL: URL(fileURLWithPath: srcPath),
                        timelineRange: tlR, sourceRange: srR, trackIndex: ti, mediaType: mt))
                }
            }
        }
    }

    private func parseRefClip(
        ref: String,
        timelineStart: CMTime,
        duration: CMTime,
        clips: inout [ClipDescriptor]
    ) {
        guard !ref.isEmpty else { return }
        // Check cache first to prevent circular references
        if let cached = parsedMediaCache[ref] {
            let offsetted = offsetClips(cached, by: timelineStart)
            clips.append(contentsOf: offsetted)
            return
        }
        // Mark as being parsed (empty sentinel) to prevent recursion
        parsedMediaCache[ref] = []

        guard let media = mediasByID[ref],
              let seq   = media.elements(forXPath: "sequence").first,
              let spine = seq.elements(forXPath: "spine").first else {
            return
        }

        var subClips: [ClipDescriptor] = []
        parseFCPXMLSpine(spine, outputOffset: .zero, clips: &subClips)
        // Trim to the requested duration
        let trimmed = subClips.filter { CMTimeRangeContainsTime($0.timelineRange, time: .zero) ||
            $0.timelineRange.start < duration }
        parsedMediaCache[ref] = trimmed
        let offsetted = offsetClips(trimmed, by: timelineStart)
        clips.append(contentsOf: offsetted)
    }

    private func parseSyncClip(
        _ elem: XMLElement,
        timelineStart: CMTime,
        duration: CMTime,
        clips: inout [ClipDescriptor]
    ) {
        for child in (elem.children ?? []).compactMap({ $0 as? XMLElement }) {
            guard child.name == "asset-clip" || child.name == "clip" else { continue }
            let lane  = Int(child.attribute(forName: "lane")?.stringValue ?? "0") ?? 0
            let start = parseFCPXMLTime(child.attribute(forName: "start")?.stringValue ?? "0s")
            let dur = child.attribute(forName: "duration")?.stringValue
                .map { parseFCPXMLTime($0) } ?? duration
            let ref   = child.attribute(forName: "ref")?.stringValue ?? ""
            if let srcPath = assetsByID[ref] {
                let (vIdx, aIdx) = trackIndices(forLane: lane)
                let tlR = CMTimeRange(start: timelineStart, duration: dur)
                let srR = CMTimeRange(start: start, duration: dur)
                let url = URL(fileURLWithPath: srcPath)
                clips.append(ClipDescriptor(sourceURL: url, timelineRange: tlR,
                    sourceRange: srR, trackIndex: vIdx, mediaType: .video))
                clips.append(ClipDescriptor(sourceURL: url, timelineRange: tlR,
                    sourceRange: srR, trackIndex: aIdx, mediaType: .audio))
            }
        }
    }

    // MARK: - Legacy XML parsing

    private func parseFCP7XML(root: XMLElement, baseURL: URL) -> TimelineDescriptor? {
        guard let sequence = root.elements(forXPath: ".//sequence").first else {
            print("[XMLParser] No <sequence> found in XML timeline.")
            return nil
        }
        buildFCP7FileTable(root: root, baseURL: baseURL)
        let seqName = sequence.elements(forXPath: "name").first?.stringValue ?? ""

        // Rate
        let timebase = Int(sequence.elements(forXPath: "rate/timebase").first?.stringValue ?? "25") ?? 25
        let isNTSC   = sequence.elements(forXPath: "rate/ntsc").first?.stringValue?.uppercased() == "TRUE"
        let (fpNum, fpDen) = isNTSC
            ? (timebase * 1000, 1001)
            : (timebase, 1)
        let frameDur = CMTime(value: CMTimeValue(fpDen), timescale: CMTimeScale(fpNum))

        // Timecode
        let tcStr = sequence.elements(forXPath: "timecode/string").first?.stringValue ?? "00:00:00:00"

        // Resolution
        let width  = Int(sequence.elements(forXPath: "media/video/format/samplecharacteristics/width").first?.stringValue  ?? "1920") ?? 1920
        let height = Int(sequence.elements(forXPath: "media/video/format/samplecharacteristics/height").first?.stringValue ?? "1080") ?? 1080

        var clips: [ClipDescriptor] = []

        // Video tracks
        let videoTracks = sequence.elements(forXPath: "media/video/track")
        for (trackIdx, track) in videoTracks.enumerated() {
            for clipitem in track.elements(forXPath: "clipitem") {
                clips.append(contentsOf: parseFCP7ClipItems(
                    clipitem,
                    trackIndex: trackIdx,
                    mediaType: .video,
                    timebase: timebase,
                    isNTSC: isNTSC,
                    parentSeq: sequence,
                    baseURL: baseURL))
            }
        }
        // Audio tracks
        let audioTracks = sequence.elements(forXPath: "media/audio/track")
        for (trackIdx, track) in audioTracks.enumerated() {
            for clipitem in track.elements(forXPath: "clipitem") {
                clips.append(contentsOf: parseFCP7ClipItems(
                    clipitem,
                    trackIndex: trackIdx + 1,
                    mediaType: .audio,
                    timebase: timebase,
                    isNTSC: isNTSC,
                    parentSeq: sequence,
                    baseURL: baseURL))
            }
        }

        let isDF = isNTSC && (timebase == 30 || timebase == 60)
        return TimelineDescriptor(
            name:          seqName,
            frameRate:     frameDur,
            isDropFrame:   isDF,
            startTimecode: tcStr,
            resolution:    CGSize(width: width, height: height),
            clips:         clips)
    }

    private func parseFCP7ClipItems(
        _ clipitem: XMLElement,
        trackIndex: Int,
        mediaType: AVMediaType,
        timebase: Int,
        isNTSC: Bool,
        parentSeq: XMLElement,
        baseURL: URL
    ) -> [ClipDescriptor] {
        let inFrame  = Int(clipitem.elements(forXPath: "in").first?.stringValue  ?? "-1") ?? -1
        let outFrame = Int(clipitem.elements(forXPath: "out").first?.stringValue ?? "-1") ?? -1
        let startF   = Int(clipitem.elements(forXPath: "start").first?.stringValue ?? "-1") ?? -1
        let endF     = Int(clipitem.elements(forXPath: "end").first?.stringValue   ?? "-1") ?? -1

        guard inFrame >= 0, outFrame > inFrame, startF >= 0, endF > startF else { return [] }

        func frameToTime(_ f: Int) -> CMTime {
            let v  = CMTimeValue(f) * CMTimeValue(isNTSC ? 1001 : 1)
            let ts = CMTimeScale(timebase * (isNTSC ? 1000 : 1))
            return CMTime(value: v, timescale: ts)
        }

        let parentTimelineRange = CMTimeRange(
            start: frameToTime(startF),
            duration: frameToTime(endF - startF))
        let parentSourceRange = CMTimeRange(
            start: frameToTime(inFrame),
            duration: frameToTime(outFrame - inFrame))

        // Check for nested inline sequence
        if let nestedSeq = clipitem.elements(forXPath: "sequence").first {
            var subClips: [ClipDescriptor] = []
            let nestedTracks = nestedSeq.elements(
                forXPath: mediaType == .video ? "media/video/track" : "media/audio/track")
            for (ti, track) in nestedTracks.enumerated() {
                for ci in track.elements(forXPath: "clipitem") {
                    subClips.append(contentsOf: parseFCP7ClipItems(
                        ci,
                        trackIndex: trackIndex + ti,
                        mediaType: mediaType,
                        timebase: timebase,
                        isNTSC: isNTSC,
                        parentSeq: nestedSeq,
                        baseURL: baseURL))
                }
            }
            return trimNestedSubClips(
                subClips,
                parentTimelineRange: parentTimelineRange,
                parentSourceRange: parentSourceRange)
        }

        let inlinePath = clipitem.elements(forXPath: "file/pathurl").first?.stringValue
        let referencedFileID = clipitem.elements(forXPath: "file").first?
            .attribute(forName: "id")?.stringValue
        guard let pathURL = inlinePath ?? referencedFileID.flatMap({ fcp7FilePathsByID[$0] }) else {
            return []
        }
        let srcPath = normalizeMediaPath(pathURL, baseURL: baseURL)
        let srcURL = URL(fileURLWithPath: srcPath)

        return [ClipDescriptor(
            sourceURL:     srcURL,
            timelineRange: parentTimelineRange,
            sourceRange:   parentSourceRange,
            trackIndex:    trackIndex,
            mediaType:     mediaType)]
    }

    private func trimNestedSubClips(
        _ subClips: [ClipDescriptor],
        parentTimelineRange: CMTimeRange,
        parentSourceRange: CMTimeRange
    ) -> [ClipDescriptor] {
        subClips.compactMap { subClip in
            let intersection = CMTimeRangeGetIntersection(subClip.timelineRange, otherRange: parentSourceRange)
            guard intersection.duration > .zero else {
                return nil
            }

            let trimIntoClip = CMTimeSubtract(intersection.start, subClip.timelineRange.start)
            let timelineOffset = CMTimeSubtract(intersection.start, parentSourceRange.start)
            let newTimelineStart = CMTimeAdd(parentTimelineRange.start, timelineOffset)
            let newSourceStart = CMTimeAdd(subClip.sourceRange.start, trimIntoClip)

            return ClipDescriptor(
                sourceURL: subClip.sourceURL,
                timelineRange: CMTimeRange(start: newTimelineStart, duration: intersection.duration),
                sourceRange: CMTimeRange(start: newSourceStart, duration: intersection.duration),
                trackIndex: subClip.trackIndex,
                mediaType: subClip.mediaType)
        }
    }

    // MARK: - Time Parsing Utilities

    /// Parse an XML rational time string: "85/2500s", "5s", "1s", "0s"
    static func parseFCPXMLTime(_ s: String?) -> CMTime {
        guard let s = s, !s.isEmpty else { return .zero }
        let stripped = s.hasSuffix("s") ? String(s.dropLast()) : s
        if stripped.contains("/") {
            let parts = stripped.split(separator: "/", maxSplits: 1)
            if parts.count == 2,
               let num = Int64(parts[0]),
               let den = Int32(parts[1]),
               den > 0 {
                return CMTime(value: num, timescale: den)
            }
        }
        if let seconds = Double(stripped), seconds.isFinite {
            return CMTime(seconds: seconds, preferredTimescale: 600)
        }
        return .zero
    }

    private func parseFCPXMLTime(_ s: String?) -> CMTime {
        XMLTimelineParser.parseFCPXMLTime(s)
    }

    private func parseFCPXMLTime(_ s: String) -> CMTime {
        XMLTimelineParser.parseFCPXMLTime(s)
    }

    /// Convert an XML offset value to HH:MM:SS:FF timecode string
    private func timecodeStringFromFCPXMLValue(_ value: String, frameRate: CMTime) -> String {
        let t    = parseFCPXMLTime(value)
        let secs = CMTimeGetSeconds(t)
        let rawFPS = frameRate.timescale > 0 && frameRate.value > 0
            ? Double(frameRate.timescale) / Double(frameRate.value)
            : 25.0
        let fps = rawFPS.isFinite && rawFPS > 0 ? rawFPS : 25.0
        let roundedFPS = max(Int(fps.rounded()), 1)
        let safeSeconds = secs.isFinite && secs > 0 ? secs : 0
        let framePosition = safeSeconds * fps
        let totalFrames = framePosition.isFinite && framePosition < Double(Int.max)
            ? Int(framePosition)
            : 0
        let ff = totalFrames % roundedFPS
        let ss = (totalFrames / roundedFPS) % 60
        let mm = (totalFrames / roundedFPS / 60) % 60
        let hh = totalFrames / roundedFPS / 3600
        return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
    }

    /// Resolve a potentially file:// or relative src string to an absolute POSIX path
    private func resolveFilePath(_ src: String, baseURL: URL) -> String {
        normalizeMediaPath(src, baseURL: baseURL)
    }

    private func buildFCP7FileTable(root: XMLElement, baseURL: URL) {
        for file in root.elements(forXPath: ".//file") {
            guard let fileID = file.attribute(forName: "id")?.stringValue,
                  let pathURL = file.elements(forXPath: "pathurl").first?.stringValue else {
                continue
            }
            fcp7FilePathsByID[fileID] = normalizeMediaPath(pathURL, baseURL: baseURL)
        }
    }

    private func normalizeMediaPath(_ src: String, baseURL: URL) -> String {
        let fm = FileManager.default

        func expanded(_ path: String) -> String {
            (path as NSString).expandingTildeInPath
        }

        func repairedVolumePath(_ path: String) -> String {
            guard path.hasPrefix("/"), !path.hasPrefix("/Volumes/") else { return path }
            return "/Volumes" + path
        }

        var candidates: [String] = []

        if src.hasPrefix("file://"), let url = URL(string: src), url.isFileURL {
            candidates.append(expanded(url.path))
        }

        let decoded = src.removingPercentEncoding ?? src
        if decoded.hasPrefix("/") {
            candidates.append(expanded(decoded))
        } else if !decoded.contains("://") {
            candidates.append(expanded(baseURL.deletingLastPathComponent()
                .appendingPathComponent(decoded).path))
            candidates.append(expanded(decoded))
        }

        for candidate in candidates {
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
            let repaired = repairedVolumePath(candidate)
            if repaired != candidate, fm.fileExists(atPath: repaired) {
                return repaired
            }
        }

        if let first = candidates.first {
            return repairedVolumePath(first)
        }
        return repairedVolumePath(expanded(decoded))
    }

    // MARK: - Lane → Track Index mapping

    /// lane 0 → (videoTrack=0, audioTrack=1)
    /// lane N<0 → extra audio lanes (N+2 offset, starting at track 2)
    /// lane N>0 → upper video layers (not used, flatten to 0)
    private func trackIndices(forLane lane: Int) -> (video: Int, audio: Int) {
        if lane <= 0 {
            let audioIdx = lane == 0 ? 1 : (2 + abs(lane) - 1)
            return (0, audioIdx)
        }
        return (0, 1) // flatten upper lanes to primary
    }

    private func offsetClips(_ clips: [ClipDescriptor], by offset: CMTime) -> [ClipDescriptor] {
        clips.map { c in
            ClipDescriptor(
                sourceURL:     c.sourceURL,
                timelineRange: CMTimeRange(start: CMTimeAdd(c.timelineRange.start, offset),
                                           duration: c.timelineRange.duration),
                sourceRange:   c.sourceRange,
                trackIndex:    c.trackIndex,
                mediaType:     c.mediaType)
        }
    }
}

// MARK: - Optional String CMTime helper

private func parseFCPXMLTime(_ s: String?) -> CMTime {
    XMLTimelineParser.parseFCPXMLTime(s)
}
