// Copyright © 2026 B00kerLouis. All rights reserved.
import Foundation

/// Native packet muxing bypasses platform decoder and writer codec whitelists.
/// Unknown ISO audio sample entries use Matroska's registered A_QUICKTIME
/// mapping, preserving the complete sample entry and compressed packets.
enum MatroskaMuxer {
    private struct Stream { let track: NativeMovieTrack; let entry: Data; let delay: Int64 }
    static func write(movieURL: URL, outputURL: URL,
        additionalFiles: [(working: URL, final: URL)] = [],
        cancellationRequested: @escaping @Sendable () -> Bool = { Task.isCancelled }) async throws {
        let movie = try NativeMovieFile(url: movieURL)
        let input = try FileHandle(forReadingFrom: movieURL)
        defer { try? input.close() }
        try movie.identity?.validate(input)
        var streams: [Stream] = []
        for (index, track) in movie.tracks.enumerated() {
            guard track.descriptions.count == 1 else { throw MatroskaError.invalid("Matroska cannot silently discard changing sample descriptions") }
            let sample = track.descriptions[0], video = track.handler == "vide"
            var entry = EBML.number(0xD7, UInt64(index + 1)) + EBML.number(0x73C5, UInt64(index + 1))
                + EBML.number(0x83, video ? 1 : 2) + EBML.number(0x88, 1) + EBML.number(0x9C, 0)
            if video {
                let configOffset = 78
                guard sample.payload.count >= configOffset else { throw MatroskaError.invalid("truncated visual sample entry") }
                let atoms = try ContainerBox.sampleExtensions(sample.payload.subdata(in: configOffset..<sample.payload.count))
                let names: [String: (String, String)] = ["avc1": ("V_MPEG4/ISO/AVC", "avcC"), "avc3": ("V_MPEG4/ISO/AVC", "avcC"),
                    "hvc1": ("V_MPEGH/ISO/HEVC", "hvcC"), "hev1": ("V_MPEGH/ISO/HEVC", "hvcC"), "dvh1": ("V_MPEGH/ISO/HEVC", "hvcC"),
                    "dvhe": ("V_MPEGH/ISO/HEVC", "hvcC"), "av01": ("V_AV1", "av1C"), "dav1": ("V_AV1", "av1C")]
                guard let codec = names[sample.type], let config = atoms.first(where: { $0.type == codec.1 }) else {
                    throw MatroskaError.invalid("MKV video requires H.264, HEVC or AV1 codec configuration")
                }
                entry += EBML.string(0x86, codec.0) + EBML.element(0x63A2, config.payload)
                var color = Data()
                if let colr = atoms.first(where: { $0.type == "colr" }), colr.payload.count >= 10 {
                    color += EBML.number(0x55BB, try ContainerBox.word(colr.payload, 4, 2))
                    color += EBML.number(0x55BA, try ContainerBox.word(colr.payload, 6, 2))
                    color += EBML.number(0x55B1, try ContainerBox.word(colr.payload, 8, 2))
                    if colr.payload.count >= 11 { color += EBML.number(0x55B9, colr.payload[10] & 128 != 0 ? 2 : 1) }
                }
                if let mastering = atoms.first(where: { $0.type == "mdcv" }), mastering.payload.count == 24 {
                    var fields = Data()
                    let mapping: [(UInt64, Int)] = [(0x55D3,0),(0x55D4,2),(0x55D5,4),(0x55D6,6),(0x55D1,8),(0x55D2,10),(0x55D7,12),(0x55D8,14)]
                    for (id, offset) in mapping { fields += EBML.float(id, Double(try ContainerBox.word(mastering.payload, offset, 2)) / 50000) }
                    fields += EBML.float(0x55D9, Double(try ContainerBox.word(mastering.payload, 16)) / 10000)
                    fields += EBML.float(0x55DA, Double(try ContainerBox.word(mastering.payload, 20)) / 10000)
                    color += EBML.element(0x55D0, fields)
                }
                if let light = atoms.first(where: { $0.type == "clli" }), light.payload.count == 4 {
                    color += EBML.number(0x55BC, try ContainerBox.word(light.payload, 0, 2)) + EBML.number(0x55BD, try ContainerBox.word(light.payload, 2, 2))
                }
                entry += EBML.element(0xE0, EBML.number(0xB0, try ContainerBox.word(sample.payload, 24, 2))
                    + EBML.number(0xBA, try ContainerBox.word(sample.payload, 26, 2)) + (color.isEmpty ? Data() : EBML.element(0x55B0, color)))
                if let duration = track.durations.first, track.durations.allSatisfy({ $0 == duration }) {
                    entry += EBML.number(0x23E383, UInt64(duration) * 1_000_000_000 / UInt64(track.scale))
                }
                var addID: UInt64 = 2
                for atom in atoms where ["dvcC", "dvvC", "dvwC", "hvcE", "avcE"].contains(atom.type) {
                    entry += EBML.element(0x41E4, EBML.number(0x41F0, addID)
                        + EBML.number(0x41E7, EBML.value(Data(atom.type.utf8))) + EBML.element(0x41ED, atom.payload)); addID += 1
                }
                if addID > 2 { entry += EBML.number(0x55EE, addID - 1) }
            } else {
                // A_QUICKTIME is the codec-agnostic, registered escape for ISO
                // sample entries. Known mappings remain interoperable with
                // existing Matroska decoders; no codec is decoded or replaced.
                let version = try ContainerBox.word(sample.payload, 8, 2)
                let extensionOffset = version == 2 ? 64 : (version == 1 ? 44 : 28)
                let atoms = sample.payload.count > extensionOffset ? (try? ContainerBox.sampleExtensions(sample.payload.subdata(in: extensionOffset..<sample.payload.count))) ?? [] : []
                var codec = "A_QUICKTIME", config = sample.data
                if sample.type == "mp4a", let esds = atoms.first(where: { $0.type == "esds" }), let asc = audioSpecificConfig(esds.payload) {
                    codec = "A_AAC"; config = asc
                } else if (sample.type == "lpcm" && version == 2) || ["sowt", "twos", "in24", "in32", "fl32", "fl64"].contains(sample.type) {
                    var floating = sample.type.hasPrefix("fl"), bigEndian = sample.type != "sowt"
                    if sample.type == "lpcm" {
                        let flags = try ContainerBox.word(sample.payload, 52)
                        floating = flags & 1 != 0; bigEndian = flags & 2 != 0
                    } else {
                        var endian = atoms.first { $0.type == "enda" }
                        if endian == nil, let wave = atoms.first(where: { $0.type == "wave" }) {
                            endian = try ContainerBox.sampleExtensions(wave.payload).first { $0.type == "enda" }
                        }
                        if let endian { bigEndian = try ContainerBox.word(endian.payload, 0, 2) == 0 }
                    }
                    if floating && bigEndian {
                        // Matroska's native IEEE float mapping is little-endian.
                        // A distinct QuickTime float FourCC preserves big-endian
                        // words without exposing the ambiguous LPCM v2 tag.
                        if sample.type == "lpcm" {
                            let bits = try ContainerBox.word(sample.payload, 48)
                            config = ContainerBox(type: bits == 64 ? "fl64" : "fl32", payload: sample.payload).data
                        }
                    } else {
                        codec = floating ? "A_PCM/FLOAT/IEEE" : (bigEndian ? "A_PCM/INT/BIG" : "A_PCM/INT/LIT")
                        config = Data()
                    }
                } else if sample.type == "ac-3" { codec = "A_AC3"; config = Data() }
                else if sample.type == "ec-3" { codec = "A_EAC3"; config = Data() }
                else if sample.type == ".mp3" { codec = "A_MPEG/L3"; config = Data() }
                var channels = try ContainerBox.word(sample.payload, 16, 2), bits = try ContainerBox.word(sample.payload, 18, 2)
                var rate = Double(try ContainerBox.word(sample.payload, 24)) / 65536
                if version == 2 {
                    rate = Double(bitPattern: try ContainerBox.word(sample.payload, 32, 8))
                    channels = try ContainerBox.word(sample.payload, 40); bits = try ContainerBox.word(sample.payload, 48)
                } else {
                    // QuickTime v1 keeps 16 in the legacy sample-size field for
                    // these entries; their registered FourCC supplies precision.
                    switch sample.type { case "in24": bits = 24; case "in32", "fl32": bits = 32; case "fl64": bits = 64; default: break }
                }
                entry += EBML.string(0x86, codec) + (config.isEmpty ? Data() : EBML.element(0x63A2, config))
                let pcm = ["lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64", "raw "].contains(sample.type)
                // Compressed AudioSampleEntry.sampleSize is a reserved field,
                // not the source's quantization depth. Never publish it as one.
                entry += EBML.element(0xE1, EBML.float(0xB5, rate) + EBML.number(0x9F, channels) + (pcm && bits > 0 ? EBML.number(0x6264, bits) : Data()))
            }
            let minimum = track.packets.map(\.ptsNS).min() ?? 0
            let delay = max(0, -minimum)
            if delay > 0 { entry += EBML.number(0x56AA, UInt64(delay)) }
            streams.append(Stream(track: track, entry: EBML.element(0xAE, entry), delay: delay))
        }
        guard streams.contains(where: { $0.track.handler == "vide" }) else { throw MatroskaError.invalid("no video track") }
        let transaction = DirectOutputTransaction(finalURL: outputURL)
        defer { try? FileManager.default.removeItem(at: transaction.workingURL) }
        FileManager.default.createFile(atPath: transaction.workingURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: transaction.workingURL)
        defer { try? output.close() }
        let header = EBML.element(0x1A45DFA3, EBML.number(0x4286, 1) + EBML.number(0x42F7, 1)
            + EBML.number(0x42F2, 4) + EBML.number(0x42F3, 8) + EBML.string(0x4282, "matroska") + EBML.number(0x4287, 4) + EBML.number(0x4285, 2))
        try output.write(contentsOf: header + EBML.uint(0x18538067) + Data([1, 255, 255, 255, 255, 255, 255, 255]))
        let segmentStart = try output.offset()
        let duration = streams.flatMap { $0.track.packets }.map { $0.ptsNS + $0.durationNS }.max() ?? 0
        try output.write(contentsOf: EBML.element(0x1549A966, EBML.number(0x2AD7B1, 1000)
            + EBML.string(0x4D80, "ProResEncoderFramework") + EBML.string(0x5741, "B00kerLouis/ProResEncoderFramework")
            + EBML.float(0x4489, Double(duration) / 1000)) + EBML.element(0x1654AE6B, streams.reduce(Data()) { $0 + $1.entry }))
        var indices = Array(repeating: 0, count: streams.count), cues = Data()
        while let index = streams.indices.filter({ indices[$0] < streams[$0].track.packets.count }).min(by: {
            streams[$0].track.packets[indices[$0]].ptsNS < streams[$1].track.packets[indices[$1]].ptsNS
        }) {
            if cancellationRequested() { throw CancellationError() }
            let packet = streams[index].track.packets[indices[index]], timestamp = UInt64((packet.ptsNS + streams[index].delay + 500) / 1000)
            let position = try output.offset() - segmentStart
            let bytes = try EBML.read(input, packet.offset, Int(packet.size))
            let audio = streams[index].track.handler == "soun"
            let payload = EBML.vint(UInt64(index + 1)) + Data([0, 0, !audio && packet.sync ? 128 : 0]) + bytes
            let block = audio ? EBML.element(0xA0, EBML.element(0xA1, payload)
                + EBML.number(0x9B, UInt64(max(1, (packet.durationNS + 500) / 1000)))) : EBML.element(0xA3, payload)
            try output.write(contentsOf: EBML.element(0x1F43B675, EBML.number(0xE7, timestamp) + block))
            if streams[index].track.handler == "vide", packet.sync {
                cues += EBML.element(0xBB, EBML.number(0xB3, timestamp) + EBML.element(0xB7, EBML.number(0xF7, UInt64(index + 1)) + EBML.number(0xF1, position)))
            }
            indices[index] += 1
        }
        try movie.identity?.validate(input)
        try output.write(contentsOf: EBML.element(0x1C53BB6B, cues)); try output.synchronize(); try output.close()
        let verified = try MatroskaFile(url: transaction.workingURL)
        guard verified.tracks.first?.packets.count == streams.first?.track.packets.count else { throw MatroskaError.invalid("output packet coverage mismatch") }
        if cancellationRequested() { throw CancellationError() }
        try transaction.commit(additionalFiles: additionalFiles)
    }

    private static func audioSpecificConfig(_ data: Data) -> Data? {
        func find(_ begin: Int, _ end: Int) -> Data? {
            var offset = begin
            while offset < end {
                let tag = data[offset]; offset += 1
                var count = 0, ended = false
                for _ in 0..<4 {
                    guard offset < end else { return nil }
                    let byte = data[offset]; offset += 1; count = (count << 7) | Int(byte & 127)
                    if byte & 128 == 0 { ended = true; break }
                }
                guard ended, count <= end - offset else { return nil }
                if tag == 5 { return data.subdata(in: offset..<offset + count) }
                let skip: Int = tag == 3 ? 3 : (tag == 4 ? 13 : count)
                if skip < count, let found = find(offset + skip, offset + count) { return found }
                offset += count
            }
            return nil
        }
        return data.count > 4 ? find(4, data.count) : nil
    }
}
