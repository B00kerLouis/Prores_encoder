import Foundation
import AVFoundation
import CoreMedia

public final class FCP7XMLTimelineWriter {
    public init() {}

    public func write(_ descriptor: TimelineDescriptor, to url: URL) -> Bool {
        do {
            let document = XMLDocument(rootElement: rootElement(for: descriptor))
            document.version = "1.0"
            document.characterEncoding = "UTF-8"
            let data = document.xmlData(options: [.nodePrettyPrint])
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[XML] Failed to write XML timeline: \(error.localizedDescription)")
            return false
        }
    }

    private func rootElement(for descriptor: TimelineDescriptor) -> XMLElement {
        let root = XMLElement(name: "xmeml")
        root.addAttribute(XMLNode.attribute(withName: "version", stringValue: "4") as! XMLNode)

        let sequence = XMLElement(name: "sequence")
        sequence.addChild(element("name", descriptor.name.isEmpty ? "Sequence" : descriptor.name))
        sequence.addChild(rateElement(for: descriptor))
        sequence.addChild(durationElement(for: descriptor))
        sequence.addChild(timecodeElement(for: descriptor))
        sequence.addChild(mediaElement(for: descriptor))
        root.addChild(sequence)
        return root
    }

    private func durationElement(for descriptor: TimelineDescriptor) -> XMLElement {
        element("duration", "\(maxFrameEnd(in: descriptor))")
    }

    private func timecodeElement(for descriptor: TimelineDescriptor) -> XMLElement {
        let timecode = XMLElement(name: "timecode")
        timecode.addChild(rateElement(for: descriptor))
        timecode.addChild(element("string", descriptor.startTimecode))
        timecode.addChild(element("frame", "\(timecodeStartFrame(descriptor.startTimecode, descriptor: descriptor))"))
        timecode.addChild(element("displayformat", descriptor.isDropFrame ? "DF" : "NDF"))
        return timecode
    }

    private func mediaElement(for descriptor: TimelineDescriptor) -> XMLElement {
        let media = XMLElement(name: "media")
        media.addChild(videoElement(for: descriptor))
        media.addChild(audioElement(for: descriptor))
        return media
    }

    private func videoElement(for descriptor: TimelineDescriptor) -> XMLElement {
        let video = XMLElement(name: "video")
        let format = XMLElement(name: "format")
        let sample = XMLElement(name: "samplecharacteristics")
        sample.addChild(rateElement(for: descriptor))
        sample.addChild(element("width", "\(Int(descriptor.resolution.width.rounded()))"))
        sample.addChild(element("height", "\(Int(descriptor.resolution.height.rounded()))"))
        format.addChild(sample)
        video.addChild(format)

        let grouped = Dictionary(grouping: descriptor.clips.filter { $0.mediaType == .video }) {
            $0.trackIndex
        }
        for key in grouped.keys.sorted() {
            let track = XMLElement(name: "track")
            for (index, clip) in (grouped[key] ?? []).sorted(by: clipSortOrder).enumerated() {
                track.addChild(clipItemElement(
                    clip,
                    descriptor: descriptor,
                    id: "video-\(key + 1)-\(index + 1)",
                    mediaType: .video
                ))
            }
            video.addChild(track)
        }
        return video
    }

    private func audioElement(for descriptor: TimelineDescriptor) -> XMLElement {
        let audio = XMLElement(name: "audio")
        audio.addChild(element("samplecharacteristics", children: [
            element("depth", "24"),
            element("samplerate", "48000")
        ]))

        let grouped = Dictionary(grouping: descriptor.clips.filter { $0.mediaType == .audio }) {
            $0.trackIndex
        }
        for key in grouped.keys.sorted() {
            let track = XMLElement(name: "track")
            for (index, clip) in (grouped[key] ?? []).sorted(by: clipSortOrder).enumerated() {
                track.addChild(clipItemElement(
                    clip,
                    descriptor: descriptor,
                    id: "audio-\(key)-\(index + 1)",
                    mediaType: .audio
                ))
            }
            audio.addChild(track)
        }
        return audio
    }

    private func clipItemElement(
        _ clip: ClipDescriptor,
        descriptor: TimelineDescriptor,
        id: String,
        mediaType: AVMediaType
    ) -> XMLElement {
        let clipitem = XMLElement(name: "clipitem")
        clipitem.addAttribute(XMLNode.attribute(withName: "id", stringValue: id) as! XMLNode)

        let start = frameNumber(clip.timelineRange.start, descriptor: descriptor)
        let end = frameNumber(CMTimeAdd(clip.timelineRange.start, clip.timelineRange.duration), descriptor: descriptor)
        let sourceIn = frameNumber(clip.sourceRange.start, descriptor: descriptor)
        let sourceOut = frameNumber(CMTimeAdd(clip.sourceRange.start, clip.sourceRange.duration), descriptor: descriptor)

        clipitem.addChild(element("name", clip.sourceURL.deletingPathExtension().lastPathComponent))
        clipitem.addChild(element("duration", "\(max(end - start, 0))"))
        clipitem.addChild(rateElement(for: descriptor))
        clipitem.addChild(element("start", "\(start)"))
        clipitem.addChild(element("end", "\(end)"))
        clipitem.addChild(element("in", "\(sourceIn)"))
        clipitem.addChild(element("out", "\(sourceOut)"))
        clipitem.addChild(fileElement(for: clip.sourceURL, id: "file-\(stableID(for: clip.sourceURL.path))"))

        if mediaType == .audio {
            clipitem.addChild(element("sourcetrack", children: [
                element("mediatype", "audio"),
                element("trackindex", "\(max(clip.trackIndex, 1))")
            ]))
        }
        return clipitem
    }

    private func fileElement(for url: URL, id: String) -> XMLElement {
        let file = XMLElement(name: "file")
        file.addAttribute(XMLNode.attribute(withName: "id", stringValue: id) as! XMLNode)
        file.addChild(element("name", url.lastPathComponent))
        file.addChild(element("pathurl", url.absoluteString))
        return file
    }

    private func rateElement(for descriptor: TimelineDescriptor) -> XMLElement {
        let rate = XMLElement(name: "rate")
        let info = frameRateInfo(for: descriptor)
        rate.addChild(element("timebase", "\(info.timebase)"))
        rate.addChild(element("ntsc", info.ntsc ? "TRUE" : "FALSE"))
        return rate
    }

    private func frameRateInfo(for descriptor: TimelineDescriptor) -> (fps: Double, timebase: Int, ntsc: Bool) {
        let fps = descriptor.frameRate.value > 0
            ? Double(descriptor.frameRate.timescale) / Double(descriptor.frameRate.value)
            : 24.0
        let ntsc = abs(fps - 23.976) < 0.02 ||
            abs(fps - 29.97) < 0.05 ||
            abs(fps - 59.94) < 0.08
        let timebase: Int
        if abs(fps - 23.976) < 0.02 {
            timebase = 24
        } else if abs(fps - 29.97) < 0.05 {
            timebase = 30
        } else if abs(fps - 59.94) < 0.08 {
            timebase = 60
        } else {
            timebase = max(Int(fps.rounded()), 1)
        }
        return (fps, timebase, ntsc)
    }

    private func frameNumber(_ time: CMTime, descriptor: TimelineDescriptor) -> Int {
        let seconds = CMTimeGetSeconds(time)
        let fps = frameRateInfo(for: descriptor).fps
        guard seconds.isFinite, fps.isFinite else { return 0 }
        return max(Int((seconds * fps).rounded()), 0)
    }

    private func maxFrameEnd(in descriptor: TimelineDescriptor) -> Int {
        descriptor.clips
            .map { frameNumber(CMTimeAdd($0.timelineRange.start, $0.timelineRange.duration), descriptor: descriptor) }
            .max() ?? 0
    }

    private func timecodeStartFrame(_ value: String, descriptor: TimelineDescriptor) -> Int {
        let fps = max(frameRateInfo(for: descriptor).timebase, 1)
        let parts = value.replacingOccurrences(of: ";", with: ":").split(separator: ":")
        guard parts.count == 4,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              let ss = Int(parts[2]),
              let ff = Int(parts[3]) else {
            return 0
        }
        return (((hh * 60) + mm) * 60 + ss) * fps + ff
    }

    private func clipSortOrder(_ lhs: ClipDescriptor, _ rhs: ClipDescriptor) -> Bool {
        let startCompare = CMTimeCompare(lhs.timelineRange.start, rhs.timelineRange.start)
        if startCompare != 0 {
            return startCompare < 0
        }
        return lhs.sourceURL.path < rhs.sourceURL.path
    }

    private func stableID(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func element(_ name: String, _ stringValue: String) -> XMLElement {
        let node = XMLElement(name: name)
        node.stringValue = stringValue
        return node
    }

    private func element(_ name: String, children: [XMLElement]) -> XMLElement {
        let node = XMLElement(name: name)
        for child in children {
            node.addChild(child)
        }
        return node
    }
}
