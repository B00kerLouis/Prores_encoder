// Copyright © 2026 B00kerLouis. All rights reserved.
// Native Hybrid MOV: fragmented while encoding, flat sample tables at finish.
// Implements the documented container design; no OBS source is incorporated.

import Foundation
import CryptoKit
import Darwin
@preconcurrency import AVFoundation

struct VTParallelSubdivision: Sendable {
    let hasPrevious: Bool
    let hasNext: Bool
}

enum HybridMOVError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return "Hybrid MOV: \(message)" }
    }
}

private func hybridRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw HybridMOVError.invalid(message) }
}

/// Small metadata boxes only. Media payload is always copied in bounded blocks.
struct HybridBox {
    var type: String
    var payload: Data

    var data: Data { Self.u32(UInt32(payload.count + 8)) + Data(type.utf8) + payload }
    static func u32(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
    static func u64(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }
    static func full(_ type: String, _ flags: UInt32 = 0, _ body: Data = Data()) -> HybridBox {
        HybridBox(type: type, payload: u32(flags) + body)
    }
    static func word(_ data: Data, _ offset: Int) throws -> UInt32 {
        try hybridRequire(offset >= 0 && offset <= data.count - 4, "truncated 32-bit field")
        return data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    static func wide(_ data: Data, _ offset: Int) throws -> UInt64 {
        try hybridRequire(offset >= 0 && offset <= data.count - 8, "truncated 64-bit field")
        return data[offset..<offset + 8].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static func parse(_ data: Data) throws -> [HybridBox] {
        var result: [HybridBox] = [], cursor = 0
        while cursor < data.count {
            let size = Int(try word(data, cursor))
            try hybridRequire(size >= 8 && size <= data.count - cursor, "invalid metadata box size")
            guard let type = String(data: data[cursor + 4..<cursor + 8], encoding: .isoLatin1) else {
                throw HybridMOVError.invalid("invalid box type")
            }
            result.append(HybridBox(type: type, payload: data.subdata(in: cursor + 8..<cursor + size)))
            cursor += size
        }
        return result
    }
    func children() throws -> [HybridBox] { try Self.parse(payload) }
    func child(_ type: String) throws -> HybridBox {
        guard let result = try children().first(where: { $0.type == type }) else {
            throw HybridMOVError.invalid("missing \(type)")
        }
        return result
    }
    func replacingChildren(_ transform: (HybridBox) throws -> [HybridBox]) throws -> HybridBox {
        HybridBox(type: type, payload: try children().flatMap(transform).reduce(Data()) { $0 + $1.data })
    }
}

private struct HybridSample: Codable {
    var offset: UInt64
    let size: UInt32
    var duration: UInt32
    let cts: Int32
    let sync: Bool
}

private struct HybridTrack {
    let template: HybridBox
    let id: UInt32
    let scale: UInt32
    let handler: String
    let stsd: HybridBox
    var samples: [HybridSample]
}

private struct HybridChunk {
    let movie: HybridBox
    let movieScale: UInt32
    let tracks: [HybridTrack]

    init(url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        var cursor: UInt64 = 0, movie: HybridBox?
        var mediaRanges: [Range<UInt64>] = []
        while cursor < length {
            try file.seek(toOffset: cursor)
            let header = try file.read(upToCount: 16) ?? Data()
            try hybridRequire(header.count >= 8, "truncated chunk box header")
            var size = UInt64(try HybridBox.word(header, 0)), headerSize: UInt64 = 8
            if size == 1 { size = try HybridBox.wide(header, 8); headerSize = 16 }
            if size == 0 { size = length - cursor }
            try hybridRequire(size >= headerSize && size <= length - cursor, "truncated chunk")
            let type = String(data: header[4..<8], encoding: .isoLatin1)
            if type == "moov" {
                try hybridRequire(size < 64 * 1024 * 1024, "oversized chunk index")
                try file.seek(toOffset: cursor + headerSize)
                let payload = try file.read(upToCount: Int(size - headerSize)) ?? Data()
                try hybridRequire(payload.count == Int(size - headerSize), "short chunk index")
                movie = HybridBox(type: "moov", payload: payload)
            }
            if type == "mdat" { mediaRanges.append(cursor + headerSize..<cursor + size) }
            cursor += size
        }
        guard let movie else { throw HybridMOVError.invalid("chunk has no closing index") }
        self.movie = movie
        let mvhd = try movie.child("mvhd").payload
        movieScale = try HybridBox.word(mvhd, mvhd.first == 1 ? 20 : 12)
        try hybridRequire(movieScale > 0, "zero movie scale")
        tracks = try movie.children().filter { $0.type == "trak" }.map { trak in
            let tkhd = try trak.child("tkhd").payload
            let id = try HybridBox.word(tkhd, tkhd.first == 1 ? 20 : 12)
            let mdia = try trak.child("mdia")
            let mdhd = try mdia.child("mdhd").payload
            let scale = try HybridBox.word(mdhd, mdhd.first == 1 ? 20 : 12)
            let hdlr = try mdia.child("hdlr").payload
            try hybridRequire(hdlr.count >= 12 && scale > 0, "invalid track header")
            let handler = String(data: hdlr[8..<12], encoding: .isoLatin1) ?? ""
            try hybridRequire(handler == "vide" || handler == "tmcd", "unsupported chunk track \(handler)")
            let table = try mdia.child("minf").child("stbl")
            let stsd = try table.child("stsd")
            try hybridRequire(try HybridBox.word(stsd.payload, 4) == 1, "multiple chunk sample descriptions")
            let stsz = try table.child("stsz").payload
            let fixedSize = try HybridBox.word(stsz, 4)
            let count = Int(try HybridBox.word(stsz, 8))
            try hybridRequire(count > 0 && count <= 1_000_000, "invalid chunk sample count")
            func expanded(_ name: String, signed: Bool = false) throws -> [Int64]? {
                guard let box = try table.children().first(where: { $0.type == name }) else { return nil }
                let n = Int(try HybridBox.word(box.payload, 4))
                try hybridRequire(n <= count && box.payload.count == 8 + n * 8, "invalid \(name) table")
                var values: [Int64] = []
                for i in 0..<n {
                    let run = Int(try HybridBox.word(box.payload, 8 + i * 8))
                    let raw = try HybridBox.word(box.payload, 12 + i * 8)
                    try hybridRequire(run > 0 && run <= count - values.count, "invalid \(name) run")
                    // AVAssetWriter's QuickTime flavor can emit signed CTS
                    // offsets in a version-0 ctts after VT subdivision hints.
                    // Normalize these into an explicit version-1 final table.
                    values += repeatElement(signed
                        ? Int64(Int32(bitPattern: raw)) : Int64(raw), count: run)
                }
                try hybridRequire(values.count == count, "incomplete \(name)")
                return values
            }
            guard let durations = try expanded("stts") else { throw HybridMOVError.invalid("missing sample timing") }
            let offsets = try expanded("ctts", signed: true) ?? Array(repeating: 0, count: count)
            var edit: Int64 = 0
            if let edts = try trak.children().first(where: { $0.type == "edts" }) {
                let elst = try edts.child("elst").payload
                try hybridRequire(try HybridBox.word(elst, 4) == 1, "unsupported multiple edits")
                edit = elst.first == 1 ? Int64(bitPattern: try HybridBox.wide(elst, 16))
                    : Int64(Int32(bitPattern: try HybridBox.word(elst, 12)))
                try hybridRequire(edit >= 0, "unsupported empty edit")
            }
            var sync: Set<Int>?
            if let stss = try table.children().first(where: { $0.type == "stss" }) {
                let n = Int(try HybridBox.word(stss.payload, 4))
                try hybridRequire(n <= count && stss.payload.count == 8 + n * 4, "invalid sync table")
                sync = Set(try (0..<n).map { Int(try HybridBox.word(stss.payload, 8 + $0 * 4)) })
            }
            let stsc = try table.child("stsc").payload
            let runs = Int(try HybridBox.word(stsc, 4))
            try hybridRequire(runs > 0 && runs <= count && stsc.count == 8 + runs * 12, "invalid chunk map")
            let children = try table.children()
            guard let chunkOffsets = children.first(where: { $0.type == "stco" || $0.type == "co64" }) else {
                throw HybridMOVError.invalid("missing chunk offsets")
            }
            let chunkCount = Int(try HybridBox.word(chunkOffsets.payload, 4))
            try hybridRequire(chunkCount > 0 && chunkCount <= count, "invalid chunk offset count")
            var samples: [HybridSample] = [], runIndex = 0
            for chunk in 1...chunkCount {
                while runIndex + 1 < runs,
                      chunk >= Int(try HybridBox.word(stsc, 8 + (runIndex + 1) * 12)) { runIndex += 1 }
                try hybridRequire(try HybridBox.word(stsc, 16 + runIndex * 12) == 1, "unsupported description index")
                let perChunk = Int(try HybridBox.word(stsc, 12 + runIndex * 12))
                try hybridRequire(perChunk > 0 && perChunk <= count - samples.count, "chunk sample count exceeds table")
                var byte = chunkOffsets.type == "co64"
                    ? try HybridBox.wide(chunkOffsets.payload, 8 + (chunk - 1) * 8)
                    : UInt64(try HybridBox.word(chunkOffsets.payload, 8 + (chunk - 1) * 4))
                for _ in 0..<perChunk {
                    let i = samples.count
                    let size = fixedSize != 0 ? fixedSize : try HybridBox.word(stsz, 12 + i * 4)
                    try hybridRequire(size > 0 && mediaRanges.contains(where: {
                        byte >= $0.lowerBound && byte <= $0.upperBound && UInt64(size) <= $0.upperBound - byte
                    }), "sample outside complete media data")
                    let cts = offsets[i] - edit
                    try hybridRequire(durations[i] > 0 && durations[i] <= Int64(UInt32.max)
                        && cts >= Int64(Int32.min) && cts <= Int64(Int32.max), "sample timing out of range")
                    samples.append(HybridSample(offset: byte, size: size, duration: UInt32(durations[i]),
                        cts: Int32(cts), sync: sync?.contains(i + 1) ?? true))
                    byte += UInt64(size)
                }
            }
            try hybridRequire(samples.count == count, "incomplete chunk sample map")
            return HybridTrack(template: trak, id: id, scale: scale, handler: handler, stsd: stsd, samples: samples)
        }
        try hybridRequire(tracks.filter { $0.handler == "vide" }.count == 1, "requires one video track")
    }
}

private struct HybridFragment: Codable {
    let index: Int
    let start: UInt64
    let end: UInt64
    let sha256: String
    let video: [HybridSample]
    let timecode: [HybridSample]
    var hashHeaderSkip: Int? = nil
}

private struct HybridJournal: Codable {
    let version: Int
    let fingerprint: String
    var movieTemplate: Data?
    var fragments: [HybridFragment] = []
    var finalIndexHash: String?
    var finalSize: UInt64?
    var subdivisionFrames: Int? = nil
}

private struct HybridJournalEnvelope: Codable {
    let payload: Data
    let sha256: String
}

private func hybridLoad(_ url: URL) throws -> HybridJournal {
    let envelope = try JSONDecoder().decode(HybridJournalEnvelope.self, from: Data(contentsOf: url))
    try hybridRequire(hybridHash(envelope.payload) == envelope.sha256, "checkpoint journal checksum mismatch")
    return try JSONDecoder().decode(HybridJournal.self, from: envelope.payload)
}

private func hybridHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func hybridLUTHash(_ lut: CubeLUT?) -> String {
    guard let lut else { return "none" }
    var hash = SHA256()
    func table(size: Int, values: [SIMD4<Float>], low: SIMD3<Float>, high: SIMD3<Float>) {
        hash.update(data: HybridBox.u32(UInt32(size)))
        for i in 0..<3 {
            hash.update(data: HybridBox.u32(low[i].bitPattern))
            hash.update(data: HybridBox.u32(high[i].bitPattern))
        }
        for value in values {
            for i in 0..<4 { hash.update(data: HybridBox.u32(value[i].bitPattern)) }
        }
    }
    if let t = lut.oneDimensional { table(size: t.size, values: t.values, low: t.domainMin, high: t.domainMax) }
    else { hash.update(data: HybridBox.u32(0)) }
    if let t = lut.threeDimensional { table(size: t.size, values: t.values, low: t.domainMin, high: t.domainMax) }
    else { hash.update(data: HybridBox.u32(0)) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Persist file data before publishing its checkpoint. The directory is synced
/// after atomic rename on local filesystems; SMB may reject directory fsync.
private func hybridSave(_ journal: HybridJournal, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let staging = url.appendingPathExtension("new")
    let payload = try encoder.encode(journal)
    try encoder.encode(HybridJournalEnvelope(payload: payload, sha256: hybridHash(payload))).write(to: staging)
    let handle = try FileHandle(forWritingTo: staging)
    try handle.synchronize()
    try handle.close()
    guard rename(staging.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
    if directory >= 0 { _ = fsync(directory); close(directory) }
}

private func hybridHashRange(_ file: FileHandle, _ range: Range<UInt64>) throws -> String {
    try file.seek(toOffset: range.lowerBound)
    var remaining = range.count, hash = SHA256()
    while remaining > 0 {
        let data = try file.read(upToCount: min(remaining, 4 * 1024 * 1024)) ?? Data()
        try hybridRequire(!data.isEmpty, "short read validating checkpoint")
        hash.update(data: data)
        remaining -= data.count
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Rebuild only metadata. Packet offsets already point at their final locations.
private func hybridMovie(template: HybridBox, tracks: [HybridTrack], empty: Bool) throws -> HybridBox {
    let mvhd = try template.child("mvhd").payload
    let movieScale = try HybridBox.word(mvhd, mvhd.first == 1 ? 20 : 12)
    let duration = tracks.filter { $0.handler == "vide" }.map {
        $0.samples.reduce(UInt64(0)) { $0 + UInt64($1.duration) } * UInt64(movieScale) / UInt64($0.scale)
    }.max() ?? 0
    func timed(_ box: HybridBox, value: UInt64, at32: Int, at64: Int) throws -> HybridBox {
        var result = box
        let wide = box.payload.first == 1
        try hybridRequire(wide || value <= UInt64(UInt32.max), "32-bit duration overflow")
        let offset = wide ? at64 : at32
        try hybridRequire(offset + (wide ? 8 : 4) <= result.payload.count, "short duration box")
        result.payload.replaceSubrange(offset..<offset + (wide ? 8 : 4),
            with: wide ? HybridBox.u64(value) : HybridBox.u32(UInt32(value)))
        return result
    }
    func table(_ track: HybridTrack) -> HybridBox {
        let samples = empty ? [] : track.samples
        func runs(_ type: String, _ values: [UInt32], flags: UInt32 = 0) -> HybridBox {
            var pairs: [(UInt32, UInt32)] = []
            for value in values {
                if let last = pairs.last, last.1 == value { pairs[pairs.count - 1].0 += 1 }
                else { pairs.append((1, value)) }
            }
            return .full(type, flags, HybridBox.u32(UInt32(pairs.count))
                + pairs.reduce(Data()) { $0 + HybridBox.u32($1.0) + HybridBox.u32($1.1) })
        }
        var boxes = [track.stsd, runs("stts", samples.map(\.duration))]
        if samples.contains(where: { $0.cts != 0 }) {
            boxes.append(runs("ctts", samples.map { UInt32(bitPattern: $0.cts) }, flags: 0x01000000))
        }
        boxes.append(.full("stsc", 0, HybridBox.u32(samples.isEmpty ? 0 : 1)
            + (samples.isEmpty ? Data() : HybridBox.u32(1) + HybridBox.u32(1) + HybridBox.u32(1))))
        boxes.append(.full("stsz", 0, HybridBox.u32(0) + HybridBox.u32(UInt32(samples.count))
            + samples.reduce(Data()) { $0 + HybridBox.u32($1.size) }))
        boxes.append(.full("co64", 0, HybridBox.u32(UInt32(samples.count))
            + samples.reduce(Data()) { $0 + HybridBox.u64($1.offset) }))
        if track.handler == "vide", samples.contains(where: { !$0.sync }) {
            let keys = samples.enumerated().filter { $0.element.sync }.map { UInt32($0.offset + 1) }
            boxes.append(.full("stss", 0, HybridBox.u32(UInt32(keys.count))
                + keys.reduce(Data()) { $0 + HybridBox.u32($1) }))
        }
        return HybridBox(type: "stbl", payload: boxes.reduce(Data()) { $0 + $1.data })
    }
    var result = try template.replacingChildren { box in
        switch box.type {
        case "mvhd": return [try timed(box, value: empty ? 0 : duration, at32: 16, at64: 24)]
        case "mvex": return []
        case "trak":
            let header = try box.child("tkhd").payload
            let id = try HybridBox.word(header, header.first == 1 ? 20 : 12)
            guard let track = tracks.first(where: { $0.id == id }) else { return [] }
            let mediaDuration = empty ? 0 : track.samples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }
            return [try box.replacingChildren { child in
                switch child.type {
                case "edts": return [] // CTS has already been normalized by the edit's media time.
                case "tkhd": return [try timed(child, value: empty ? 0 : duration, at32: 20, at64: 28)]
                case "mdia": return [try child.replacingChildren { mdia in
                    if mdia.type == "mdhd" {
                        var header = try timed(mdia, value: mediaDuration, at32: 16, at64: 24)
                        let scaleOffset = header.payload.first == 1 ? 20 : 12
                        header.payload.replaceSubrange(scaleOffset..<scaleOffset + 4, with: HybridBox.u32(track.scale))
                        return [header]
                    }
                    if mdia.type == "minf" { return [try mdia.replacingChildren { $0.type == "stbl" ? [table(track)] : [$0] }] }
                    return [mdia]
                }]
                default: return [child]
                }
            }]
        default: return [box]
        }
    }
    if empty {
        let trex = tracks.map { HybridBox.full("trex", 0, HybridBox.u32($0.id) + HybridBox.u32(1)
            + HybridBox.u32(0) + HybridBox.u32(0) + HybridBox.u32(0)).data }.reduce(Data(), +)
        result.payload += HybridBox(type: "mvex", payload: trex).data
    }
    return result
}

/// Writes a complete fragment, flushes it, then publishes a hash-checked journal.
/// At most one chunk of compressed media is staged per active VT session.
private final class HybridMuxer {
    let file: FileHandle
    let stateURL: URL
    var journal: HybridJournal
    var template: HybridBox?
    var tracks: [HybridTrack] = []
    static let ftyp = HybridBox(type: "ftyp", payload: Data("qt  ".utf8) + HybridBox.u32(0) + Data("qt  ".utf8)).data
    static let placeholder = HybridBox(type: "wide", payload: Data(repeating: 0, count: 8)).data
    var committedFrames: Int { journal.fragments.reduce(0) { $0 + $1.video.count } }

    init(workingURL: URL, stateURL: URL, fingerprint: String, subdivisionFrames: Int) throws {
        self.stateURL = stateURL
        if FileManager.default.fileExists(atPath: stateURL.path) {
            journal = try hybridLoad(stateURL)
            try hybridRequire(journal.version == 1 && journal.fingerprint == fingerprint,
                "source or options changed; use a different output path")
            file = try FileHandle(forUpdating: workingURL)
            if let data = journal.movieTemplate {
                guard let movie = try HybridBox.parse(data).first else { throw HybridMOVError.invalid("missing saved template") }
                template = movie
                // Recover track descriptors from a tiny temporary MOV is unnecessary:
                // the journal stores the original flat movie metadata.
                tracks = try Self.descriptors(movie)
            }
            let length = try file.seekToEnd()
            var expectedStart = UInt64(Self.ftyp.count + Self.placeholder.count)
            if let template {
                expectedStart += UInt64(try hybridMovie(template: template, tracks: tracks, empty: true).data.count)
            }
            for (index, fragment) in journal.fragments.enumerated() {
                try hybridRequire(fragment.index == index && fragment.start == expectedStart
                    && fragment.end > fragment.start && fragment.end <= length,
                    "invalid fragment checkpoint boundary")
                if fragment.hashHeaderSkip == 16 {
                    try file.seek(toOffset: fragment.start)
                    let header = try file.read(upToCount: 16) ?? Data()
                    let mediaSize = try HybridBox.wide(header, 8)
                    let payloadEnd = fragment.video.last.map { $0.offset + UInt64($0.size) } ?? 0
                    try hybridRequire(try HybridBox.word(header, 0) == 1
                        && header.subdata(in: 4..<8) == Data("mdat".utf8)
                        && mediaSize >= 16 && mediaSize <= fragment.end - fragment.start
                        && payloadEnd == fragment.start + mediaSize,
                        "invalid committed media header")
                } else {
                    try hybridRequire(fragment.hashHeaderSkip == nil, "invalid checkpoint hash range")
                }
                let hashStart = fragment.start + UInt64(fragment.hashHeaderSkip ?? 0)
                try hybridRequire(try hybridHashRange(file, hashStart..<fragment.end) == fragment.sha256,
                    "committed fragment \(index) failed SHA-256 verification; no data was discarded")
                expectedStart = fragment.end
                for i in tracks.indices {
                    tracks[i].samples += tracks[i].handler == "vide" ? fragment.video : fragment.timecode
                }
            }
            // Undo a possibly interrupted soft remux only after verifying the ledger.
            let initialization = try template.map { try hybridMovie(template: $0, tracks: tracks, empty: true).data } ?? Data()
            try file.seek(toOffset: 0)
            try file.write(contentsOf: Self.ftyp + Self.placeholder + initialization)
            try file.synchronize()
            try file.truncate(atOffset: expectedStart)
            try file.seekToEnd()
            print("[Hybrid] Verified and reused \(committedFrames) committed frames; incomplete tail discarded.")
        } else {
            try hybridRequire(!FileManager.default.fileExists(atPath: workingURL.path), "unjournaled working file already exists")
            try Data().write(to: workingURL, options: .withoutOverwriting)
            file = try FileHandle(forUpdating: workingURL)
            journal = HybridJournal(version: 1, fingerprint: fingerprint)
            journal.subdivisionFrames = subdivisionFrames
            try file.write(contentsOf: Self.ftyp + Self.placeholder)
            try file.synchronize()
            try hybridSave(journal, at: stateURL)
        }
    }

    deinit { try? file.close() }

    private static func descriptors(_ movie: HybridBox) throws -> [HybridTrack] {
        let mvhd = try movie.child("mvhd").payload
        let movieScale = try HybridBox.word(mvhd, mvhd.first == 1 ? 20 : 12)
        return try movie.children().filter { $0.type == "trak" }.map { trak in
            let tkhd = try trak.child("tkhd").payload
            let mdia = try trak.child("mdia"), mdhd = try mdia.child("mdhd").payload
            let handler = try mdia.child("hdlr").payload
            let kind = String(data: handler[8..<12], encoding: .isoLatin1) ?? ""
            return HybridTrack(template: trak,
                id: try HybridBox.word(tkhd, tkhd.first == 1 ? 20 : 12),
                scale: kind == "tmcd" ? movieScale : try HybridBox.word(mdhd, mdhd.first == 1 ? 20 : 12),
                handler: kind,
                stsd: try mdia.child("minf").child("stbl").child("stsd"), samples: [])
        }
    }

    func append(chunkURL: URL, expectedFrames: Int, totalFrames: Int, fps: FramerateInfo) throws {
        let chunk = try HybridChunk(url: chunkURL)
        guard let video = chunk.tracks.first(where: { $0.handler == "vide" }) else {
            throw HybridMOVError.invalid("chunk has no video")
        }
        try hybridRequire(video.samples.count == expectedFrames && video.samples.first?.sync == true,
            "chunk count or independent GOP validation failed")
        try hybridRequire(video.scale == UInt32(fps.numerator)
            && video.samples.allSatisfy { $0.duration == UInt32(fps.denominator) },
            "subdivision changed the rational edit rate")
        var decodeTime: Int64 = 0
        let presentationTimes = video.samples.map { sample in
            let result = decodeTime + Int64(sample.cts)
            decodeTime += Int64(sample.duration)
            return result
        }.sorted()
        try hybridRequire(presentationTimes.enumerated().allSatisfy {
            $0.element == Int64($0.offset * fps.denominator)
        }, "subdivision contains missing, duplicate or shifted presentation times")
        if template == nil {
            template = chunk.movie
            tracks = chunk.tracks.map { HybridTrack(template: $0.template, id: $0.id,
                scale: $0.handler == "tmcd" ? chunk.movieScale : $0.scale,
                handler: $0.handler, stsd: $0.stsd, samples: []) }
            journal.movieTemplate = chunk.movie.data
            try file.write(contentsOf: hybridMovie(template: chunk.movie, tracks: tracks, empty: true).data)
            try file.synchronize()
            try hybridSave(journal, at: stateURL)
        }
        var deliveries: [(Int, [HybridSample])] = []
        for (i, track) in tracks.enumerated() {
            guard let incoming = chunk.tracks.first(where: { $0.id == track.id && $0.handler == track.handler }) else {
                throw HybridMOVError.invalid("chunk track configuration changed")
            }
            try hybridRequire((track.handler == "tmcd" || track.scale == incoming.scale) && track.stsd.data == incoming.stsd.data,
                "encoder sample description changed between subdivisions")
            if track.handler == "tmcd", !journal.fragments.isEmpty { continue }
            var samples = incoming.samples
            if track.handler == "tmcd" {
                try hybridRequire(samples.count == 1, "timecode requires one sample")
                let duration = UInt64(totalFrames) * UInt64(video.samples[0].duration) * UInt64(track.scale) / UInt64(video.scale)
                try hybridRequire(duration <= UInt64(UInt32.max), "timecode duration overflow")
                samples[0].duration = UInt32(duration)
            }
            deliveries.append((i, samples))
        }
        let start = try file.offset()
        func moof(_ offsets: [Int32]) -> Data {
            var trafs = Data()
            for (index, delivery) in deliveries.enumerated() {
                let track = tracks[delivery.0], samples = delivery.1
                let base = track.samples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }
                let tfhd = HybridBox.full("tfhd", 0x020000, HybridBox.u32(track.id))
                let tfdt = HybridBox.full("tfdt", 0x01000000, HybridBox.u64(base))
                let body = HybridBox.u32(UInt32(samples.count)) + HybridBox.u32(UInt32(bitPattern: offsets[index]))
                    + samples.reduce(Data()) { data, sample in
                        data + HybridBox.u32(sample.duration) + HybridBox.u32(sample.size)
                        + HybridBox.u32(sample.sync ? 0x02000000 : 0x01010000)
                        + HybridBox.u32(UInt32(bitPattern: sample.cts))
                    }
                let trun = HybridBox.full("trun", 0x01000f01, body)
                trafs += HybridBox(type: "traf", payload: tfhd.data + tfdt.data + trun.data).data
            }
            return HybridBox(type: "moof", payload:
                HybridBox.full("mfhd", 0, HybridBox.u32(UInt32(journal.fragments.count + 1))).data + trafs).data
        }
        let headerSize = moof(Array(repeating: 0, count: deliveries.count)).count
        var byte = UInt64(headerSize + 8), offsets: [Int32] = []
        for (_, samples) in deliveries {
            try hybridRequire(byte <= UInt64(Int32.max), "fragment exceeds signed data-offset limit")
            offsets.append(Int32(byte))
            byte += samples.reduce(UInt64(0)) { $0 + UInt64($1.size) }
        }
        try hybridRequire(byte <= UInt64(UInt32.max), "fragment exceeds 32-bit media size")
        var hash = SHA256()
        func write(_ data: Data) throws { try file.write(contentsOf: data); hash.update(data: data) }
        try write(moof(offsets))
        try write(HybridBox.u32(UInt32(byte - UInt64(headerSize))) + Data("mdat".utf8))
        let source = try FileHandle(forReadingFrom: chunkURL)
        defer { try? source.close() }
        var deliveredVideo: [HybridSample] = [], deliveredTimecode: [HybridSample] = []
        for (trackIndex, incoming) in deliveries {
            var delivered: [HybridSample] = []
            var cursor = 0
            while cursor < incoming.count {
                let sourceOffset = incoming[cursor].offset
                var count = 1, bytes = UInt64(incoming[cursor].size)
                while cursor + count < incoming.count,
                      incoming[cursor + count].offset == sourceOffset + bytes,
                      bytes + UInt64(incoming[cursor + count].size) <= 4 * 1024 * 1024 {
                    bytes += UInt64(incoming[cursor + count].size)
                    count += 1
                }
                try source.seek(toOffset: sourceOffset)
                var destinationOffset = try file.offset()
                for i in cursor..<cursor + count {
                    var sample = incoming[i]
                    sample.offset = destinationOffset
                    destinationOffset += UInt64(sample.size)
                    delivered.append(sample)
                }
                var remaining = Int(bytes)
                while remaining > 0 {
                    let data = try source.read(upToCount: min(remaining, 4 * 1024 * 1024)) ?? Data()
                    try hybridRequire(!data.isEmpty, "short chunk payload read")
                    try write(data)
                    remaining -= data.count
                }
                cursor += count
            }
            tracks[trackIndex].samples += delivered
            if tracks[trackIndex].handler == "vide" { deliveredVideo = delivered }
            else { deliveredTimecode = delivered }
        }
        try file.synchronize()
        journal.fragments.append(HybridFragment(index: journal.fragments.count, start: start,
            end: try file.offset(), sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            video: deliveredVideo, timecode: deliveredTimecode))
        try hybridSave(journal, at: stateURL)
        print("[Hybrid] Committed \(committedFrames)/\(totalFrames) frames (\(journal.fragments.count) fragments).")
    }

    func finish(totalFrames: Int) throws {
        try hybridRequire(committedFrames == totalFrames, "incomplete picture coverage")
        guard let template else { throw HybridMOVError.invalid("no movie template") }
        let index = try hybridMovie(template: template, tracks: tracks, empty: false).data
        let end = try file.offset()
        try file.write(contentsOf: index)
        try file.synchronize()
        journal.finalIndexHash = hybridHash(index)
        journal.finalSize = end + UInt64(index.count)
        try hybridSave(journal, at: stateURL)
        // Only this 16-byte header changes: all fragment headers and the initial
        // moov become inert bytes inside the enclosing 64-bit mdat.
        try file.seek(toOffset: UInt64(Self.ftyp.count))
        try file.write(contentsOf: HybridBox.u32(1) + Data("mdat".utf8)
            + HybridBox.u64(end - UInt64(Self.ftyp.count)))
        try file.synchronize()
        print("[Hybrid] Soft remux wrote \(index.count) index bytes; no media-data recopy.")
    }

    /// Direct compressed ProRes delivery. mdat precedes its closing moof, as in
    /// Apple's recoverable MOV layout. Only metadata and a 4 MiB write buffer
    /// are retained; media is written once, at its final destination offset.
    func appendProResFrames(expectedFrames: Int, totalFrames: Int, fps: FramerateInfo,
        next: @Sendable (Int) async throws -> SendableSampleBuffer) async throws {
        guard let videoIndex = tracks.firstIndex(where: { $0.handler == "vide" }) else {
            throw HybridMOVError.invalid("direct stream requires an initialized movie")
        }
        let track = tracks[videoIndex]
        try hybridRequire(track.scale == UInt32(fps.numerator), "direct stream clock changed")
        let firstFrame = committedFrames
        let start = try file.offset()
        try file.write(contentsOf: HybridBox.u32(1) + Data("mdat".utf8) + HybridBox.u64(0))
        var hash = SHA256(), pending = Data(), delivered: [HybridSample] = []
        func flush() throws {
            if !pending.isEmpty {
                try file.write(contentsOf: pending)
                hash.update(data: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        for i in 0..<expectedFrames {
            try Task.checkCancellation()
            let wrapped = try await next(firstFrame + i)
            let sample = wrapped.buf
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let expected = CMTime(value: Int64((firstFrame + i) * fps.denominator), timescale: Int32(fps.numerator))
            try hybridRequire(CMTimeCompare(pts, expected) == 0 && CMSampleBufferGetNumSamples(sample) == 1,
                "direct ProRes callback changed presentation order")
            guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else {
                throw HybridMOVError.invalid("direct ProRes callback has no packet")
            }
            let stsd = track.stsd.payload
            let codec = try HybridBox.word(stsd, 12)
            try hybridRequire(CMFormatDescriptionGetMediaSubType(format) == codec, "direct ProRes codec changed")
            let length = CMBlockBufferGetDataLength(block)
            try hybridRequire(length > 0 && length <= Int(UInt32.max), "invalid ProRes packet length")
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            try hybridRequire(status == kCMBlockBufferNoErr, "cannot read compressed ProRes packet")
            delivered.append(HybridSample(offset: try file.offset() + UInt64(pending.count),
                size: UInt32(length), duration: UInt32(fps.denominator), cts: 0, sync: true))
            pending.append(data)
            if pending.count >= 4 * 1024 * 1024 { try flush() }
        }
        try flush()
        let dataEnd = try file.offset()
        let base = track.samples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }
        let tfhd = HybridBox.full("tfhd", 0x000001, HybridBox.u32(track.id) + HybridBox.u64(start + 16))
        let tfdt = HybridBox.full("tfdt", 0x01000000, HybridBox.u64(base))
        let body = HybridBox.u32(UInt32(delivered.count)) + HybridBox.u32(0)
            + delivered.reduce(Data()) { $0 + HybridBox.u32($1.duration) + HybridBox.u32($1.size) + HybridBox.u32(0x02000000) }
        let trun = HybridBox.full("trun", 0x000701, body)
        let traf = HybridBox(type: "traf", payload: tfhd.data + tfdt.data + trun.data)
        let moof = HybridBox(type: "moof", payload: HybridBox.full("mfhd", 0,
            HybridBox.u32(UInt32(journal.fragments.count + 1))).data + traf.data).data
        try file.write(contentsOf: moof)
        hash.update(data: moof)
        let end = try file.offset()
        try file.seek(toOffset: start + 8)
        try file.write(contentsOf: HybridBox.u64(dataEnd - start))
        try file.seek(toOffset: end)
        try file.synchronize()
        tracks[videoIndex].samples += delivered
        var fragment = HybridFragment(index: journal.fragments.count, start: start, end: end,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), video: delivered, timecode: [])
        fragment.hashHeaderSkip = 16
        journal.fragments.append(fragment)
        try hybridSave(journal, at: stateURL)
        print("[Hybrid] Directly committed \(committedFrames)/\(totalFrames) frames.")
    }
}

/// Intra-frame ProRes can distribute pictures across independent hardware
/// sessions without GOP changes. One reader feeds bounded per-session windows;
/// the muxer drains lanes in exact presentation order.
private final class HybridStreamProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastOutput = DispatchTime.now().uptimeNanoseconds
    func touch() { lock.lock(); lastOutput = DispatchTime.now().uptimeNanoseconds; lock.unlock() }
    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return DispatchTime.now().uptimeNanoseconds - lastOutput > 60_000_000_000
    }
}

private func hybridNextPicture(_ output: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
    while let sample = output.copyNextSampleBuffer() {
        // AVAssetReader may prepend an empty timing marker to a ranged read.
        if CMSampleBufferGetNumSamples(sample) > 0 { return sample }
    }
    return nil
}

private func hybridStreamProRes(asset: AVAsset, track: AVAssetTrack, quality: String,
    sourceColor: SourceColorSpace?, fps: FramerateInfo, sourceStart: CMTime,
    totalFrames: Int, workers: Int, fragmentFrames: Int, muxer: HybridMuxer) async throws {
    let firstFrame = muxer.committedFrames
    let size = try await track.load(.naturalSize)
    let subtype = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
    var requested = proResReaderPixelFormat(quality)
    if subtype == kCMVideoCodecType_H264 { requested = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
    if subtype == kCMVideoCodecType_HEVC { requested = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }
    let plan = try negotiateDecodedVideoOutput(asset: asset, videoTrack: track, pixelFormats: [requested,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA])
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: plan.outputSettings)
    output.alwaysCopiesSampleData = false
    try hybridRequire(reader.canAdd(output), "cannot create direct source reader")
    reader.add(output)
    let start = CMTimeAdd(sourceStart, CMTime(value: Int64(firstFrame * fps.denominator), timescale: Int32(fps.numerator)))
    reader.timeRange = CMTimeRange(start: start, duration: CMTime(value: Int64((totalFrames - firstFrame) * fps.denominator),
        timescale: Int32(fps.numerator)))
    var sessions: [ProResSession] = []
    defer { sessions.forEach { $0.invalidate() } }
    for _ in 0..<workers {
        let session = try ProResSession(width: Int(size.width), height: Int(size.height), codecType: proResCodecType(quality),
            fpsHint: Int(fps.fps.rounded()), colorSpace: sourceColor, sourcePixelFormat: plan.pixelFormat)
        session.enableAsyncMode(channelCapacity: 4, requiresEveryFrame: true)
        sessions.append(session)
    }
    let channels = sessions.map { $0.outputChannel! }
    let permits = sessions.map { _ in
        let window = AsyncChannel<Int>(capacity: 4)
        for _ in 0..<4 { window.send(0) }
        return window
    }
    let sessionRefs = sessions
    let readerRef = SendableRef(reader), outputRef = SendableRef(output)
    let failure = PipelineFailureBox()
    let health = HybridStreamProgress()
    try hybridRequire(reader.startReading(), "direct source reader failed to start")
    print("[Hybrid] Direct ProRes: one reader, \(workers) VT sessions, four in-flight frames per session.")
    let watchdog = Task.detached(priority: .utility) {
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            if health.timedOut {
                failure.store(HybridMOVError.invalid("no direct-stream output for 60 seconds; last committed fragment is retained"))
                channels.forEach { $0.finish() }
                permits.forEach { $0.finish() }
                sessionRefs.forEach { $0.cancelPendingFrames() }
                readerRef.value.cancelReading()
                return
            }
        }
    }
    let producer = Task.detached(priority: .userInitiated) {
        do {
            for index in firstFrame..<totalFrames {
                let lane = (index - firstFrame) % workers
                guard await permits[lane].next() != nil else { throw CancellationError() }
                try Task.checkCancellation()
                if let error = failure.error { throw error }
                let wrapped: SendableSampleBuffer = try autoreleasepool {
                    guard let sample = hybridNextPicture(outputRef.value) else {
                        throw HybridMOVError.invalid("direct source ended before picture \(index): \(String(describing: readerRef.value.error))")
                    }
                    let expected = CMTimeAdd(sourceStart, CMTime(value: Int64(index * fps.denominator), timescale: Int32(fps.numerator)))
                    try hybridRequire(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), expected) == 0,
                        "source is not CFR at picture \(index)")
                    return SendableSampleBuffer(buf: sample)
                }
                guard let pixel = CMSampleBufferGetImageBuffer(wrapped.buf) else {
                    throw HybridMOVError.invalid("direct source has no decoded picture")
                }
                let pts = CMTime(value: Int64(index * fps.denominator), timescale: Int32(fps.numerator))
                let duration = CMTime(value: Int64(fps.denominator), timescale: Int32(fps.numerator))
                try hybridRequire(sessionRefs[lane].submit(pixelBuffer: pixel, pts: pts, duration: duration),
                    "direct VT submit failed at picture \(index)")
            }
            try hybridRequire(hybridNextPicture(outputRef.value) == nil && readerRef.value.status == .completed,
                "direct source picture range was not exhausted exactly")
            sessionRefs.forEach { $0.flushAsync() }
        } catch {
            failure.store(error)
            channels.forEach { $0.finish() }
            throw error
        }
    }
    do {
        while muxer.committedFrames < totalFrames {
            try await muxer.appendProResFrames(expectedFrames: min(fragmentFrames, totalFrames - muxer.committedFrames),
                totalFrames: totalFrames, fps: fps) { index in
                let lane = (index - firstFrame) % workers
                guard let sample = await channels[lane].next() else {
                    throw failure.error ?? HybridMOVError.invalid("direct VT output ended early")
                }
                permits[lane].send(0)
                health.touch()
                return sample
            }
        }
        try await producer.value
        watchdog.cancel()
        _ = await watchdog.result
        for session in sessions {
            if let error = session.callbackError { throw error }
        }
    } catch {
        failure.store(error)
        reader.cancelReading()
        channels.forEach { $0.finish() }
        permits.forEach { $0.finish() }
        producer.cancel()
        sessionRefs.forEach { $0.cancelPendingFrames() }
        _ = await producer.result
        watchdog.cancel()
        _ = await watchdog.result
        throw error
    }
}

private struct HybridCompletedChunk: Codable {
    let fingerprint: String
    let frames: Int
    let sha256: String
}

/// Default CLI routing must preserve audio and unsupported ancillary workflows.
/// Actual frame submission additionally checks CFR timestamps throughout encoding.
func hybridMOVSourceIneligibilityReason(asset: AVAsset, deleteSourceAudio: Bool) async -> String? {
    do {
        if !deleteSourceAudio, let source = asset as? AVURLAsset, source.url.isFileURL,
           try NativeContainerKind.identify(source.url) == .isoMovie,
           try NativeMovieFile(url: source.url, audioOnly: true).tracks.contains(where: { $0.handler == "soun" }) {
            return "source audio packets are preserved by the ordinary writer, including unrecognized codecs"
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { return "requires exactly one video track" }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        if !deleteSourceAudio, !audio.isEmpty {
            return "source audio is preserved by the ordinary writer; select -dsa to omit it"
        }
        let metadata = try await asset.loadTracks(withMediaType: .metadata)
        if !metadata.isEmpty { return "source has timed metadata" }
        let fps = await framerateInfo(from: asset)
        let range = try await track.load(.timeRange)
        let count = range.duration.seconds * fps.fps
        guard count.isFinite, count > 0, count <= Double(Int32.max),
              abs(count - count.rounded()) < 0.001 else { return "source does not declare an integral CFR picture range" }
        let minimum = try await track.load(.minFrameDuration)
        let expected = CMTime(value: Int64(fps.denominator), timescale: Int32(fps.numerator))
        if minimum.isNumeric, minimum.value > 0, CMTimeCompare(minimum, expected) != 0 {
            return "source sample timing is variable or does not match its edit rate"
        }
        _ = try negotiateDecodedVideoOutput(asset: asset, videoTrack: track, pixelFormats: retagProbePixelFormats)
        return nil
    } catch {
        return "source requires the ordinary reader: \(error.localizedDescription)"
    }
}

/// Prepare all candidates simultaneously, with hardware mandatory. Two accepted
/// sessions prove concurrent hardware contexts, not two physical media engines.
private func hybridMOVWorkerPlan(requested: Int, recommendation: Int?, fragmentCount: Int,
    width: Int, height: Int, quality: String, fps: FramerateInfo,
    color: SourceColorSpace?, options: HEVCEncodeOptions?) -> HybridMOVWorkerPlan {
    let target = requested == 0 ? 2 : requested
    let candidateCount = max(1, min(target, recommendation ?? target, fragmentCount))
    var candidates: [ProResSession] = []
    defer { candidates.forEach { $0.invalidate() } }
    var failure: String?
    if candidateCount > 1 {
        let probeOptions = options.map { HEVCEncodeOptions(bitrateMbps: $0.bitrateMbps,
            dvProfile: $0.dvProfile, keyFrameIntervalSeconds: $0.keyFrameIntervalSeconds,
            allIntra: $0.allIntra, bFrames: $0.bFrames, bitrateMode: $0.bitrateMode, multiPass: false) }
        do {
            for _ in 0..<candidateCount {
                candidates.append(try ProResSession(width: width, height: height,
                    codecType: proResCodecType(quality), fpsHint: Int(fps.fps.rounded()),
                    colorSpace: color, hevcOptions: probeOptions, requireHardwareForHybridProbe: true))
            }
        } catch { failure = error.localizedDescription }
    }
    let verified = candidateCount > 1 ? candidates.count : 1
    let plan = HybridMOVWorkerPlan(requested: requested, recommendedLimit: recommendation,
        verifiedHardwareSessions: verified, fragmentCount: fragmentCount, probeFailure: failure)
    let check = candidateCount > 1 ? "hardware session check \(verified)/\(candidateCount)" : "single-worker selection"
    print("[Hybrid] Parallel mode \(requested == 0 ? "automatic (target 2)" : "manual (target \(requested))"); VT limit \(recommendation.map(String.init) ?? "unavailable"); \(check).")
    if let notice = plan.notice { print("[Hybrid] \(notice)") }
    return plan
}

/// Recoverable single-file workflow for eligible CLI MOV defaults and explicit
/// Framework options. AMA, AV1 and timeline dispatch retain their existing paths.
/// Every intermediate lives beside the requested output.
func encodeHybridMOV(sourceURL: URL, outputURL: URL, quality: String,
    hevcOptions: HEVCEncodeOptions?, colorTransform: ColorTransformRequest?,
    forcedStartTimecode: String?, deleteSourceAudio: Bool,
    cmuMasteringNits: Float?, useDolbyVisionCodecTag: Bool,
    requestedWorkers: Int, fragmentFrames requestedFragmentFrames: Int,
    resume: Bool) async -> Bool {
    let fm = FileManager.default
    let directory = outputURL.deletingLastPathComponent()
    let stateDirectory = directory.appendingPathComponent(".\(outputURL.lastPathComponent).hybrid-state", isDirectory: true)
    let workingURL = directory.appendingPathComponent("\(outputURL.deletingPathExtension().lastPathComponent).hybrid-partial.mov")
    let stateURL = stateDirectory.appendingPathComponent("journal.json")
    let started = ContinuousClock.now
    do {
        try hybridRequire(outputURL.pathExtension.lowercased() == "mov", "requires MOV output")
        try hybridRequire(!isAV1Quality(quality) && quality != "pass", "requires a VideoToolbox codec")
        try hybridRequire(requestedWorkers >= 0 && requestedWorkers <= 8
            && (requestedFragmentFrames == 0 || (24...2400).contains(requestedFragmentFrames)),
            "workers must be 0...8; fragment frames must be 0 (automatic) or 24...2400")
        try hybridRequire(sourceURL.standardizedFileURL != outputURL.standardizedFileURL
            && sourceURL.standardizedFileURL != workingURL.standardizedFileURL, "output would overwrite the source")
        let asset = AVURLAsset(url: sourceURL)
        if !deleteSourceAudio, try NativeContainerKind.identify(sourceURL) == .isoMovie {
            let sourceAudio = try NativeMovieFile(url: sourceURL, audioOnly: true)
            try hybridRequire(sourceAudio.tracks.isEmpty,
                "source audio requires the ordinary packet-preserving encode path or explicit -dsa")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try hybridRequire(deleteSourceAudio || audioTracks.isEmpty,
            "audio transport is not yet supported; use the ordinary encode path or explicitly select -dsa")
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        try hybridRequire(metadataTracks.isEmpty, "timed metadata requires the ordinary encode path")
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        try hybridRequire(videoTracks.count == 1, "requires exactly one source video track")
        let sourceTrack = videoTracks[0]
        let fps = await framerateInfo(from: asset)
        let range = try await sourceTrack.load(.timeRange)
        let exactCount = range.duration.seconds * fps.fps
        try hybridRequire(exactCount.isFinite && exactCount > 0 && exactCount <= Double(Int32.max)
            && abs(exactCount - exactCount.rounded()) < 0.001, "requires an integral CFR picture range")
        let totalFrames = Int(exactCount.rounded())
        let sourceColor = await detectColorSpace(from: sourceTrack)
        let size = try await sourceTrack.load(.naturalSize)
        if hevcOptions?.dvProfile?.isProfile76 == true {
            _ = try DolbyVisionProfile7RasterPlan(sourceWidth: Int(size.width), sourceHeight: Int(size.height))
        }
        let probe = try ProResSession(width: Int(size.width), height: Int(size.height),
            codecType: proResCodecType(quality), fpsHint: Int(fps.fps.rounded()),
            colorSpace: sourceColor, hevcOptions: hevcOptions)
        let recommendation = probe.parallelEncodingRecommendation()
        probe.invalidate()
        let previousFrames = resume ? (try? hybridLoad(stateURL))?.subdivisionFrames : nil
        let durationMinimum = Int(min(2400, ceil((recommendation.minimumDuration ?? 0) * fps.fps)))
        let automaticFrames = min(2400, max(240, recommendation.minimumFrames ?? 0, durationMinimum))
        let fragmentFrames = requestedFragmentFrames == 0 ? (previousFrames ?? automaticFrames) : requestedFragmentFrames
        try hybridRequire((24...2400).contains(fragmentFrames), "invalid saved subdivision length")
        let chunkCount = (totalFrames + fragmentFrames - 1) / fragmentFrames
        let workerPlan = hybridMOVWorkerPlan(requested: requestedWorkers, recommendation: recommendation.limit,
            fragmentCount: chunkCount, width: Int(size.width), height: Int(size.height), quality: quality,
            fps: fps, color: sourceColor, options: hevcOptions)
        let workers = workerPlan.workers
        let timecodeTrack = try await asset.loadTracks(withMediaType: .timecode).first
        let startTimecode: String
        if let timecodeTrack {
            if let info = try? await readQuickTimeTimecodeInfo(asset: asset, track: timecodeTrack) {
                startTimecode = info.stringValue
            } else {
                startTimecode = try readQuickTimeTimecodeInfoFromMOVSample(sourceURL: sourceURL,
                    trackID: timecodeTrack.trackID,
                    expectedFormatDescription: try? await timecodeTrack.load(.formatDescriptions).first).stringValue
            }
        } else {
            startTimecode = forcedStartTimecode ?? "01:00:00:00"
        }
        let attributes = try fm.attributesOfItem(atPath: sourceURL.path)
        let sourceSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let sourceFile = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceFile.close() }
        let head = try sourceFile.read(upToCount: 1024 * 1024) ?? Data()
        try sourceFile.seek(toOffset: sourceSize > 1024 * 1024 ? sourceSize - 1024 * 1024 : 0)
        let tail = try sourceFile.read(upToCount: 1024 * 1024) ?? Data()
        let encoderIdentity = hevcOptions.map {
            "\($0.bitrateMbps.bitPattern)|\($0.dvProfile?.rawValue ?? "none")|\($0.keyFrameIntervalSeconds)|\($0.allIntra)|\($0.bFrames)|\($0.bitrateMode.rawValue)|\($0.multiPass)"
        } ?? "none"
        let colorIdentity = colorTransform.map {
            "\($0.outputGamut.rawValue)|\($0.outputOETF.rawValue)|\($0.targetNits.bitPattern)|\(hybridLUTHash($0.lut))"
        } ?? "none"
        let identity = "hybrid-v2|\(sourceURL.standardizedFileURL.path)|\(sourceSize)|" +
            "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(hybridHash(head + tail))|" +
            "\(quality)|\(encoderIdentity)|\(colorIdentity)|" +
            "\(startTimecode)|\(fps.numerator)/\(fps.denominator)|\(fragmentFrames)|\(cmuMasteringNits.map { String($0.bitPattern) } ?? "none")|\(useDolbyVisionCodecTag)"
        let fingerprint = hybridHash(Data(identity.utf8))
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !resume {
            try hybridRequire(!fm.fileExists(atPath: stateURL.path) && !fm.fileExists(atPath: workingURL.path)
                && !fm.fileExists(atPath: outputURL.path),
                "output or recovery state already exists; use --hybrid-resume or a new output path")
        } else {
            try hybridRequire(fm.fileExists(atPath: stateURL.path), "no saved Hybrid MOV job at this output path")
        }
        try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let lockFD = open(stateDirectory.appendingPathComponent("job.lock").path, O_CREAT | O_RDWR, 0o600)
        try hybridRequire(lockFD >= 0, "cannot open job lock")
        var lockIsOpen = true
        func releaseLock() {
            guard lockIsOpen else { return }
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
            lockIsOpen = false
        }
        defer { releaseLock() }
        try hybridRequire(flock(lockFD, LOCK_EX | LOCK_NB) == 0, "another process owns this job")
        // Cover a crash after final rename but before journal cleanup.
        if resume, !fm.fileExists(atPath: workingURL.path), fm.fileExists(atPath: outputURL.path) {
            let state = try hybridLoad(stateURL)
            try hybridRequire(state.version == 1 && state.fingerprint == fingerprint, "job fingerprint mismatch")
            let final = try FileHandle(forReadingFrom: outputURL)
            defer { try? final.close() }
            let size = try final.seekToEnd()
            guard let end = state.fragments.last?.end, let expected = state.finalIndexHash else {
                throw HybridMOVError.invalid("missing finalization checkpoint")
            }
            try hybridRequire(size == state.finalSize && end < size
                && (try hybridHashRange(final, end..<size)) == expected, "final commit verification failed")
            for fragment in state.fragments {
                try hybridRequire(try hybridHashRange(final,
                    fragment.start + UInt64(fragment.hashHeaderSkip ?? 0)..<fragment.end) == fragment.sha256,
                    "final fragment verification failed")
            }
            let committed = try HybridChunk(url: outputURL)
            try hybridRequire(committed.tracks.first(where: { $0.handler == "vide" })?.samples.count == totalFrames,
                "final container or picture coverage is invalid; recovery state was retained")
            releaseLock()
            try? fm.removeItem(at: stateDirectory)
            print("[Hybrid] Recovered an already completed final commit.")
            return true
        }
        let muxer = try HybridMuxer(workingURL: workingURL, stateURL: stateURL,
            fingerprint: fingerprint, subdivisionFrames: fragmentFrames)
        try hybridRequire(muxer.committedFrames <= totalFrames &&
            (muxer.committedFrames == totalFrames || muxer.committedFrames % fragmentFrames == 0),
            "checkpoint is not at a subdivision boundary")
        print("[Hybrid] Using \(workers) worker(s), \(fragmentFrames) frames/fragment.")
        if fragmentFrames < (recommendation.minimumFrames ?? 1) {
            print("[Hybrid] Explicit fragment length is below the encoder recommendation; benchmark before increasing concurrency.")
        }
        let directProRes = !isHEVCQuality(quality) && !isH264Quality(quality) && colorTransform == nil
        let stagedChunkCount = directProRes ? min(chunkCount, 1) : chunkCount
        let sourceStart = range.start
        let transform = try await sourceTrack.load(.preferredTransform)
        try await withThrowingTaskGroup(of: Int.self) { group in
            var nextCommit = muxer.journal.fragments.count, nextSchedule = nextCommit, active = 0
            var ready: Set<Int> = []
            while nextCommit < stagedChunkCount {
                try Task.checkCancellation()
                // Bound both decoder/codec sessions and out-of-order disk staging.
                while active < workers && nextSchedule < min(stagedChunkCount, nextCommit + workers) {
                    let index = nextSchedule
                    nextSchedule += 1
                    active += 1
                    group.addTask {
                        let chunkURL = stateDirectory.appendingPathComponent("chunk-\(index).mov")
                        let doneURL = chunkURL.appendingPathExtension("json")
                        let frameCount = min(fragmentFrames, totalFrames - index * fragmentFrames)
                        if let doneData = try? Data(contentsOf: doneURL),
                           let done = try? JSONDecoder().decode(HybridCompletedChunk.self, from: doneData),
                           done.fingerprint == fingerprint, done.frames == frameCount,
                           let file = try? FileHandle(forReadingFrom: chunkURL) {
                            defer { try? file.close() }
                            if try hybridHashRange(file, 0..<file.seekToEnd()) == done.sha256 {
                                print("[Hybrid] Reusing completed subdivision \(index).")
                                return index
                            }
                        }
                        let localAsset = AVURLAsset(url: sourceURL)
                        guard let track = try await localAsset.loadTracks(withMediaType: .video).first else {
                            throw HybridMOVError.invalid("source disconnected")
                        }
                        let composition = AVMutableComposition()
                        guard let destination = composition.addMutableTrack(withMediaType: .video,
                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
                            throw HybridMOVError.invalid("cannot create subdivision")
                        }
                        let start = CMTimeAdd(sourceStart, CMTime(value: Int64(index * fragmentFrames * fps.denominator),
                            timescale: Int32(fps.numerator)))
                        let duration = CMTime(value: Int64(frameCount * fps.denominator), timescale: Int32(fps.numerator))
                        try destination.insertTimeRange(CMTimeRange(start: start, duration: duration), of: track, at: .zero)
                        destination.preferredTransform = transform
                        var cmu: CMUOutputArtifacts?
                        if let nits = cmuMasteringNits {
                            cmu = try await runCMUAnalysisBeforeCompressedEncode(inputAsset: localAsset,
                                sidecarBaseURL: chunkURL, quality: quality, colorTransform: colorTransform,
                                dolbyVisionProfile: hevcOptions?.dvProfile, masteringPeakNits: nits,
                                forcedStartTimecode: startTimecode, progress: nil,
                                privateHybridFrameRange: Int64(index * fragmentFrames)..<Int64(index * fragmentFrames + frameCount))
                        }
                        let success = await encodeMOV(asset: composition, outputURL: chunkURL, quality: quality,
                            extraAudioURL: nil, audioReplace: false, deleteSourceAudio: true,
                            forcedOutputStartTimecode: startTimecode, dolbyVisionXMLURL: cmu?.xmlURL,
                            dolbyVisionLevel4Measurements: cmu?.level4Measurements,
                            hevcOptions: hevcOptions, av1Options: nil, colorSpace: sourceColor, fpsInfo: fps,
                            colorTransform: colorTransform, useDolbyVisionCodecTag: useDolbyVisionCodecTag, reconnectAttempt: 3,
                            timecodeFrameCountOverride: Int64(frameCount), privateFrameStreamMediaTimeScale: Int32(fps.numerator),
                            parallelSubdivision: VTParallelSubdivision(hasPrevious: index > 0, hasNext: index + 1 < chunkCount))
                        try hybridRequire(success, "subdivision \(index) failed; committed prefix is retained")
                        let chunk = try HybridChunk(url: chunkURL)
                        try hybridRequire(chunk.tracks.first(where: { $0.handler == "vide" })?.samples.count == frameCount,
                            "subdivision \(index) picture count mismatch")
                        let file = try FileHandle(forUpdating: chunkURL)
                        defer { try? file.close() }
                        try file.synchronize()
                        let checksum = try hybridHashRange(file, 0..<file.seekToEnd())
                        let completion = HybridCompletedChunk(fingerprint: fingerprint, frames: frameCount, sha256: checksum)
                        let doneData = try JSONEncoder().encode(completion)
                        try doneData.write(to: doneURL, options: .atomic)
                        let marker = try FileHandle(forWritingTo: doneURL)
                        try marker.synchronize()
                        try marker.close()
                        return index
                    }
                }
                guard let completed = try await group.next() else { throw HybridMOVError.invalid("missing subdivision") }
                active -= 1
                ready.insert(completed)
                while ready.remove(nextCommit) != nil {
                    let chunkURL = stateDirectory.appendingPathComponent("chunk-\(nextCommit).mov")
                    try muxer.append(chunkURL: chunkURL,
                        expectedFrames: min(fragmentFrames, totalFrames - nextCommit * fragmentFrames),
                        totalFrames: totalFrames, fps: fps)
                    try fm.removeItem(at: chunkURL)
                    try? fm.removeItem(at: chunkURL.appendingPathExtension("json"))
                    nextCommit += 1
                }
            }
        }
        if directProRes && muxer.committedFrames < totalFrames {
            try await hybridStreamProRes(asset: asset, track: sourceTrack, quality: quality,
                sourceColor: sourceColor, fps: fps, sourceStart: sourceStart, totalFrames: totalFrames,
                workers: workers, fragmentFrames: fragmentFrames, muxer: muxer)
        }
        try Task.checkCancellation()
        try muxer.finish(totalFrames: totalFrames)
        try Task.checkCancellation()
        // File data and complete index are durable before a single same-volume rename.
        if renamex_np(workingURL.path, outputURL.path, UInt32(RENAME_EXCL)) != 0 {
            let status = errno
            if status == ENOTSUP || status == ENOSYS || status == EINVAL {
                // SMB servers commonly lack renamex_np's exclusive extension.
                // Foundation's same-volume move refuses an existing destination.
                try fm.moveItem(at: workingURL, to: outputURL)
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
            }
        }
        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 { _ = fsync(dirFD); close(dirFD) }
        releaseLock()
        do { try fm.removeItem(at: stateDirectory) }
        catch { print("[Hybrid] Output committed; retained cleanup receipt at \(stateDirectory.path).") }
        print("[Hybrid] Finished \(totalFrames) frames in \(started.duration(to: .now)); \(outputURL.path)")
        return true
    } catch {
        print("[Hybrid] \(error.localizedDescription)")
        if fm.fileExists(atPath: stateURL.path) {
            print("[Hybrid] Saved state: \(stateDirectory.path). Repeat the same command with --hybrid-resume.")
        }
        return false
    }
}
