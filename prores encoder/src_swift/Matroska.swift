// Copyright © 2026 B00kerLouis. All rights reserved.
// Native Matroska container I/O. Encoded packets remain on their source volume.
import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

enum MatroskaError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return "Matroska: " + text }; return nil }
}

private func mkvCheck(_ condition: Bool, _ reason: String) throws {
    if !condition { throw MatroskaError.invalid(reason) }
}

/// EBML sizes are unsigned VINTs, while IDs retain their leading marker bit.
enum EBML {
    struct Element { let id: UInt64; let body: UInt64; let end: UInt64; let unknown: Bool }
    static func uint(_ value: UInt64, width: Int = 0) -> Data {
        let n = width > 0 ? width : max(1, (64 - value.leadingZeroBitCount + 7) / 8)
        return Data((0..<n).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func vint(_ value: UInt64) -> Data {
        let n = (1...8).first { value < (UInt64(1) << ($0 * 7)) - 1 } ?? 8
        return uint(value | (UInt64(1) << (7 * n)), width: n)
    }
    static func element(_ id: UInt64, _ bytes: Data) -> Data { uint(id) + vint(UInt64(bytes.count)) + bytes }
    static func number(_ id: UInt64, _ value: UInt64) -> Data { element(id, uint(value)) }
    static func string(_ id: UInt64, _ text: String) -> Data { element(id, Data(text.utf8)) }
    static func float(_ id: UInt64, _ value: Double) -> Data { element(id, uint(value.bitPattern, width: 8)) }
    static func read(_ file: FileHandle, _ offset: UInt64, _ count: Int) throws -> Data {
        try file.seek(toOffset: offset)
        let result = try file.read(upToCount: count) ?? Data()
        try mkvCheck(result.count == count, "truncated file at byte \(offset)")
        return result
    }
    static func value(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
    static func variable(_ bytes: Data, _ cursor: inout Int, marker: Bool = false) throws -> (UInt64, Int) {
        try mkvCheck(cursor < bytes.count && bytes[cursor] != 0, "invalid EBML integer")
        let n = bytes[cursor].leadingZeroBitCount + 1
        try mkvCheck(n <= 8 && cursor <= bytes.count - n, "truncated EBML integer")
        var value = UInt64(bytes[cursor] & (marker ? 255 : UInt8(255 >> n)))
        for index in 1..<n { value = value << 8 | UInt64(bytes[cursor + index]) }
        cursor += n
        return (value, n)
    }
    static func header(_ file: FileHandle, at offset: UInt64, limit: UInt64) throws -> Element {
        let bytes = try read(file, offset, Int(min(12, limit - offset)))
        var cursor = 0
        let (id, idWidth) = try variable(bytes, &cursor, marker: true)
        try mkvCheck(idWidth <= 4, "invalid element ID")
        let (size, width) = try variable(bytes, &cursor)
        let body = offset + UInt64(cursor)
        let unknown = size == (UInt64(1) << (width * 7)) - 1
        try mkvCheck(unknown || size <= limit - body, "element exceeds its parent")
        return Element(id: id, body: body, end: unknown ? limit : body + size, unknown: unknown)
    }
    static func children(_ file: FileHandle, _ start: UInt64, _ end: UInt64) throws -> [Element] {
        var position = start, result: [Element] = []
        while position < end {
            let child = try header(file, at: position, limit: end)
            result.append(child); position = child.end
            try mkvCheck(result.count <= 100_000, "too many metadata elements")
        }
        return result
    }
    static func data(_ file: FileHandle, _ element: Element) throws -> Data {
        try mkvCheck(element.end - element.body <= 16 * 1024 * 1024, "oversized codec metadata")
        return try read(file, element.body, Int(element.end - element.body))
    }
}

struct MatroskaPacket: Sendable {
    let offset: UInt64
    let size: UInt32
    let ptsNS: Int64
    var durationNS: Int64
    let sync: Bool
}

struct MatroskaTrack: Sendable {
    var number: UInt64 = 0, kind: UInt64 = 0
    var codec = "", codecPrivate = Data()
    var isDefault = true, enabled = true
    var width = 0, height = 0, channels = 1, bitDepth = 0
    var sampleRate = 8_000.0
    var defaultDuration: Int64 = 0, codecDelay: Int64 = 0
    var primaries: UInt64 = 2, transfer: UInt64 = 2, matrix: UInt64 = 2, range: UInt64 = 0
    var additions: [String: Data] = [:]
    var mastering: [UInt64: Double] = [:]
    var maxCLL: UInt64?, maxFALL: UInt64?
    var packets: [MatroskaPacket] = []
}

/// Scans headers and block prefixes, skipping all unselected payloads. Packet
/// indices contain offsets, sizes and timing only; no movie payload is cached.
struct MatroskaFile {
    let url: URL
    var tracks: [MatroskaTrack] = []
    private(set) var timestampScale: Int64 = 1_000_000

    init(url: URL, primaryOnly: Bool = true, allowAudioOnly: Bool = false) throws {
        self.url = url
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try mkvCheck(size >= 8, "file is too short")
        let header = try EBML.header(file, at: 0, limit: size)
        try mkvCheck(header.id == 0x1A45DFA3, "missing EBML header")
        let document = try EBML.children(file, header.body, header.end).first { $0.id == 0x4282 }
        if let document {
            let type = String(decoding: try EBML.data(file, document), as: UTF8.self)
            try mkvCheck(type == "matroska" || type == "webm", "unsupported document type")
        }
        var position = header.end
        var segment: EBML.Element?
        while position < size {
            let next = try EBML.header(file, at: position, limit: size)
            if next.id == 0x18538067 { segment = next; break }
            position = next.end
        }
        guard let segment else { throw MatroskaError.invalid("missing Segment") }
        // Metadata may appear after Clusters. Resolve tracks in a first pass.
        position = segment.body
        while position < segment.end {
            let item = try EBML.header(file, at: position, limit: segment.end)
            if item.id == 0x1549A966 {
                for value in try EBML.children(file, item.body, item.end) where value.id == 0x2AD7B1 {
                    timestampScale = Int64(EBML.value(try EBML.data(file, value)))
                }
            } else if item.id == 0x1654AE6B {
                for value in try EBML.children(file, item.body, item.end) where value.id == 0xAE {
                    tracks.append(try Self.readTrack(file, value))
                }
            }
            if item.unknown && item.id == 0x1F43B675 { position = try Self.clusterEnd(file, item, segment.end) }
            else { position = item.end }
        }
        try mkvCheck(timestampScale > 0 && timestampScale <= 1_000_000_000, "invalid TimestampScale")
        // Only the default (or first enabled) video and audio tracks are read.
        if primaryOnly {
            tracks = [UInt64(1), 2].compactMap { kind in
                tracks.first { $0.kind == kind && $0.enabled && $0.isDefault }
                    ?? tracks.first { $0.kind == kind && $0.enabled }
            }
        } else { tracks = tracks.filter { ($0.kind == 1 || $0.kind == 2) && $0.enabled } }
        try mkvCheck(tracks.first?.kind == 1 || (allowAudioOnly && tracks.contains { $0.kind == 2 }), "no enabled primary media track")
        position = segment.body
        while position < segment.end {
            if Task.isCancelled { throw CancellationError() }
            let item = try EBML.header(file, at: position, limit: segment.end)
            if item.id == 0x1F43B675 { position = try scanCluster(file, item, segment.end) }
            else { position = item.end }
        }
        for index in tracks.indices {
            try mkvCheck(!tracks[index].packets.isEmpty, "selected \(tracks[index].codec) track is empty")
            if tracks[index].kind == 2 {
                try mkvCheck(tracks[index].sampleRate.isFinite && tracks[index].sampleRate > 0 && tracks[index].sampleRate <= 384000,
                    "invalid declared audio sampling frequency")
            }
            if tracks[index].defaultDuration == 0 {
                let pts = tracks[index].packets.prefix(256).map(\.ptsNS).sorted()
                let deltas = zip(pts, pts.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
                if !deltas.isEmpty { tracks[index].defaultDuration = deltas[deltas.count / 2] }
            }
            // AAC's GASpecificConfig declares 960/1024 core samples. This is
            // interpreted only for a positively identified AAC-LC stream.
            if tracks[index].codec.hasPrefix("A_AAC"), tracks[index].codecPrivate.count >= 2 {
                let bits = UInt16(tracks[index].codecPrivate[0]) << 8 | UInt16(tracks[index].codecPrivate[1])
                if bits >> 11 == 2 && ((bits >> 7) & 15) != 15 {
                    let frames = bits & 4 != 0 ? 960 : 1024
                    tracks[index].defaultDuration = Int64((Double(frames) * 1e9 / tracks[index].sampleRate).rounded())
                }
            }
            for packet in tracks[index].packets.indices where tracks[index].packets[packet].durationNS == 0 {
                tracks[index].packets[packet].durationNS = tracks[index].defaultDuration
            }
        }
    }

    private static let segmentIDs: Set<UInt64> = [0x1F43B675, 0x1549A966, 0x1654AE6B, 0x1C53BB6B, 0x114D9B74, 0x1941A469, 0x1043A770, 0x1254C367]
    private static func clusterEnd(_ file: FileHandle, _ cluster: EBML.Element, _ limit: UInt64) throws -> UInt64 {
        var position = cluster.body
        while position < limit {
            let item = try EBML.header(file, at: position, limit: limit)
            if segmentIDs.contains(item.id) { return position }
            try mkvCheck(!item.unknown, "unknown-size Cluster child")
            position = item.end
        }
        return position
    }
    private static func readTrack(_ file: FileHandle, _ element: EBML.Element) throws -> MatroskaTrack {
        var track = MatroskaTrack()
        for item in try EBML.children(file, element.body, element.end) {
            switch item.id {
            case 0xD7: track.number = EBML.value(try EBML.data(file, item))
            case 0x83: track.kind = EBML.value(try EBML.data(file, item))
            case 0x88: track.isDefault = EBML.value(try EBML.data(file, item)) != 0
            case 0xB9: track.enabled = EBML.value(try EBML.data(file, item)) != 0
            case 0x86: track.codec = String(decoding: try EBML.data(file, item), as: UTF8.self)
            case 0x63A2: track.codecPrivate = try EBML.data(file, item)
            case 0x23E383: track.defaultDuration = Int64(EBML.value(try EBML.data(file, item)))
            case 0x56AA: track.codecDelay = Int64(EBML.value(try EBML.data(file, item)))
            case 0x6D80: throw MatroskaError.invalid("encrypted or compressed selected-track content is unsupported")
            case 0xE0, 0xE1:
                for field in try EBML.children(file, item.body, item.end) {
                    let bytes = try EBML.data(file, field), value = EBML.value(bytes)
                    switch field.id {
                    case 0xB0: track.width = Int(clamping: value)
                    case 0xBA: track.height = Int(clamping: value)
                    case 0x9F: track.channels = Int(clamping: value)
                    case 0x6264: track.bitDepth = Int(clamping: value)
                    case 0xB5:
                        track.sampleRate = bytes.count == 8 ? Double(bitPattern: value) : Double(Float(bitPattern: UInt32(truncatingIfNeeded: value)))
                    case 0x55B0:
                        for color in try EBML.children(file, field.body, field.end) {
                            let code = EBML.value(try EBML.data(file, color))
                            switch color.id { case 0x55B1: track.matrix = code; case 0x55B9: track.range = code
                            case 0x55BA: track.transfer = code; case 0x55BB: track.primaries = code
                            case 0x55BC: track.maxCLL = code; case 0x55BD: track.maxFALL = code
                            case 0x55D0:
                                for field in try EBML.children(file, color.body, color.end) {
                                    let bytes = try EBML.data(file, field), bits = EBML.value(bytes)
                                    let value = bytes.count == 8 ? Double(bitPattern: bits) : Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
                                    if (0x55D1...0x55DA).contains(field.id) && value.isFinite && value >= 0 && value <= (field.id >= 0x55D9 ? 10000 : 1) { track.mastering[field.id] = value }
                                }
                            default: break }
                        }
                    default: break
                    }
                }
            case 0x41E4:
                let fields = try EBML.children(file, item.body, item.end)
                if let type = fields.first(where: { $0.id == 0x41E7 }), let extra = fields.first(where: { $0.id == 0x41ED }) {
                    let code = try EBML.data(file, type)
                    let name = String(decoding: EBML.uint(EBML.value(code), width: 4), as: UTF8.self)
                    if ["dvcC", "dvvC", "dvwC", "hvcE", "avcE"].contains(name) { track.additions[name] = try EBML.data(file, extra) }
                }
            default: break
            }
        }
        return track
    }

    private mutating func scanCluster(_ file: FileHandle, _ cluster: EBML.Element, _ limit: UInt64) throws -> UInt64 {
        var position = cluster.body, timestamp: Int64 = 0
        while position < cluster.end {
            let item = try EBML.header(file, at: position, limit: cluster.end)
            if cluster.unknown && Self.segmentIDs.contains(item.id) { break }
            switch item.id {
            case 0xE7: timestamp = Int64(EBML.value(try EBML.data(file, item)))
            case 0xA3: try scanBlock(file, item, timestamp: timestamp, simple: true, duration: 0, sync: false)
            case 0xA0:
                let fields = try EBML.children(file, item.body, item.end)
                if let block = fields.first(where: { $0.id == 0xA1 }) {
                    let duration = try fields.first(where: { $0.id == 0x9B }).map { Int64(EBML.value(try EBML.data(file, $0))) * timestampScale } ?? 0
                    try scanBlock(file, block, timestamp: timestamp, simple: false, duration: duration, sync: !fields.contains { $0.id == 0xFB })
                }
            default: break
            }
            try mkvCheck(!item.unknown, "unknown-sized block")
            position = item.end
        }
        return position
    }
    private mutating func scanBlock(_ file: FileHandle, _ block: EBML.Element, timestamp: Int64, simple: Bool, duration: Int64, sync: Bool) throws {
        let prefix = try EBML.read(file, block.body, Int(min(block.end - block.body, 4096)))
        var cursor = 0
        let (number, _) = try EBML.variable(prefix, &cursor)
        guard let index = tracks.firstIndex(where: { $0.number == number }) else { return }
        try mkvCheck(cursor <= prefix.count - 3, "truncated block header")
        let delta = Int16(bitPattern: UInt16(prefix[cursor]) << 8 | UInt16(prefix[cursor + 1]))
        let flags = prefix[cursor + 2]; cursor += 3
        let lace = (flags >> 1) & 3
        var sizes: [Int] = []
        if lace != 0 {
            try mkvCheck(cursor < prefix.count, "missing lace count")
            let count = Int(prefix[cursor]) + 1; cursor += 1
            if lace == 2 {
                let total = Int(block.end - block.body) - cursor
                try mkvCheck(total % count == 0, "invalid fixed lacing")
                sizes = Array(repeating: total / count, count: count)
            } else {
                for n in 0..<(count - 1) {
                    if lace == 1 {
                        var size = 0, byte: UInt8 = 255
                        while byte == 255 {
                            try mkvCheck(cursor < prefix.count, "oversized Xiph lace header")
                            byte = prefix[cursor]; cursor += 1; size += Int(byte)
                        }
                        sizes.append(size)
                    } else {
                        let (raw, width) = try EBML.variable(prefix, &cursor)
                        let size = n == 0 ? Int64(raw) : Int64(sizes[n - 1]) + Int64(raw) - ((Int64(1) << (width * 7 - 1)) - 1)
                        try mkvCheck(size >= 0 && size <= Int64(UInt32.max), "invalid EBML lacing")
                        sizes.append(Int(size))
                    }
                }
                sizes.append(Int(block.end - block.body) - cursor - sizes.reduce(0, +))
            }
        } else { sizes = [Int(block.end - block.body) - cursor] }
        let step = duration > 0 ? duration / Int64(sizes.count) : tracks[index].defaultDuration
        var offset = block.body + UInt64(cursor)
        for (n, size) in sizes.enumerated() {
            try mkvCheck(size > 0 && size <= 64 * 1024 * 1024 && UInt64(size) <= block.end - offset, "invalid packet size")
            tracks[index].packets.append(MatroskaPacket(offset: offset, size: UInt32(size),
                ptsNS: (timestamp + Int64(delta)) * timestampScale + Int64(n) * step - tracks[index].codecDelay,
                durationNS: step, sync: simple ? flags & 0x80 != 0 : sync))
            offset += UInt64(size)
        }
    }
}
