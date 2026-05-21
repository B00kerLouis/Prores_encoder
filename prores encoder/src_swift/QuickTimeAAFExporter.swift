import Foundation
import AVFoundation
import CoreMedia
import swiftaaf_Framework

func generateLinkedAAFWithSwiftAAF(
    descriptor: TimelineDescriptor,
    outputPath: String,
    sequenceName: String? = nil
) -> Bool {
    do {
        let writer = QuickTimeLinkedTimelineAAFWriter()
        try writer.write(
            descriptor: descriptor,
            to: URL(fileURLWithPath: outputPath),
            sequenceName: sequenceName ?? (descriptor.name.isEmpty ? "Linked Media Sequence" : descriptor.name)
        )
        print("[AAF] SwiftAAF wrote \(outputPath)")
        return true
    } catch {
        print("[AAF] Linked AAF generation failed: \(error.localizedDescription)")
        return false
    }
}

private final class QuickTimeLinkedTimelineAAFWriter {
    private static let timecodeSlotID: UInt32 = 1
    private static let firstTimelineSlotID: UInt32 = 2
    private static let videoSourceSlotID: UInt32 = 1
    private static let audioSourceSlotID: UInt32 = 2
    private static var audioRate: swiftaaf_Framework.AAFRational {
        swiftaaf_Framework.AAFRational(48_000, 1)
    }

    private static var avidContainerFormat: swiftaaf_Framework.AUID {
        get throws { try swiftaaf_Framework.AUID("4b464141-000d-4d4f-060e-2b34010101ff") }
    }

    private static var avidAMAContainerGUID: swiftaaf_Framework.AUID {
        get throws { try swiftaaf_Framework.AUID("87a0584d-cafa-41f5-9a68-f0cadefdbb71") }
    }

    private static var avidAMAContainerHandlerGUID: swiftaaf_Framework.AUID {
        get throws { try swiftaaf_Framework.AUID("3c06dc73-0276-4c4c-ba3f-3f47120cd1e9") }
    }

    private struct SourceBinding {
        let url: URL
        let name: String
        let sourceMob: AAFObject
        let masterMob: AAFObject
        let hasVideo: Bool
        let hasAudio: Bool
        let videoLengthFrames: Int64
        let audioLengthSamples: Int64
        let audioChannels: Int
    }

    func write(descriptor: TimelineDescriptor, to url: URL, sequenceName: String) throws {
        guard !descriptor.clips.isEmpty else {
            throw QuickTimeAAFExportError.noClips
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let file = try AAFFile(url: url, mode: "w")
        try applyIdentification(file: file)

        let videoRate = Self.videoEditRate(from: descriptor)
        let sourceBindings = try buildSourceBindings(
            file: file,
            descriptor: descriptor,
            videoRate: videoRate
        )

        for binding in sourceBindings.values.sorted(by: { $0.name < $1.name }) {
            try file.content.mobs.append(binding.sourceMob)
            try file.content.mobs.append(binding.masterMob)
        }

        let compositionMob = try createCompositionMob(
            file: file,
            descriptor: descriptor,
            sourceBindings: sourceBindings,
            videoRate: videoRate,
            sequenceName: sequenceName
        )
        try file.content.mobs.append(compositionMob)
        try file.close()
    }

    private func buildSourceBindings(
        file: AAFFile,
        descriptor: TimelineDescriptor,
        videoRate: swiftaaf_Framework.AAFRational
    ) throws -> [String: SourceBinding] {
        let grouped = Dictionary(grouping: descriptor.clips) { $0.sourceURL.standardizedFileURL.path }
        var bindings: [String: SourceBinding] = [:]

        for (path, clips) in grouped {
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent
            let hasVideo = clips.contains { $0.mediaType == .video }
            let hasAudio = clips.contains { $0.mediaType == .audio }
            let videoLength = maxSourceLength(
                clips: clips.filter { $0.mediaType == .video },
                editRate: videoRate
            )
            let audioLength = maxSourceLength(
                clips: clips.filter { $0.mediaType == .audio },
                editRate: Self.audioRate
            )
            let audioChannels = max(audioChannelEstimate(for: url), hasAudio ? 1 : 0)

            let sourceMob = try file.create.SourceMob(name + " <SOURCE MOB>")
            let masterMob = try file.create.MasterMob(name)
            try masterMob.get("ConvertFrameRate")?.setDecodedValue(false)

            var fileDescriptors: [AAFObject] = []
            if hasVideo {
                try appendSourceTerminatorSlot(
                    to: sourceMob,
                    slotID: Self.videoSourceSlotID,
                    editRate: videoRate,
                    mediaKind: "picture",
                    length: videoLength
                )
                try appendLinkedSlot(
                    to: masterMob,
                    slotID: Self.videoSourceSlotID,
                    editRate: videoRate,
                    mediaKind: "picture",
                    length: videoLength,
                    sourceMob: sourceMob,
                    sourceSlotID: Self.videoSourceSlotID,
                    slotName: "V1"
                )
                fileDescriptors.append(try createVideoDescriptor(
                    file: file,
                    url: url,
                    descriptor: descriptor,
                    editRate: videoRate,
                    length: videoLength,
                    linkedSlotID: Self.videoSourceSlotID
                ))
            }

            if hasAudio {
                try appendSourceTerminatorSlot(
                    to: sourceMob,
                    slotID: Self.audioSourceSlotID,
                    editRate: Self.audioRate,
                    mediaKind: "sound",
                    length: audioLength
                )
                try appendLinkedSlot(
                    to: masterMob,
                    slotID: Self.audioSourceSlotID,
                    editRate: Self.audioRate,
                    mediaKind: "sound",
                    length: audioLength,
                    sourceMob: sourceMob,
                    sourceSlotID: Self.audioSourceSlotID,
                    slotName: "A1"
                )
                fileDescriptors.append(try createAudioDescriptor(
                    file: file,
                    url: url,
                    sampleLength: audioLength,
                    channels: audioChannels,
                    linkedSlotID: Self.audioSourceSlotID
                ))
            }

            if fileDescriptors.count == 1 {
                try sourceMob.setSourceMobDescriptor(fileDescriptors[0])
            } else {
                let multiple = try file.create.MultipleDescriptor()
                try multiple.setFileDescriptorLength(max(videoLength, audioLength))
                try multiple.setSampleRate(videoRate)
                try multiple.setContainerFormat(Self.avidContainerFormat)
                try applyAvidContainer(to: multiple)
                try multiple.locator.append(try file.create.NetworkLocator(Self.avidURLString(for: url)))
                try (multiple.get("FileDescriptors") as? AAFStrongReferenceVectorProperty)?.setObjects(fileDescriptors)
                try sourceMob.setSourceMobDescriptor(multiple)
            }

            bindings[path] = SourceBinding(
                url: url,
                name: name,
                sourceMob: sourceMob,
                masterMob: masterMob,
                hasVideo: hasVideo,
                hasAudio: hasAudio,
                videoLengthFrames: videoLength,
                audioLengthSamples: audioLength,
                audioChannels: audioChannels
            )
        }
        return bindings
    }

    private func createCompositionMob(
        file: AAFFile,
        descriptor: TimelineDescriptor,
        sourceBindings: [String: SourceBinding],
        videoRate: swiftaaf_Framework.AAFRational,
        sequenceName: String
    ) throws -> AAFObject {
        let mob = try file.create.CompositionMob(sequenceName)
        try mob.setMobUsage("Usage_TopLevel")

        let totalFrames = maxTimelineLength(
            clips: descriptor.clips.filter { $0.mediaType == .video },
            editRate: videoRate
        )
        try appendTimecodeSlot(
            to: mob,
            editRate: videoRate,
            length: max(totalFrames, 1),
            timecode: descriptor.startTimecode,
            drop: descriptor.isDropFrame
        )

        let videoGroups = Dictionary(grouping: descriptor.clips.filter { $0.mediaType == .video }) {
            $0.trackIndex
        }
        var slotID = Self.firstTimelineSlotID
        for key in videoGroups.keys.sorted() {
            let components = try timelineComponents(
                file: file,
                clips: videoGroups[key] ?? [],
                sourceBindings: sourceBindings,
                editRate: videoRate,
                mediaKind: "picture",
                sourceSlotID: Self.videoSourceSlotID
            )
            try appendSequenceSlot(
                to: mob,
                slotID: slotID,
                editRate: videoRate,
                mediaKind: "picture",
                components: components.objects,
                length: components.length,
                slotName: "V\(key + 1)"
            )
            slotID += 1
        }

        let audioGroups = Dictionary(grouping: descriptor.clips.filter { $0.mediaType == .audio }) {
            $0.trackIndex
        }
        for key in audioGroups.keys.sorted() {
            let components = try timelineComponents(
                file: file,
                clips: audioGroups[key] ?? [],
                sourceBindings: sourceBindings,
                editRate: Self.audioRate,
                mediaKind: "sound",
                sourceSlotID: Self.audioSourceSlotID
            )
            try appendSequenceSlot(
                to: mob,
                slotID: slotID,
                editRate: Self.audioRate,
                mediaKind: "sound",
                components: components.objects,
                length: components.length,
                slotName: "A\(max(key, 1))"
            )
            slotID += 1
        }

        return mob
    }

    private func timelineComponents(
        file: AAFFile,
        clips: [ClipDescriptor],
        sourceBindings: [String: SourceBinding],
        editRate: swiftaaf_Framework.AAFRational,
        mediaKind: Any,
        sourceSlotID: UInt32
    ) throws -> (objects: [AAFObject], length: Int64) {
        var cursor: Int64 = 0
        var components: [AAFObject] = []

        for clip in clips.sorted(by: clipSortOrder) {
            let start = Self.editUnits(from: clip.timelineRange.start, editRate: editRate)
            let length = max(Self.editUnits(from: clip.timelineRange.duration, editRate: editRate), 0)
            guard length > 0 else { continue }

            if start > cursor {
                components.append(try file.create.Filler(mediaKind: mediaKind, length: start - cursor))
                cursor = start
            }

            let key = clip.sourceURL.standardizedFileURL.path
            guard let binding = sourceBindings[key] else {
                throw QuickTimeAAFExportError.missingSourceBinding(clip.sourceURL.path)
            }
            if mediaKind as? String == "picture", !binding.hasVideo {
                continue
            }
            if mediaKind as? String == "sound", !binding.hasAudio {
                continue
            }

            let sourceStart = Self.editUnits(from: clip.sourceRange.start, editRate: editRate)
            let sourceClip = try file.create.SourceClip(
                start: sourceStart,
                length: length,
                mobID: try binding.masterMob.mobID ?? MobID(),
                slotID: sourceSlotID,
                mediaKind: mediaKind
            )
            components.append(sourceClip)
            cursor = max(cursor, start + length)
        }

        return (components, cursor)
    }

    private func appendTimecodeSlot(
        to mob: AAFObject,
        editRate: swiftaaf_Framework.AAFRational,
        length: Int64,
        timecode: String,
        drop: Bool
    ) throws {
        let fps = UInt16(max(1, Int(round(Double(editRate.numerator) / Double(editRate.denominator)))))
        let timecodeComponent = try mob.root!.create.Timecode(fps: fps, drop: drop, length: length)
        try timecodeComponent.setTimecodeStart(Self.timecodeFrames(timecode, fps: Int(fps)))
        try appendSequenceSlot(
            to: mob,
            slotID: Self.timecodeSlotID,
            editRate: editRate,
            mediaKind: "Timecode",
            components: [timecodeComponent],
            length: length,
            slotName: "TC1"
        )
    }

    private func appendSourceTerminatorSlot(
        to mob: AAFObject,
        slotID: UInt32,
        editRate: swiftaaf_Framework.AAFRational,
        mediaKind: Any,
        length: Int64
    ) throws {
        let terminator = try mob.root!.create.SourceClip(
            start: 0,
            length: length,
            mobID: MobID(),
            slotID: 0,
            mediaKind: mediaKind
        )
        try appendSequenceSlot(
            to: mob,
            slotID: slotID,
            editRate: editRate,
            mediaKind: mediaKind,
            components: [terminator],
            length: length,
            slotName: ""
        )
    }

    private func appendLinkedSlot(
        to mob: AAFObject,
        slotID: UInt32,
        editRate: swiftaaf_Framework.AAFRational,
        mediaKind: Any,
        length: Int64,
        sourceMob: AAFObject,
        sourceSlotID: UInt32,
        slotName: String
    ) throws {
        let sourceClip = try mob.root!.create.SourceClip(
            start: 0,
            length: length,
            mobID: try sourceMob.mobID ?? MobID(),
            slotID: sourceSlotID,
            mediaKind: mediaKind
        )
        try appendSequenceSlot(
            to: mob,
            slotID: slotID,
            editRate: editRate,
            mediaKind: mediaKind,
            components: [sourceClip],
            length: length,
            slotName: slotName
        )
    }

    private func appendSequenceSlot(
        to mob: AAFObject,
        slotID: UInt32,
        editRate: swiftaaf_Framework.AAFRational,
        mediaKind: Any,
        components: [AAFObject],
        length: Int64,
        slotName: String
    ) throws {
        let slot = try mob.createTimelineSlot(editRate, slotID: slotID)
        try slot.setSlotName(slotName)
        let sequence = try mob.root!.create.Sequence(mediaKind: mediaKind, length: length)
        try sequence.components.setObjects(components)
        try slot.setSegment(sequence)
    }

    private func createVideoDescriptor(
        file: AAFFile,
        url: URL,
        descriptor: TimelineDescriptor,
        editRate: swiftaaf_Framework.AAFRational,
        length: Int64,
        linkedSlotID: UInt32
    ) throws -> AAFObject {
        let item = try file.create.CDCIDescriptor()
        let width = max(Int(descriptor.resolution.width.rounded()), 1)
        let height = max(Int(descriptor.resolution.height.rounded()), 1)
        try item.setFileDescriptorLength(length)
        try item.setSampleRate(editRate)
        try item.setContainerFormat(Self.avidContainerFormat)
        try applyAvidContainer(to: item)
        try item.get("LinkedSlotID")?.setDecodedValue(linkedSlotID)
        try item.locator.append(try file.create.NetworkLocator(Self.avidURLString(for: url)))

        try item.get("ComponentWidth")?.setDecodedValue(UInt32(10))
        try item.get("HorizontalSubsampling")?.setDecodedValue(UInt32(2))
        try item.get("VerticalSubsampling")?.setDecodedValue(UInt32(1))
        try item.get("ColorSiting")?.setDecodedValue("CoSiting")
        try item.get("FrameLayout")?.setDecodedValue("FullFrame")
        try item.get("VideoLineMap")?.setDecodedValue([Int32(0), Int32(0)])
        try item.get("ImageAspectRatio")?.setDecodedValue(reducedAspectRatio(width: width, height: height))
        try item.get("StoredWidth")?.setDecodedValue(UInt32(width))
        try item.get("StoredHeight")?.setDecodedValue(UInt32(height))
        try item.get("SampledWidth")?.setDecodedValue(UInt32(width))
        try item.get("SampledHeight")?.setDecodedValue(UInt32(height))
        try item.get("SampledXOffset")?.setDecodedValue(Int32(0))
        try item.get("SampledYOffset")?.setDecodedValue(Int32(0))
        try item.get("DisplayWidth")?.setDecodedValue(UInt32(width))
        try item.get("DisplayHeight")?.setDecodedValue(UInt32(height))
        try item.get("DisplayXOffset")?.setDecodedValue(Int32(0))
        try item.get("DisplayYOffset")?.setDecodedValue(Int32(0))
        try item.get("ImageAlignmentFactor")?.setDecodedValue(UInt32(0))
        try item.get("Compression")?.setDecodedValue(AAFQuickTimeSequenceWriter.proResHQCompressionAUID)
        return item
    }

    private func createAudioDescriptor(
        file: AAFFile,
        url: URL,
        sampleLength: Int64,
        channels: Int,
        linkedSlotID: UInt32
    ) throws -> AAFObject {
        let item = try file.create.PCMDescriptor()
        let safeChannels = max(channels, 1)
        let bits = 24
        let blockAlign = safeChannels * max(bits / 8, 1)
        try item.setFileDescriptorLength(sampleLength)
        try item.setSampleRate(Self.audioRate)
        try item.setContainerFormat(Self.avidContainerFormat)
        try applyAvidContainer(to: item)
        try item.get("LinkedSlotID")?.setDecodedValue(linkedSlotID)
        try item.locator.append(try file.create.NetworkLocator(Self.avidURLString(for: url)))
        try item.get("DataOffset")?.setDecodedValue(Int32(0))
        try item.get("AudioSamplingRate")?.setDecodedValue(Self.audioRate)
        try item.get("Channels")?.setDecodedValue(UInt32(safeChannels))
        try item.get("AverageBPS")?.setDecodedValue(UInt32(48_000 * blockAlign))
        try item.get("QuantizationBits")?.setDecodedValue(UInt32(bits))
        try item.get("BlockAlign")?.setDecodedValue(UInt16(blockAlign))
        try item.get("Locked")?.setDecodedValue(false)
        return item
    }

    private func applyIdentification(file: AAFFile) throws {
        let identifications = try file.header.get("IdentificationList", allKeys: false) as? AAFStrongReferenceVectorProperty
        guard let identification = try identifications?.objects().first else { return }
        try identification.get("CompanyName")?.setDecodedValue("prores encoder")
        try identification.get("ProductName")?.setDecodedValue("prores encoder")
        try identification.get("ProductVersionString")?.setDecodedValue(SwiftAAF.version)
    }

    private func applyAvidContainer(to descriptor: AAFObject) throws {
        try descriptor.setMediaContainerGUID(Self.avidAMAContainerGUID)
        try descriptor.setContainerHandlerGUID(Self.avidAMAContainerHandlerGUID)
    }

    private func maxSourceLength(clips: [ClipDescriptor], editRate: swiftaaf_Framework.AAFRational) -> Int64 {
        clips.map {
            Self.editUnits(
                from: CMTimeAdd($0.sourceRange.start, $0.sourceRange.duration),
                editRate: editRate
            )
        }.max() ?? 0
    }

    private func maxTimelineLength(clips: [ClipDescriptor], editRate: swiftaaf_Framework.AAFRational) -> Int64 {
        clips.map {
            Self.editUnits(
                from: CMTimeAdd($0.timelineRange.start, $0.timelineRange.duration),
                editRate: editRate
            )
        }.max() ?? 0
    }

    private func audioChannelEstimate(for url: URL) -> Int {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = quickTimeAAFLoadAudioTracksSynchronously(from: asset).first,
              let description = quickTimeAAFLoadFormatDescriptionsSynchronously(from: audioTrack).first else {
            return 2
        }
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return 2
        }
        return Int(streamDescription.pointee.mChannelsPerFrame)
    }

    private func clipSortOrder(_ lhs: ClipDescriptor, _ rhs: ClipDescriptor) -> Bool {
        let compare = CMTimeCompare(lhs.timelineRange.start, rhs.timelineRange.start)
        if compare != 0 {
            return compare < 0
        }
        return lhs.sourceURL.path < rhs.sourceURL.path
    }

    private static func videoEditRate(from descriptor: TimelineDescriptor) -> swiftaaf_Framework.AAFRational {
        guard descriptor.frameRate.value > 0, descriptor.frameRate.timescale > 0 else {
            return swiftaaf_Framework.AAFRational(24, 1)
        }
        return swiftaaf_Framework.AAFRational(Int64(descriptor.frameRate.timescale), Int64(descriptor.frameRate.value))
    }

    private static func editUnits(from time: CMTime, editRate: swiftaaf_Framework.AAFRational) -> Int64 {
        let seconds = CMTimeGetSeconds(time)
        let rate = editRate.doubleValue
        guard seconds.isFinite, rate.isFinite else { return 0 }
        return Int64((seconds * rate).rounded())
    }

    private static func timecodeFrames(_ value: String, fps: Int) -> Int64 {
        let parts = value.replacingOccurrences(of: ";", with: ":").split(separator: ":")
        guard parts.count == 4,
              let hh = Int64(parts[0]),
              let mm = Int64(parts[1]),
              let ss = Int64(parts[2]),
              let ff = Int64(parts[3]) else {
            return 0
        }
        let safeFPS = Int64(max(fps, 1))
        return (((hh * 60) + mm) * 60 + ss) * safeFPS + ff
    }

    private static func avidURLString(for movieURL: URL) -> String {
        var path = movieURL.path
        if path.hasPrefix("/Volumes/") {
            path.removeFirst("/Volumes".count)
        }
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file://\(encodedPath)"
    }

    private func reducedAspectRatio(width: Int, height: Int) -> String {
        let divisor = gcd(abs(width), abs(height))
        guard divisor > 0 else {
            return "\(width)/\(height)"
        }
        return "\(width / divisor)/\(height / divisor)"
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}

private func quickTimeAAFLoadAudioTracksSynchronously(from asset: AVAsset) -> [AVAssetTrack] {
    let semaphore = DispatchSemaphore(value: 0)
    let assetRef = SendableRef(asset)
    let box = QuickTimeAAFSynchronousResultBox<[AVAssetTrack]>()
    Task {
        box.value = (try? await assetRef.value.loadTracks(withMediaType: .audio)) ?? []
        semaphore.signal()
    }
    semaphore.wait()
    return box.value ?? []
}

private func quickTimeAAFLoadFormatDescriptionsSynchronously(
    from track: AVAssetTrack
) -> [CMFormatDescription] {
    let semaphore = DispatchSemaphore(value: 0)
    let trackRef = SendableRef(track)
    let box = QuickTimeAAFSynchronousResultBox<[CMFormatDescription]>()
    Task {
        box.value = (try? await trackRef.value.load(.formatDescriptions)) ?? []
        semaphore.signal()
    }
    semaphore.wait()
    return box.value ?? []
}

private final class QuickTimeAAFSynchronousResultBox<T>: @unchecked Sendable {
    var value: T?
}

private enum QuickTimeAAFExportError: LocalizedError {
    case noClips
    case missingSourceBinding(String)

    var errorDescription: String? {
        switch self {
        case .noClips:
            return "Linked AAF export requires at least one clip"
        case .missingSourceBinding(let path):
            return "Missing source binding for \(path)"
        }
    }
}
