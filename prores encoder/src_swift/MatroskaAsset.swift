// Copyright © 2026 B00kerLouis. All rights reserved.
import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

/// Metadata-only ISO BMFF view over Matroska packets. AVFoundation requests
/// byte ranges; each request is translated back to the original MKV file.
/// No source movie, decoded carrier or temporary mdat is copied to disk.
private enum MKVBox {
    static func u16(_ n: UInt16) -> Data { EBML.uint(UInt64(n), width: 2) }
    static func u32(_ n: UInt32) -> Data { EBML.uint(UInt64(n), width: 4) }
    static func u64(_ n: UInt64) -> Data { EBML.uint(n, width: 8) }
    static func box(_ name: String, _ data: Data = Data()) -> Data { u32(UInt32(data.count + 8)) + Data(name.utf8) + data }
    static func full(_ name: String, _ flags: UInt32 = 0, _ data: Data = Data()) -> Data { box(name, u32(flags) + data) }
    static let matrix = [UInt32(0x10000), 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000].reduce(Data()) { $0 + u32($1) }
    static func runs(_ name: String, _ values: [UInt32], version: UInt32 = 0) -> Data {
        var records: [(UInt32, UInt32)] = []
        for value in values {
            if records.last?.1 == value { records[records.count - 1].0 += 1 }
            else { records.append((1, value)) }
        }
        return full(name, version, u32(UInt32(records.count)) + records.reduce(Data()) { $0 + u32($1.0) + u32($1.1) })
    }
    static func descriptor(_ tag: UInt8, _ bytes: Data) -> Data {
        let count = bytes.count
        return Data([tag, UInt8((count >> 21) & 127) | 128, UInt8((count >> 14) & 127) | 128,
            UInt8((count >> 7) & 127) | 128, UInt8(count & 127)]) + bytes
    }
    static func sampleEntry(_ track: MatroskaTrack) throws -> Data {
        if track.kind == 2 && track.codec.hasPrefix("A_QUICKTIME") {
            let entries = try ContainerBox.parse(track.codecPrivate)
            guard entries.count == 1 else { throw MatroskaError.invalid("invalid QuickTime audio codec configuration") }
            return track.codecPrivate
        }
        if track.kind == 1 {
            let codecs = ["V_MPEG4/ISO/AVC": ("avc1", "avcC"), "V_MPEGH/ISO/HEVC": ("hvc1", "hvcC"), "V_AV1": ("av01", "av1C")]
            guard let codec = codecs[track.codec], track.width > 0, track.width <= 65535,
                  track.height > 0, track.height <= 65535, !track.codecPrivate.isEmpty else {
                throw MatroskaError.invalid("unsupported video codec/configuration: \(track.codec)")
            }
            var body = Data(count: 6) + u16(1) + Data(count: 16) + u16(UInt16(track.width)) + u16(UInt16(track.height))
            body += u32(0x480000) + u32(0x480000) + u32(0) + u16(1) + Data(count: 32) + u16(24) + u16(65535)
            body += box(codec.1, track.codecPrivate)
            body += box("colr", Data("nclx".utf8) + u16(UInt16(clamping: track.primaries))
                + u16(UInt16(clamping: track.transfer)) + u16(UInt16(clamping: track.matrix)) + Data([track.range == 2 ? 128 : 0]))
            if (0x55D1...0x55DA).allSatisfy({ track.mastering[$0] != nil }) {
                var mastering = Data()
                for id: UInt64 in [0x55D3,0x55D4,0x55D5,0x55D6,0x55D1,0x55D2,0x55D7,0x55D8] {
                    mastering += u16(UInt16(clamping: Int((track.mastering[id]! * 50000).rounded())))
                }
                mastering += u32(UInt32(clamping: Int64((track.mastering[0x55D9]! * 10000).rounded())))
                mastering += u32(UInt32(clamping: Int64((track.mastering[0x55DA]! * 10000).rounded())))
                body += box("mdcv", mastering)
            }
            if track.maxCLL != nil || track.maxFALL != nil {
                body += box("clli", u16(UInt16(clamping: track.maxCLL ?? 0)) + u16(UInt16(clamping: track.maxFALL ?? 0)))
            }
            for key in track.additions.keys.sorted() { body += box(key, track.additions[key]!) }
            return box(codec.0, body)
        }
        if track.codec.hasPrefix("A_PCM/") {
            guard [8,16,24,32,64].contains(track.bitDepth), track.channels > 0, track.channels <= 64,
                  track.sampleRate.isFinite, track.sampleRate > 0, track.sampleRate <= 384000 else {
                throw MatroskaError.invalid("PCM requires its actual sample rate, bit depth and channel count")
            }
            let floating = track.codec == "A_PCM/FLOAT/IEEE", big = track.codec == "A_PCM/INT/BIG"
            let flags: UInt32 = (floating ? 1 : 4) | (big ? 2 : 0) | 8
            var body = Data(count: 6) + u16(1) + u16(2) + u16(0) + u32(0)
            body += u16(3) + u16(16) + u16(65534) + u16(0) + u32(0x10000) + u32(72)
            body += u64(track.sampleRate.bitPattern) + u32(UInt32(track.channels)) + u32(0x7f000000)
            body += u32(UInt32(track.bitDepth)) + u32(flags) + u32(UInt32(track.channels * track.bitDepth / 8)) + u32(1)
            return box("lpcm", body)
        }
        let type: String
        var extensions = Data()
        switch track.codec {
        case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG2/LC":
            type = "mp4a"
            let config = descriptor(0x05, track.codecPrivate)
            let decoder = descriptor(0x04, Data([0x40, 0x15, 0, 0, 0]) + u32(0) + u32(0) + config)
            extensions = full("esds", 0, descriptor(0x03, u16(1) + Data([0]) + decoder + descriptor(0x06, Data([2]))))
        case "A_PCM/INT/LIT": type = "sowt"
        case "A_PCM/INT/BIG": type = "twos"
        case "A_AC4": type = "ac-4"; extensions = box("dac4", track.codecPrivate)
        case "A_MPEGH/ISO/HEMHAS", "A_MPEGH/ISO/MHAS": type = "mhm1"; extensions = track.codecPrivate.isEmpty ? Data() : box("mhaC", track.codecPrivate)
        case "A_MPEGH/ISO/MHA": type = "mha1"; extensions = box("mhaC", track.codecPrivate)
        case "A_AVS3", "A_AV3A": type = "av3a"; extensions = track.codecPrivate.isEmpty ? Data() : box("dca3", track.codecPrivate)
        case "A_AC3": type = "ac-3"
        case "A_EAC3": type = "ec-3"
        case "A_MPEG/L3": type = ".mp3"
        case "A_ALAC": type = "alac"; extensions = box("alac", track.codecPrivate)
        case "A_FLAC": type = "fLaC"; extensions = full("dfLa", 0, track.codecPrivate.starts(with: Data("fLaC".utf8)) ? track.codecPrivate.dropFirst(4) : track.codecPrivate)
        case "A_TRUEHD": type = "mlpa"; extensions = track.codecPrivate.isEmpty ? Data() : box("dmlp", track.codecPrivate)
        case "A_DTS": type = "DTS "
        case "A_PCM/FLOAT/IEEE": type = track.bitDepth == 64 ? "fl64" : "fl32"
        default: throw MatroskaError.invalid("the original audio codec \(track.codec) has no registered ISO BMFF mapping or embedded QuickTime sample entry; a mapping is required, not an audio decoder")
        }
        guard track.channels > 0, track.channels <= 64, track.sampleRate.isFinite,
              track.sampleRate > 0, track.sampleRate <= 384000 else { throw MatroskaError.invalid("invalid audio format") }
        return box(type, Data(count: 6) + u16(1) + Data(count: 8) + u16(UInt16(track.channels))
            + u16(16) + u32(0) + u32(UInt32(min(track.sampleRate.rounded(), 65535)) << 16) + extensions)
    }
}

final class MatroskaAssetSource: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    struct Range { let start: UInt64; let source: UInt64; let count: UInt64 }
    let sourceURL: URL
    private let file: FileHandle
    private var prefix = Data()
    private(set) var nativeMovie: NativeMovieFile!
    private static let registry = Registry()
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var sources: [URL: MatroskaAssetSource] = [:]
    }
    static func nativeSource(for url: URL) -> NativeMovieFile? {
        registry.lock.lock(); defer { registry.lock.unlock() }
        return registry.sources[url]?.nativeMovie
    }
    static func release(url: URL) {
        registry.lock.lock(); registry.sources.removeValue(forKey: url); registry.lock.unlock()
    }
    private var ranges: [Range] = []
    private var length: UInt64 = 0
    private let queue = DispatchQueue(label: "B00kerLouis.MatroskaReader")
    private(set) var asset: AVURLAsset!

    init(url: URL, primaryOnly: Bool = true, allowAudioOnly: Bool = false) throws {
        sourceURL = url
        file = try FileHandle(forReadingFrom: url)
        let movie = try MatroskaFile(url: url, primaryOnly: primaryOnly, allowAudioOnly: allowAudioOnly)
        super.init()
        try build(movie)
        let virtualURL = URL(string: "prores-matroska://\(UUID().uuidString)/input.mov")!
        asset = AVURLAsset(url: virtualURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        asset.resourceLoader.setDelegate(self, queue: queue)
        Self.registry.lock.lock(); Self.registry.sources[virtualURL] = self; Self.registry.lock.unlock()
    }
    deinit { try? file.close() }

    private func build(_ movie: MatroskaFile) throws {
        var offsets: [[UInt64]] = [], cursor: UInt64 = 0
        for track in movie.tracks {
            var positions: [UInt64] = []
            for packet in track.packets {
                positions.append(cursor); ranges.append(Range(start: cursor, source: packet.offset, count: UInt64(packet.size)))
                cursor += UInt64(packet.size)
            }
            offsets.append(positions)
        }
        let origin = movie.tracks[0].packets.map(\.ptsNS).min() ?? 0
        var nativeTracks: [NativeMovieTrack] = []
        func makeMovie(_ baseOffset: UInt64) throws -> Data {
            var tracks = Data(), movieDuration: UInt64 = 0
            for (index, track) in movie.tracks.enumerated() {
                let video = track.kind == 1
                let entry = try ContainerBox.parse(MKVBox.sampleEntry(track))[0]
                let pcmTypes: Set<String> = ["lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64", "raw "]
                let pcm = !video && pcmTypes.contains(entry.type)
                let version = !video ? try ContainerBox.word(entry.payload, 8, 2) : 0
                let pcmChannels = pcm && version == 2 ? Int(try ContainerBox.word(entry.payload, 40)) : track.channels
                let pcmBits = pcm && version == 2 ? Int(try ContainerBox.word(entry.payload, 48)) : track.bitDepth
                let word = pcm ? pcmChannels * pcmBits / 8 : 0
                if pcm && word <= 0 { throw MatroskaError.invalid("PCM word size is absent from the source") }
                let sorted = track.packets.map(\.ptsNS).sorted()
                let rates: [(UInt32, Int64)] = [(24000,1001),(30000,1001),(60000,1001),(120000,1001),(24,1),(25,1),(30,1),(48,1),(50,1),(60,1),(120,1)]
                let exactRate = video ? rates.first { numerator, denominator in
                    let ns = Double(denominator) * 1e9 / Double(numerator)
                    guard abs(ns - Double(track.defaultDuration)) <= 2 else { return false }
                    return sorted.enumerated().allSatisfy { index, pts in
                        abs(Double(pts - (sorted.first ?? 0)) - Double(index) * ns) <= Double(movie.timestampScale) + 2
                    }
                } : nil
                let scale: UInt32 = video ? (exactRate?.0 ?? 1_000_000) : UInt32(track.sampleRate.rounded())
                var next: [Int64: Int64] = [:]
                for (a, b) in zip(sorted, sorted.dropFirst()) { if b > a { next[a] = b - a } }
                var duration: [UInt32] = [], cts: [UInt32] = [], dts: Int64 = 0, end: Int64 = 0
                for packet in track.packets {
                    let audioSamples: Int64 = pcm ? Int64(packet.size) / Int64(word)
                        : Int64((Double(packet.durationNS > 0 ? packet.durationNS : (next[packet.ptsNS] ?? track.defaultDuration)) * Double(scale) / 1e9).rounded())
                    let span = video ? (next[packet.ptsNS] ?? max(track.defaultDuration, 1))
                        : audioSamples * 1_000_000_000 / Int64(scale)
                    let ticks = video ? (exactRate?.1 ?? max(1, Int64((Double(span) * Double(scale) / 1e9).rounded()))) : audioSamples
                    let pts = exactRate.map { numerator, denominator in
                        Int64((Double(packet.ptsNS - origin) * Double(numerator) / (Double(denominator) * 1e9)).rounded()) * denominator
                    } ?? Int64((Double(packet.ptsNS - origin) * Double(scale) / 1e9).rounded())
                    guard ticks > 0, ticks <= Int64(UInt32.max), let offset = Int32(exactly: pts - dts) else {
                        throw MatroskaError.invalid("sample timing exceeds ISO BMFF limits")
                    }
                    duration.append(UInt32(ticks)); cts.append(UInt32(bitPattern: offset)); dts += ticks
                    end = max(end, pts + ticks)
                }
                let mediaDuration = UInt64(max(dts, end)), movieTicks = UInt64(max(0, end)) * 1000 / UInt64(scale)
                movieDuration = max(movieDuration, movieTicks)
                let stsd = MKVBox.full("stsd", 0, MKVBox.u32(1) + (try MKVBox.sampleEntry(track)))
                var tables = stsd
                var pcmCounts: [UInt32] = []
                if pcm {
                    pcmCounts = try track.packets.map { packet in
                        guard Int(packet.size) % word == 0 else { throw MatroskaError.invalid("PCM block does not contain whole sample frames") }
                        return packet.size / UInt32(word)
                    }
                    let total = pcmCounts.reduce(UInt64(0)) { $0 + UInt64($1) }
                    guard total <= UInt32.max else { throw MatroskaError.invalid("PCM movie sample count exceeds ISO BMFF limits") }
                    tables += MKVBox.full("stts", 0, MKVBox.u32(1) + MKVBox.u32(UInt32(total)) + MKVBox.u32(1))
                    var offsets = MKVBox.u32(0x01000000) + MKVBox.u32(UInt32(cts.count))
                    for (index, value) in cts.enumerated() { offsets += MKVBox.u32(pcmCounts[index]) + MKVBox.u32(value) }
                    if cts.contains(where: { $0 != 0 }) { tables += MKVBox.box("ctts", offsets) }
                    var chunks = MKVBox.u32(0) + MKVBox.u32(UInt32(pcmCounts.count))
                    for (index, count) in pcmCounts.enumerated() { chunks += MKVBox.u32(UInt32(index + 1)) + MKVBox.u32(count) + MKVBox.u32(1) }
                    tables += MKVBox.box("stsc", chunks)
                    tables += MKVBox.full("stsz", 0, MKVBox.u32(UInt32(word)) + MKVBox.u32(UInt32(total)))
                } else {
                    tables += MKVBox.runs("stts", duration) + MKVBox.runs("ctts", cts, version: 0x01000000)
                    tables += MKVBox.full("stsc", 0, MKVBox.u32(1) + MKVBox.u32(1) + MKVBox.u32(1) + MKVBox.u32(1))
                    tables += MKVBox.full("stsz", 0, MKVBox.u32(0) + MKVBox.u32(UInt32(track.packets.count)) + track.packets.reduce(Data()) { $0 + MKVBox.u32($1.size) })
                }
                tables += MKVBox.full("co64", 0, MKVBox.u32(UInt32(track.packets.count)) + offsets[index].reduce(Data()) { $0 + MKVBox.u64(baseOffset + $1) })
                if video {
                    let sync = track.packets.enumerated().filter { $0.element.sync }.map { UInt32($0.offset + 1) }
                    tables += MKVBox.full("stss", 0, MKVBox.u32(UInt32(sync.count)) + sync.reduce(Data()) { $0 + MKVBox.u32($1) })
                }
                let dinf = MKVBox.box("dinf", MKVBox.full("dref", 0, MKVBox.u32(1) + MKVBox.full("url ", 1)))
                let header = video ? MKVBox.full("vmhd", 1, Data(count: 8)) : MKVBox.full("smhd", 0, Data(count: 4))
                let minf = MKVBox.box("minf", header + dinf + MKVBox.box("stbl", tables))
                let mdhd = MKVBox.full("mdhd", 0x01000000, Data(count: 16) + MKVBox.u32(scale) + MKVBox.u64(mediaDuration) + MKVBox.u16(0x55c4) + MKVBox.u16(0))
                let hdlr = MKVBox.full("hdlr", 0, MKVBox.u32(0) + Data((video ? "vide" : "soun").utf8) + Data(count: 12) + Data([0]))
                var tkhd = Data(count: 16) + MKVBox.u32(UInt32(index + 1)) + MKVBox.u32(0) + MKVBox.u64(movieTicks)
                tkhd += Data(count: 8) + MKVBox.u16(0) + MKVBox.u16(0) + MKVBox.u16(video ? 0 : 0x100) + MKVBox.u16(0)
                tkhd += MKVBox.matrix + MKVBox.u32(UInt32(track.width) << 16) + MKVBox.u32(UInt32(track.height) << 16)
                let encodedTrack = MKVBox.box("trak", MKVBox.full("tkhd", 0x01000007, tkhd) + MKVBox.box("mdia", mdhd + hdlr + minf))
                tracks += encodedTrack
                if baseOffset == 0 {
                    let template = try ContainerBox.parse(encodedTrack)[0]
                    nativeTracks.append(NativeMovieTrack(template: template, id: UInt32(index + 1), scale: scale,
                        handler: video ? "vide" : "soun", descriptions: try ContainerBox.parse(MKVBox.sampleEntry(track)),
                        packets: track.packets, durations: duration, cts: cts.map { Int32(bitPattern: $0) },
                        descriptionIndices: Array(repeating: 1, count: track.packets.count), sampleCounts: pcmCounts))
                }
            }
            let mvhd = MKVBox.full("mvhd", 0x01000000, Data(count: 16) + MKVBox.u32(1000) + MKVBox.u64(movieDuration)
                + MKVBox.u32(0x10000) + MKVBox.u16(0x100) + Data(count: 10) + MKVBox.matrix + Data(count: 24) + MKVBox.u32(UInt32(movie.tracks.count + 1)))
            return MKVBox.box("moov", mvhd + tracks)
        }
        let ftyp = MKVBox.box("ftyp", Data("qt  ".utf8) + MKVBox.u32(0) + Data("qt  ".utf8))
        let placeholder = try makeMovie(0)
        let base = UInt64(ftyp.count + placeholder.count + 16)
        nativeMovie = NativeMovieFile(url: sourceURL, movie: try ContainerBox.parse(placeholder)[0], scale: 1000, tracks: nativeTracks, identity: try ContainerSourceIdentity.read(file))
        prefix = ftyp + (try makeMovie(base)) + MKVBox.u32(1) + Data("mdat".utf8) + MKVBox.u64(cursor + 16)
        ranges = ranges.map { Range(start: $0.start + base, source: $0.source, count: $0.count) }
        length = base + cursor
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        do {
            if let info = request.contentInformationRequest {
                info.contentType = UTType.quickTimeMovie.identifier
                info.contentLength = Int64(length)
                info.isByteRangeAccessSupported = true
            }
            if let data = request.dataRequest {
                var offset = UInt64(max(data.currentOffset, data.requestedOffset))
                let end = data.requestsAllDataToEndOfResource ? length : min(length, UInt64(data.requestedOffset) + UInt64(data.requestedLength))
                while offset < end && !request.isCancelled {
                    if offset < UInt64(prefix.count) {
                        let stop = Int(min(end, UInt64(prefix.count)))
                        data.respond(with: prefix.subdata(in: Int(offset)..<stop)); offset = UInt64(stop)
                    } else {
                        var lo = 0, hi = ranges.count
                        while lo < hi {
                            let mid = (lo + hi) / 2
                            if ranges[mid].start + ranges[mid].count <= offset { lo = mid + 1 } else { hi = mid }
                        }
                        guard lo < ranges.count, ranges[lo].start <= offset else { throw MatroskaError.invalid("invalid virtual packet range") }
                        let range = ranges[lo], inside = offset - range.start
                        let count = Int(min(1024 * 1024, min(end - offset, range.count - inside)))
                        let bytes = try EBML.read(file, range.source + inside, count)
                        data.respond(with: bytes); offset += UInt64(count)
                    }
                }
            }
            request.finishLoading()
        } catch { request.finishLoading(with: error) }
        return true
    }
}

/// Folder discovery uses the same native MKV header view as single-file input.
/// The temporary delegate is released after probing, without retagging/copying
/// ordinary movie sources or retaining every batch source in memory.
func mediaContainerHasVideo(at url: URL) async -> Bool {
    var source: MatroskaAssetSource?
    if (try? NativeContainerKind.identify(url)) == .matroska {
        guard let opened = try? MatroskaAssetSource(url: url) else { return false }
        source = opened
    }
    defer { if let source { MatroskaAssetSource.release(url: source.asset.url) } }
    let asset = source?.asset ?? AVURLAsset(url: url)
    return ((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty == false
}
