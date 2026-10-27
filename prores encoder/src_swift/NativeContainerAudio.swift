// Copyright © 2026 B00kerLouis. All rights reserved.
import Foundation
import CoreMedia
import Darwin

/// Container identification is independent of the filename and audio codec.
/// This also accepts ISO audio supplied through -aa under an unfamiliar suffix.
enum NativeContainerKind {
    case isoMovie, matroska, other
    static func identify(_ url: URL) throws -> NativeContainerKind {
        guard url.isFileURL else { return .other }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 12) ?? Data()
        if bytes.count >= 4 && EBML.value(bytes.prefix(4)) == 0x1a45dfa3 { return .matroska }
        if bytes.count >= 8 {
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            if ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(type) { return .isoMovie }
        }
        return .other
    }
}

/// Packet offsets are valid only for the indexed file identity. Validate both
/// before and after copying so a replaced or modified source never produces a
/// successful delivery containing bytes from a different file.
struct ContainerSourceIdentity: Equatable {
    let device: Int32, inode: UInt64, size: Int64, seconds: Int64, nanoseconds: Int64
    static func read(_ file: FileHandle) throws -> ContainerSourceIdentity {
        var value = stat()
        guard fstat(file.fileDescriptor, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return ContainerSourceIdentity(device: value.st_dev, inode: value.st_ino, size: value.st_size,
            seconds: Int64(value.st_mtimespec.tv_sec), nanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
    func validate(_ file: FileHandle) throws {
        guard try Self.read(file) == self else { throw MatroskaError.invalid("the indexed source file changed during packet delivery") }
    }
}

/// Container-level tracks deliberately have no dependency on an audio decoder,
/// AudioToolbox codec registry or AVAssetWriter's codec admission whitelist.
struct NativeMovieTrack {
    let template: ContainerBox
    let id: UInt32
    let scale: UInt32
    let handler: String
    let descriptions: [ContainerBox]
    let packets: [MatroskaPacket]
    let durations: [UInt32]
    let cts: [Int32]
    let descriptionIndices: [UInt32]
    var sampleCounts: [UInt32] = []
}

struct NativeMovieFile {
    let url: URL
    let movie: ContainerBox
    let scale: UInt32
    let tracks: [NativeMovieTrack]
    let identity: ContainerSourceIdentity?
    init(url: URL, movie: ContainerBox, scale: UInt32, tracks: [NativeMovieTrack], identity: ContainerSourceIdentity? = nil) {
        self.url = url; self.movie = movie; self.scale = scale; self.tracks = tracks; self.identity = identity
    }
    init(url: URL, audioOnly: Bool = false) throws {
        self.url = url
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        identity = try ContainerSourceIdentity.read(file)
        let locations = try ContainerBox.locations(file)
        movie = try ContainerBox.movie(file, locations).1
        let header = try movie.child("mvhd").payload
        scale = UInt32(try ContainerBox.word(header, header.first == 1 ? 20 : 12))
        guard scale > 0 else { throw MatroskaError.invalid("zero movie timescale") }
        var result: [NativeMovieTrack] = []
        for track in try ContainerBox.parse(movie.payload) where track.type == "trak" {
            let mdia = try track.child("mdia"), hdlr = try mdia.child("hdlr").payload
            guard hdlr.count >= 12 else { throw MatroskaError.invalid("truncated track handler") }
            let handler = String(decoding: hdlr[8..<12], as: UTF8.self)
            guard handler == "soun" || handler == "vide" else { continue }
            if audioOnly && handler != "soun" { continue }
            let tkhd = try track.child("tkhd").payload, mdhd = try mdia.child("mdhd").payload
            let id = UInt32(try ContainerBox.word(tkhd, tkhd.first == 1 ? 20 : 12))
            let trackScale = UInt32(try ContainerBox.word(mdhd, mdhd.first == 1 ? 20 : 12))
            guard trackScale > 0 && trackScale <= Int32.max else { throw MatroskaError.invalid("zero track timescale") }
            let table = try mdia.child("minf").child("stbl"), children = try ContainerBox.parse(table.payload)
            let stsd = try table.child("stsd").payload
            guard stsd.count >= 8 else { throw MatroskaError.invalid("truncated sample descriptions") }
            let descriptions = try ContainerBox.parse(stsd.subdata(in: 8..<stsd.count))
            let stsz = try table.child("stsz").payload
            let fixed = try ContainerBox.word(stsz, 4), count = Int(try ContainerBox.word(stsz, 8))
            let pcmTypes: Set<String> = ["lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64", "raw "]
            if handler == "soun", fixed > 0, fixed <= 1024, descriptions.count == 1,
               pcmTypes.contains(descriptions[0].type), !children.contains(where: { $0.type == "ctts" || $0.type == "stss" }),
               let stts = children.first(where: { $0.type == "stts" }), try ContainerBox.word(stts.payload, 4) == 1 {
                let ticks = try ContainerBox.word(stts.payload, 12)
                let compact = try Self.compactPCM(file: file, track: track, id: id, scale: trackScale,
                    descriptions: descriptions, table: table, samples: count, bytesPerSample: fixed, ticks: ticks)
                result.append(compact); continue
            }
            guard count <= 10_000_000 else { throw MatroskaError.invalid("sample index exceeds metadata memory budget") }
            if count == 0 {
                if locations.contains(where: { $0.type == "moof" }) {
                    if let fragmented = try Self.fragments(file: file, locations: locations, movie: movie,
                        template: track, id: id, scale: trackScale, movieScale: scale, handler: handler, descriptions: descriptions) {
                        result.append(fragmented)
                    }
                }
                continue
            }
            let sizes = try (0..<count).map { fixed > 0 ? fixed : try ContainerBox.word(stsz, 12 + $0 * 4) }
            func runs(_ name: String, fallback: Int64) throws -> [Int64] {
                guard let box = children.first(where: { $0.type == name }) else { return Array(repeating: fallback, count: count) }
                let records = Int(try ContainerBox.word(box.payload, 4))
                guard records <= count else { throw MatroskaError.invalid("oversized timing table") }
                var values: [Int64] = []
                for n in 0..<records {
                    let run = Int(try ContainerBox.word(box.payload, 8 + n * 8))
                    let word = UInt32(try ContainerBox.word(box.payload, 12 + n * 8))
                    guard run <= count - values.count else { throw MatroskaError.invalid("invalid timing run") }
                    let value = name == "ctts" ? Int64(Int32(bitPattern: word)) : Int64(word)
                    values.append(contentsOf: repeatElement(value, count: run))
                }
                guard values.count == count else { throw MatroskaError.invalid("incomplete timing table") }
                return values
            }
            let durations = try runs("stts", fallback: 0), cts = try runs("ctts", fallback: 0)
            guard let chunks = children.first(where: { $0.type == "stco" || $0.type == "co64" }) else { throw MatroskaError.invalid("missing chunk table") }
            let chunkCount = Int(try ContainerBox.word(chunks.payload, 4)), width = chunks.type == "co64" ? 8 : 4
            let mapping = try table.child("stsc").payload, records = Int(try ContainerBox.word(mapping, 4))
            guard records > 0, records <= chunkCount, chunkCount <= count else { throw MatroskaError.invalid("invalid sample-to-chunk table") }
            var edits: Int64 = 0
            if let edts = try ContainerBox.parse(track.payload).first(where: { $0.type == "edts" }) {
                let elst = try edts.child("elst").payload, wide = elst.first == 1
                let editCount = Int(try ContainerBox.word(elst, 4))
                for n in 0..<editCount {
                    let offset = 8 + n * (wide ? 20 : 12)
                    let duration = try ContainerBox.word(elst, offset, wide ? 8 : 4)
                    let raw = try ContainerBox.word(elst, offset + (wide ? 8 : 4), wide ? 8 : 4)
                    let media = wide ? Int64(bitPattern: raw) : Int64(Int32(bitPattern: UInt32(raw)))
                    if media == -1 { edits -= Int64(duration) * Int64(trackScale) / Int64(scale) }
                    else { edits += media; break }
                }
            }
            var sync: Set<Int>?
            if let box = children.first(where: { $0.type == "stss" }) {
                let entries = Int(try ContainerBox.word(box.payload, 4))
                guard entries <= count else { throw MatroskaError.invalid("oversized sync table") }
                sync = Set(try (0..<entries).map { Int(try ContainerBox.word(box.payload, 8 + $0 * 4)) - 1 })
            }
            var packets: [MatroskaPacket] = [], descriptionsByPacket: [UInt32] = [], sample = 0, record = 0, dts: Int64 = 0
            for chunk in 1...chunkCount {
                while try record + 1 < records && UInt64(chunk) >= ContainerBox.word(mapping, 8 + (record + 1) * 12) { record += 1 }
                let samples = Int(try ContainerBox.word(mapping, 12 + record * 12)), description = UInt32(try ContainerBox.word(mapping, 16 + record * 12))
                guard samples <= count - sample, description > 0, description <= descriptions.count else { throw MatroskaError.invalid("invalid chunk sample description") }
                var offset = try ContainerBox.word(chunks.payload, 8 + (chunk - 1) * width, width)
                for _ in 0..<samples {
                    guard offset <= UInt64(identity!.size), sizes[sample] <= UInt64(identity!.size) - offset,
                          sizes[sample] <= 64 * 1024 * 1024, durations[sample] > 0 else { throw MatroskaError.invalid("invalid compressed sample extent") }
                    let pts = dts + cts[sample] - edits
                    packets.append(MatroskaPacket(offset: offset, size: UInt32(sizes[sample]), ptsNS: CMTimeConvertScale(CMTime(value: pts, timescale: Int32(trackScale)), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value,
                        durationNS: CMTimeConvertScale(CMTime(value: durations[sample], timescale: Int32(trackScale)), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value, sync: sync?.contains(sample) ?? true))
                    descriptionsByPacket.append(description)
                    dts += durations[sample]; offset += sizes[sample]; sample += 1
                }
            }
            guard sample == count else { throw MatroskaError.invalid("incomplete sample coverage") }
            result.append(NativeMovieTrack(template: track, id: id, scale: trackScale, handler: handler,
                descriptions: descriptions, packets: packets, durations: durations.map { UInt32($0) }, cts: cts.map { Int32($0) }, descriptionIndices: descriptionsByPacket))
        }
        tracks = result
        try identity?.validate(file)
    }

    private static func fragments(file: FileHandle, locations: [ContainerBox.Location], movie: ContainerBox,
        template: ContainerBox, id: UInt32, scale: UInt32, movieScale: UInt32, handler: String,
        descriptions: [ContainerBox]) throws -> NativeMovieTrack? {
        var defaultDescription: UInt64 = 1, defaultDuration: UInt64 = 0, defaultSize: UInt64 = 0, defaultFlags: UInt64 = 0
        if let mvex = try ContainerBox.parse(movie.payload).first(where: { $0.type == "mvex" }) {
            for trex in try ContainerBox.parse(mvex.payload) where try trex.type == "trex" && ContainerBox.word(trex.payload, 4) == id {
                defaultDescription = try ContainerBox.word(trex.payload, 8); defaultDuration = try ContainerBox.word(trex.payload, 12)
                defaultSize = try ContainerBox.word(trex.payload, 16); defaultFlags = try ContainerBox.word(trex.payload, 20)
            }
        }
        var packets: [MatroskaPacket] = [], durations: [UInt32] = [], composition: [Int32] = [], indices: [UInt32] = []
        var nextDTS: Int64 = 0, flatDTS: Int64 = 0, mediaEnd: Int64 = 0
        for location in locations where location.type == "moof" {
            guard location.size <= 16 * 1024 * 1024 else { throw MatroskaError.invalid("oversized fragment metadata") }
            let moof = try ContainerBox.parse(EBML.read(file, location.offset, Int(location.size)))[0]
            for traf in try ContainerBox.parse(moof.payload) where traf.type == "traf" {
                let children = try ContainerBox.parse(traf.payload)
                guard let tfhd = children.first(where: { $0.type == "tfhd" }), try ContainerBox.word(tfhd.payload, 4) == id else { continue }
                let flags = try ContainerBox.word(tfhd.payload, 0) & 0xffffff
                var cursor = 8, base = location.offset
                if flags & 1 != 0 { base = try ContainerBox.word(tfhd.payload, cursor, 8); cursor += 8 }
                var description = defaultDescription, duration = defaultDuration, size = defaultSize, sampleFlags = defaultFlags
                if flags & 2 != 0 { description = try ContainerBox.word(tfhd.payload, cursor); cursor += 4 }
                if flags & 8 != 0 { duration = try ContainerBox.word(tfhd.payload, cursor); cursor += 4 }
                if flags & 16 != 0 { size = try ContainerBox.word(tfhd.payload, cursor); cursor += 4 }
                if flags & 32 != 0 { sampleFlags = try ContainerBox.word(tfhd.payload, cursor) }
                guard description > 0, description <= descriptions.count else { throw MatroskaError.invalid("invalid fragment sample description") }
                var dts = nextDTS
                if let tfdt = children.first(where: { $0.type == "tfdt" }) {
                    dts = Int64(try ContainerBox.word(tfdt.payload, 4, tfdt.payload.first == 1 ? 8 : 4))
                }
                let following = locations.first { $0.type == "mdat" && $0.offset >= location.offset + location.size }
                var packetOffset = following.map { $0.offset + $0.header } ?? base
                for run in children where run.type == "trun" {
                    let flags = try ContainerBox.word(run.payload, 0) & 0xffffff
                    let count = Int(try ContainerBox.word(run.payload, 4)); var cursor = 8
                    guard count <= 1_000_000, packets.count + count <= 10_000_000 else { throw MatroskaError.invalid("fragment index exceeds metadata budget") }
                    if flags & 1 != 0 {
                        let delta = Int64(Int32(bitPattern: UInt32(try ContainerBox.word(run.payload, cursor))))
                        guard Int64(base) + delta >= 0 else { throw MatroskaError.invalid("invalid fragment data offset") }
                        packetOffset = UInt64(Int64(base) + delta); cursor += 4
                    }
                    var firstFlags = sampleFlags
                    if flags & 4 != 0 { firstFlags = try ContainerBox.word(run.payload, cursor); cursor += 4 }
                    for index in 0..<count {
                        var span = duration, bytes = size, marks = index == 0 ? firstFlags : sampleFlags, cts: Int64 = 0
                        if flags & 0x100 != 0 { span = try ContainerBox.word(run.payload, cursor); cursor += 4 }
                        if flags & 0x200 != 0 { bytes = try ContainerBox.word(run.payload, cursor); cursor += 4 }
                        if flags & 0x400 != 0 { marks = try ContainerBox.word(run.payload, cursor); cursor += 4 }
                        if flags & 0x800 != 0 {
                            let raw = UInt32(try ContainerBox.word(run.payload, cursor)); cursor += 4
                            cts = run.payload.first == 1 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
                        }
                        guard span > 0, span <= UInt32.max, bytes > 0, bytes <= 64 * 1024 * 1024,
                              let flatCTS = Int32(exactly: dts + cts - flatDTS) else { throw MatroskaError.invalid("invalid fragment sample") }
                        let pts = CMTimeConvertScale(CMTime(value: dts + cts, timescale: Int32(scale)), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                        let length = CMTimeConvertScale(CMTime(value: Int64(span), timescale: Int32(scale)), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                        packets.append(MatroskaPacket(offset: packetOffset, size: UInt32(bytes), ptsNS: pts, durationNS: length, sync: marks & 0x10000 == 0))
                        durations.append(UInt32(span)); composition.append(flatCTS); indices.append(UInt32(description))
                        packetOffset += bytes; dts += Int64(span); flatDTS += Int64(span); mediaEnd = max(mediaEnd, dts + cts)
                    }
                }
                nextDTS = dts
            }
        }
        guard !packets.isEmpty else { return nil }
        func runs(_ name: String, _ values: [UInt32], version: UInt32 = 0) -> ContainerBox {
            var rows: [(UInt32, UInt32)] = []
            for value in values { if rows.last?.1 == value { rows[rows.count - 1].0 += 1 } else { rows.append((1, value)) } }
            return ContainerBox(type: name, payload: EBML.uint(UInt64(version), width: 4) + EBML.uint(UInt64(rows.count), width: 4)
                + rows.reduce(Data()) { $0 + EBML.uint(UInt64($1.0), width: 4) + EBML.uint(UInt64($1.1), width: 4) })
        }
        func rewrite(_ box: ContainerBox) throws -> ContainerBox {
            var box = box
            switch box.type {
            case "stsz": box.payload = Data(count: 8) + EBML.uint(UInt64(packets.count), width: 4) + packets.reduce(Data()) { $0 + EBML.uint(UInt64($1.size), width: 4) }
            case "stts": return runs("stts", durations)
            case "ctts": return runs("ctts", composition.map { UInt32(bitPattern: $0) }, version: 0x01000000)
            case "tkhd", "mdhd":
                let wide = box.payload.first == 1, offset = box.type == "tkhd" ? (wide ? 28 : 20) : (wide ? 24 : 16)
                let value = box.type == "tkhd" ? UInt64(mediaEnd) * UInt64(movieScale) / UInt64(scale) : UInt64(mediaEnd)
                try ContainerBox.replace(&box.payload, at: offset, value: value, width: wide ? 8 : 4)
            case "trak", "mdia", "minf", "stbl":
                var children = try ContainerBox.parse(box.payload).map(rewrite)
                if box.type == "stbl" && !children.contains(where: { $0.type == "ctts" }) { children.append(runs("ctts", composition.map { UInt32(bitPattern: $0) }, version: 0x01000000)) }
                box.payload = children.reduce(Data()) { $0 + $1.data }
            default: break
            }
            return box
        }
        return NativeMovieTrack(template: try rewrite(template), id: id, scale: scale, handler: handler,
            descriptions: descriptions, packets: packets, durations: durations, cts: composition, descriptionIndices: indices)
    }

    private static func compactPCM(file: FileHandle, track: ContainerBox, id: UInt32, scale: UInt32,
        descriptions: [ContainerBox], table: ContainerBox, samples: Int, bytesPerSample: UInt64, ticks: UInt64) throws -> NativeMovieTrack {
        let children = try ContainerBox.parse(table.payload)
        guard let chunks = children.first(where: { $0.type == "stco" || $0.type == "co64" }) else { throw MatroskaError.invalid("PCM has no chunk table") }
        let count = Int(try ContainerBox.word(chunks.payload, 4)), width = chunks.type == "co64" ? 8 : 4
        let mapping = try table.child("stsc").payload, records = Int(try ContainerBox.word(mapping, 4))
        guard count > 0, records > 0, records <= count, ticks > 0 else { throw MatroskaError.invalid("invalid PCM sample tables") }
        var packets: [MatroskaPacket] = [], durations: [UInt32] = [], sampleCounts: [UInt32] = [], record = 0, total: UInt64 = 0
        for chunk in 1...count {
            while try record + 1 < records && UInt64(chunk) >= ContainerBox.word(mapping, 8 + (record + 1) * 12) { record += 1 }
            var remaining = try ContainerBox.word(mapping, 12 + record * 12)
            var offset = try ContainerBox.word(chunks.payload, 8 + (chunk - 1) * width, width)
            while remaining > 0 {
                let n = min(remaining, 1024 * 1024 / bytesPerSample)
                guard n > 0, n * ticks <= UInt32.max else { throw MatroskaError.invalid("invalid PCM sample duration") }
                let start = CMTimeConvertScale(CMTime(value: Int64(total * ticks), timescale: Int32(scale)), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                let span = CMTimeConvertScale(CMTime(value: Int64(n * ticks), timescale: Int32(scale)), timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
                packets.append(MatroskaPacket(offset: offset, size: UInt32(n * bytesPerSample), ptsNS: start, durationNS: span, sync: true))
                durations.append(UInt32(n * ticks)); sampleCounts.append(UInt32(n))
                offset += n * bytesPerSample; total += n; remaining -= n
            }
        }
        guard total == samples else { throw MatroskaError.invalid("PCM sample coverage mismatch") }
        return NativeMovieTrack(template: track, id: id, scale: scale, handler: "soun", descriptions: descriptions,
            packets: packets, durations: durations, cts: Array(repeating: 0, count: packets.count),
            descriptionIndices: Array(repeating: 1, count: packets.count), sampleCounts: sampleCounts)
    }
}

enum NativeContainerAudio {
    /// Audio sample entries are preserved byte for byte, including unrecognized
    /// codec boxes. Rebuild only chunk locations and track IDs on the owned output.
    static func append(source: NativeMovieFile, to destination: URL) throws {
        let tracks = source.tracks.filter { $0.handler == "soun" }
        guard !tracks.isEmpty else { return }
        let input = try FileHandle(forReadingFrom: source.url), output = try FileHandle(forUpdating: destination)
        defer { try? input.close(); try? output.close() }
        try source.identity?.validate(input)
        let (old, target) = try ContainerBox.movie(output, ContainerBox.locations(output))
        var children = try ContainerBox.parse(target.payload)
        guard let headerIndex = children.firstIndex(where: { $0.type == "mvhd" }) else { throw MatroskaError.invalid("missing movie header") }
        let targetScale = try ContainerBox.word(children[headerIndex].payload, children[headerIndex].payload.first == 1 ? 20 : 12)
        var nextID: UInt64 = 1
        for track in children where track.type == "trak" {
            let header = try track.child("tkhd").payload
            nextID = max(nextID, try ContainerBox.word(header, header.first == 1 ? 20 : 12) + 1)
        }
        let trackIDs = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, nextID + UInt64($0.offset)) })
        var referenceIDs = trackIDs
        func videoID(_ movie: ContainerBox) throws -> UInt32? {
            for track in try ContainerBox.parse(movie.payload) where track.type == "trak" {
                let handler = try track.child("mdia").child("hdlr").payload
                if handler.count >= 12 && String(decoding: handler[8..<12], as: UTF8.self) == "vide" {
                    let header = try track.child("tkhd").payload
                    return UInt32(try ContainerBox.word(header, header.first == 1 ? 20 : 12))
                }
            }
            return nil
        }
        if let originalVideo = try videoID(source.movie), let encodedVideo = try videoID(target) { referenceIDs[originalVideo] = UInt64(encodedVideo) }
        var usedGroups: Set<UInt64> = []
        for track in children where track.type == "trak" {
            let header = try track.child("tkhd").payload
            let group = try ContainerBox.word(header, header.first == 1 ? 46 : 34, 2)
            if group != 0 { usedGroups.insert(group) }
        }
        var groups: [UInt64: UInt64] = [:]
        for track in tracks {
            let mdatSize = track.packets.reduce(UInt64(16)) { $0 + UInt64($1.size) }
            try output.seekToEnd()
            try output.write(contentsOf: EBML.uint(1, width: 4) + Data("mdat".utf8) + EBML.uint(mdatSize, width: 8))
            var positions: [UInt64] = []
            for packet in track.packets {
                if Task.isCancelled { throw CancellationError() }
                positions.append(try output.offset())
                var remaining = UInt64(packet.size), offset = packet.offset
                while remaining > 0 {
                    let count = Int(min(1024 * 1024, remaining))
                    try output.write(contentsOf: EBML.read(input, offset, count))
                    offset += UInt64(count); remaining -= UInt64(count)
                }
            }
            func rewrite(_ box: ContainerBox) throws -> ContainerBox {
                var box = box
                switch box.type {
                case "stco", "co64":
                    box.type = "co64"
                    box.payload = Data(count: 4) + EBML.uint(UInt64(positions.count), width: 4) + positions.reduce(Data()) { $0 + EBML.uint($1, width: 8) }
                case "stsc":
                    var runs: [(UInt32, UInt32, UInt32)] = []
                    for (index, description) in track.descriptionIndices.enumerated() {
                        let count = track.sampleCounts.isEmpty ? 1 : track.sampleCounts[index]
                        if runs.last?.1 != description || runs.last?.2 != count { runs.append((UInt32(index + 1), description, count)) }
                    }
                    box.payload = Data(count: 4) + EBML.uint(UInt64(runs.count), width: 4) + runs.reduce(Data()) {
                        $0 + EBML.uint(UInt64($1.0), width: 4) + EBML.uint(UInt64($1.2), width: 4) + EBML.uint(UInt64($1.1), width: 4)
                    }
                case "tkhd":
                    let wide = box.payload.first == 1
                    try ContainerBox.replace(&box.payload, at: wide ? 20 : 12, value: trackIDs[track.id]!)
                    let groupOffset = wide ? 46 : 34
                    let originalGroup = try ContainerBox.word(box.payload, groupOffset, 2)
                    if originalGroup != 0 {
                        if groups[originalGroup] == nil {
                            let group = usedGroups.contains(originalGroup) ? (1...UInt64(Int16.max)).first { !usedGroups.contains($0) } : originalGroup
                            guard let group else { throw MatroskaError.invalid("no free audio alternate group") }
                            groups[originalGroup] = group; usedGroups.insert(group)
                        }
                        try ContainerBox.replace(&box.payload, at: groupOffset, value: groups[originalGroup]!, width: 2)
                    }
                    let duration = try ContainerBox.word(box.payload, wide ? 28 : 20, wide ? 8 : 4)
                    try ContainerBox.replace(&box.payload, at: wide ? 28 : 20, value: (duration * targetScale + UInt64(source.scale) - 1) / UInt64(source.scale), width: wide ? 8 : 4)
                case "elst":
                    let wide = box.payload.first == 1, count = Int(try ContainerBox.word(box.payload, 4))
                    for n in 0..<count {
                        let offset = 8 + n * (wide ? 20 : 12), width = wide ? 8 : 4
                        let duration = try ContainerBox.word(box.payload, offset, width)
                        try ContainerBox.replace(&box.payload, at: offset, value: (duration * targetScale + UInt64(source.scale) - 1) / UInt64(source.scale), width: width)
                    }
                case "tref":
                    box.payload = try ContainerBox.parse(box.payload).map { reference in
                        var reference = reference
                        guard reference.payload.count % 4 == 0 else { throw MatroskaError.invalid("invalid track reference array") }
                        for offset in stride(from: 0, to: reference.payload.count, by: 4) {
                            let original = UInt32(try ContainerBox.word(reference.payload, offset))
                            if let relocated = referenceIDs[original] { try ContainerBox.replace(&reference.payload, at: offset, value: relocated) }
                        }
                        return reference
                    }.reduce(Data()) { $0 + $1.data }
                case "trak", "mdia", "minf", "stbl", "edts": box.payload = try ContainerBox.parse(box.payload).map(rewrite).reduce(Data()) { $0 + $1.data }
                default: break
                }
                return box
            }
            children.append(try rewrite(track.template)); nextID += 1
        }
        try source.identity?.validate(input)
        let headerWide = children[headerIndex].payload.first == 1
        var movieDuration = try ContainerBox.word(children[headerIndex].payload, headerWide ? 24 : 16, headerWide ? 8 : 4)
        for track in children where track.type == "trak" {
            let header = try track.child("tkhd").payload, wide = header.first == 1
            movieDuration = max(movieDuration, try ContainerBox.word(header, wide ? 28 : 20, wide ? 8 : 4))
        }
        try ContainerBox.replace(&children[headerIndex].payload, at: headerWide ? 24 : 16, value: movieDuration, width: headerWide ? 8 : 4)
        let end = children[headerIndex].payload.count - 4
        try ContainerBox.replace(&children[headerIndex].payload, at: end, value: nextID)
        let movie = ContainerBox(type: "moov", payload: children.reduce(Data()) { $0 + $1.data })
        try output.seekToEnd(); try output.write(contentsOf: movie.data); try output.synchronize()
        try output.seek(toOffset: old.offset + 4); try output.write(contentsOf: Data("free".utf8)); try output.synchronize()
    }
}
