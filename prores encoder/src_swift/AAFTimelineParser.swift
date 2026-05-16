import Foundation
import AVFoundation
import CoreMedia
import swiftaaf_Framework

public final class AAFTimelineParser {
    private struct ResolvedSource {
        let url: URL
        let sourceStart: CMTime
        let width: Int?
        let height: Int?
    }

    private struct ParseContext {
        let aafURL: URL
        let searchPaths: [URL]
    }

    public init() {}

    public func parse(url: URL, mediaSearchPaths: [URL] = []) -> TimelineDescriptor? {
        do {
            let file = try AAFFile(url: url, mode: "r")
            defer { try? file.close() }

            let content = try file.content
            let topLevel = try content.topLevelMobs().first ?? content.compositionMobs().first
            guard let compositionMob = topLevel else {
                print("[AAFParser] No CompositionMob found.")
                return nil
            }

            let context = ParseContext(
                aafURL: url,
                searchPaths: uniqueURLs(mediaSearchPaths + [url.deletingLastPathComponent()])
            )
            let sequenceName = try compositionMob.mobName ?? url.deletingPathExtension().lastPathComponent

            var clips: [ClipDescriptor] = []
            var frameDuration = CMTime(value: 1, timescale: 24)
            var resolution = CGSize(width: 1920, height: 1080)
            var startTimecode = "00:00:00:00"
            var dropFrame = false
            var videoTrackFallback = 0
            var audioTrackFallback = 1

            let slots = try compositionMob.slots.objects().sorted {
                ((try? $0.slotID) ?? 0) < ((try? $1.slotID) ?? 0)
            }

            for slot in slots {
                guard let segment = try slot.segment else { continue }
                let slotName = (try? slot.slotName) ?? ""

                if segment.isAAFInstance(named: "Timecode") ||
                    (try? segment.mediaKind?.lowercased().contains("timecode")) == true {
                    let fps = Int((try? segment.timecodeFPS) ?? 24)
                    let start = (try? segment.timecodeStart) ?? 0
                    dropFrame = (try? segment.timecodeDrop) ?? false
                    startTimecode = Self.timecodeString(fromFrames: start, fps: fps, drop: dropFrame)
                    continue
                }

                guard let mediaType = mediaType(for: segment, slotName: slotName),
                      let editRate = try slot.editRate else {
                    continue
                }

                let trackIndex: Int
                if mediaType == .video {
                    trackIndex = trackIndexFromSlotName(slotName, mediaType: .video) ?? videoTrackFallback
                    videoTrackFallback += 1
                    frameDuration = Self.frameDuration(for: editRate)
                } else {
                    trackIndex = trackIndexFromSlotName(slotName, mediaType: .audio) ?? audioTrackFallback
                    audioTrackFallback += 1
                }

                let beforeCount = clips.count
                try appendClips(
                    from: segment,
                    timelineStartUnits: 0,
                    slotEditRate: editRate,
                    mediaType: mediaType,
                    trackIndex: trackIndex,
                    context: context,
                    clips: &clips,
                    resolution: &resolution
                )
                if beforeCount == clips.count {
                    print("[AAFParser] Warning: slot '\(slotName)' produced no clips.")
                }
            }

            guard !clips.isEmpty else {
                print("[AAFParser] No linked media clips found.")
                return nil
            }

            return TimelineDescriptor(
                name: sequenceName,
                frameRate: frameDuration,
                isDropFrame: dropFrame,
                startTimecode: startTimecode,
                resolution: resolution,
                clips: clips
            )
        } catch {
            print("[AAFParser] \(error.localizedDescription)")
            return nil
        }
    }

    private func appendClips(
        from component: AAFObject,
        timelineStartUnits: Int64,
        slotEditRate: swiftaaf_Framework.AAFRational,
        mediaType: AVMediaType,
        trackIndex: Int,
        context: ParseContext,
        clips: inout [ClipDescriptor],
        resolution: inout CGSize
    ) throws {
        if component.isAAFInstance(named: "Sequence") {
            for (_, position, child) in try component.sequencePositions() {
                try appendClips(
                    from: child,
                    timelineStartUnits: timelineStartUnits + max(position, 0),
                    slotEditRate: slotEditRate,
                    mediaType: mediaType,
                    trackIndex: trackIndex,
                    context: context,
                    clips: &clips,
                    resolution: &resolution
                )
            }
            return
        }

        if component.isAAFInstance(named: "Filler") ||
            component.isAAFInstance(named: "Transition") {
            return
        }

        if component.isAAFInstance(named: "Selector"),
           let selected = try component.selectorSelected {
            try appendClips(
                from: selected,
                timelineStartUnits: timelineStartUnits,
                slotEditRate: slotEditRate,
                mediaType: mediaType,
                trackIndex: trackIndex,
                context: context,
                clips: &clips,
                resolution: &resolution
            )
            return
        }

        if component.isAAFInstance(named: "NestedScope") {
            for nested in try component.nestedScopeSlots.objects() {
                try appendClips(
                    from: nested,
                    timelineStartUnits: timelineStartUnits,
                    slotEditRate: slotEditRate,
                    mediaType: mediaType,
                    trackIndex: trackIndex,
                    context: context,
                    clips: &clips,
                    resolution: &resolution
                )
            }
            return
        }

        if component.isAAFInstance(named: "OperationGroup"),
           let inputs = component.get("InputSegments") as? AAFStrongReferenceVectorProperty {
            for input in try inputs.objects() {
                try appendClips(
                    from: input,
                    timelineStartUnits: timelineStartUnits,
                    slotEditRate: slotEditRate,
                    mediaType: mediaType,
                    trackIndex: trackIndex,
                    context: context,
                    clips: &clips,
                    resolution: &resolution
                )
            }
            return
        }

        guard component.isAAFInstance(named: "SourceClip") else {
            return
        }

        let lengthUnits = (try component.componentLength) ?? 0
        guard lengthUnits > 0,
              let source = try resolveSource(for: component,
                                             mediaType: mediaType,
                                             fallbackRate: slotEditRate,
                                             context: context) else {
            return
        }

        if mediaType == .video,
           let width = source.width,
           let height = source.height,
           width > 0,
           height > 0 {
            resolution = CGSize(width: width, height: height)
        }

        let timelineStart = Self.time(fromEditUnits: timelineStartUnits, editRate: slotEditRate)
        let duration = Self.time(fromEditUnits: lengthUnits, editRate: slotEditRate)
        clips.append(ClipDescriptor(
            sourceURL: source.url,
            timelineRange: CMTimeRange(start: timelineStart, duration: duration),
            sourceRange: CMTimeRange(start: source.sourceStart, duration: duration),
            trackIndex: trackIndex,
            mediaType: mediaType
        ))
    }

    private func resolveSource(
        for clip: AAFObject,
        mediaType: AVMediaType,
        fallbackRate: swiftaaf_Framework.AAFRational,
        context: ParseContext
    ) throws -> ResolvedSource? {
        var currentClip: AAFObject? = clip
        var accumulatedStart = (try clip.startTime) ?? 0
        var currentRate = fallbackRate
        var depth = 0

        while let sourceClip = currentClip, depth < 32 {
            depth += 1
            guard let mob = try sourceClip.sourceMob else {
                return nil
            }

            let sourceSlotID = try sourceClip.sourceSlotID
            if let descriptor = try mob.sourceMobDescriptor,
               let resolved = try sourceFromDescriptor(
                    descriptor,
                    sourceSlotID: sourceSlotID,
                    mediaType: mediaType,
                    sourceStart: accumulatedStart,
                    editRate: currentRate,
                    context: context) {
                return resolved
            }

            guard let slot = try sourceClip.sourceSlot,
                  let segment = try slot.segment else {
                return nil
            }

            currentRate = (try slot.editRate) ?? currentRate
            if segment.isAAFInstance(named: "Sequence") {
                let selected = try component(in: segment, at: accumulatedStart)
                accumulatedStart = selected.localOffset
                currentClip = selected.component
            } else if segment.isAAFInstance(named: "SourceClip") {
                accumulatedStart += (try segment.startTime) ?? 0
                currentClip = segment
            } else {
                return nil
            }
        }

        return nil
    }

    private func component(in sequence: AAFObject, at editUnit: Int64) throws -> (component: AAFObject, localOffset: Int64) {
        var fallback: (AAFObject, Int64)?
        for (_, position, component) in try sequence.sequencePositions() {
            let length = (try component.componentLength) ?? 0
            if fallback == nil {
                fallback = (component, max(editUnit - position, 0))
            }
            if position <= editUnit, editUnit < position + length {
                return (component, max(editUnit - position, 0))
            }
        }
        if let fallback {
            return fallback
        }
        throw AAFParserError.emptySequence
    }

    private func sourceFromDescriptor(
        _ descriptor: AAFObject,
        sourceSlotID: UInt32?,
        mediaType: AVMediaType,
        sourceStart: Int64,
        editRate: swiftaaf_Framework.AAFRational,
        context: ParseContext
    ) throws -> ResolvedSource? {
        let candidates = try descriptorCandidates(
            from: descriptor,
            sourceSlotID: sourceSlotID,
            mediaType: mediaType
        )

        for candidate in candidates {
            guard let url = try locatorURL(from: candidate, context: context) else { continue }
            return ResolvedSource(
                url: url,
                sourceStart: Self.time(fromEditUnits: sourceStart, editRate: editRate),
                width: Self.intValue(try candidate.value(for: "StoredWidth")),
                height: Self.intValue(try candidate.value(for: "StoredHeight"))
            )
        }
        return nil
    }

    private func descriptorCandidates(
        from descriptor: AAFObject,
        sourceSlotID: UInt32?,
        mediaType: AVMediaType
    ) throws -> [AAFObject] {
        guard descriptor.isAAFInstance(named: "MultipleDescriptor"),
              let vector = descriptor.get("FileDescriptors") as? AAFStrongReferenceVectorProperty else {
            return [descriptor]
        }

        let descriptors = try vector.objects()
        let bySlot = descriptors.filter {
            guard let sourceSlotID else { return false }
            return Self.uint32Value(try? $0.value(for: "LinkedSlotID")) == sourceSlotID
        }
        if !bySlot.isEmpty {
            return bySlot
        }

        let byKind = descriptors.filter { candidate in
            if mediaType == .video {
                return candidate.isAAFInstance(named: "DigitalImageDescriptor")
            }
            return candidate.isAAFInstance(named: "SoundDescriptor")
        }
        return byKind.isEmpty ? descriptors : byKind
    }

    private func locatorURL(from descriptor: AAFObject, context: ParseContext) throws -> URL? {
        let descriptors: [AAFObject]
        if descriptor.isAAFInstance(named: "MultipleDescriptor"),
           let vector = descriptor.get("FileDescriptors") as? AAFStrongReferenceVectorProperty {
            descriptors = try vector.objects()
        } else {
            descriptors = [descriptor]
        }

        for item in descriptors {
            guard let locatorProperty = item.get("Locator") as? AAFStrongReferenceVectorProperty else {
                continue
            }
            for locator in try locatorProperty.objects() {
                guard let raw = try locator.urlString,
                      let url = resolve(locator: raw, context: context) else {
                    continue
                }
                return url
            }
        }
        return nil
    }

    private func resolve(locator: String, context: ParseContext) -> URL? {
        let fm = FileManager.default
        let decoded = locator.removingPercentEncoding ?? locator
        var candidates: [String] = []

        if decoded.hasPrefix("file://"), let url = URL(string: decoded), url.isFileURL {
            candidates.append(url.path)
        }
        if decoded.hasPrefix("/") {
            candidates.append(decoded)
        }
        if decoded.hasPrefix("file:///") {
            candidates.append(String(decoded.dropFirst("file://".count)))
        }
        if !decoded.contains("://") {
            candidates.append(decoded)
        }

        for path in candidates {
            let expanded = (path as NSString).expandingTildeInPath
            if fm.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
            let volumePath = expanded.hasPrefix("/Volumes/") ? expanded : "/Volumes" + expanded
            if fm.fileExists(atPath: volumePath) {
                return URL(fileURLWithPath: volumePath)
            }
        }

        let fileName = candidates.compactMap { URL(fileURLWithPath: $0).lastPathComponent }.first { !$0.isEmpty }
        if let fileName {
            for searchPath in context.searchPaths {
                let candidate = searchPath.appendingPathComponent(fileName).path
                if fm.fileExists(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        if let first = candidates.first {
            return URL(fileURLWithPath: first)
        }
        return nil
    }

    private func mediaType(for segment: AAFObject, slotName: String) -> AVMediaType? {
        let mediaKind = ((try? segment.mediaKind) ?? "").lowercased()
        if mediaKind.contains("picture") {
            return .video
        }
        if mediaKind.contains("sound") {
            return .audio
        }

        let upper = slotName.uppercased()
        if upper.hasPrefix("V") {
            return .video
        }
        if upper.hasPrefix("A") {
            return .audio
        }
        return nil
    }

    private func trackIndexFromSlotName(_ slotName: String, mediaType: AVMediaType) -> Int? {
        let upper = slotName.uppercased()
        let prefix = mediaType == .video ? "V" : "A"
        guard upper.hasPrefix(prefix) else { return nil }
        let digits = upper.dropFirst().prefix { $0.isNumber }
        guard let value = Int(digits) else { return nil }
        return mediaType == .video ? max(value - 1, 0) : max(value, 1)
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private static func frameDuration(for editRate: swiftaaf_Framework.AAFRational) -> CMTime {
        let num = max(Int64(editRate.numerator), 1)
        let den = max(Int64(editRate.denominator), 1)
        return CMTime(value: CMTimeValue(den), timescale: CMTimeScale(num))
    }

    private static func time(fromEditUnits units: Int64, editRate: swiftaaf_Framework.AAFRational) -> CMTime {
        let num = max(Int64(editRate.numerator), 1)
        let den = max(Int64(editRate.denominator), 1)
        return CMTime(value: CMTimeValue(units * den), timescale: CMTimeScale(num))
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let int64 = int64Value(value) else { return nil }
        return Int(int64)
    }

    private static func uint32Value(_ value: Any?) -> UInt32? {
        guard let int64 = int64Value(value), int64 >= 0 else { return nil }
        return UInt32(int64)
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int:
            return Int64(value)
        case let value as Int8:
            return Int64(value)
        case let value as Int16:
            return Int64(value)
        case let value as Int32:
            return Int64(value)
        case let value as Int64:
            return value
        case let value as UInt8:
            return Int64(value)
        case let value as UInt16:
            return Int64(value)
        case let value as UInt32:
            return Int64(value)
        case let value as UInt64:
            return Int64(exactly: value)
        default:
            return nil
        }
    }

    private static func timecodeString(fromFrames frames: Int64, fps: Int, drop: Bool) -> String {
        let safeFPS = max(fps, 1)
        let separator = drop ? ";" : ":"
        let ff = Int(frames % Int64(safeFPS))
        let totalSeconds = Int(frames / Int64(safeFPS))
        let ss = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let hh = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, separator, ff)
    }
}

private enum AAFParserError: LocalizedError {
    case emptySequence

    var errorDescription: String? {
        switch self {
        case .emptySequence:
            return "AAF Sequence has no components"
        }
    }
}
