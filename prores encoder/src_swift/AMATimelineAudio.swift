// Copyright © 2026 B00kerLouis. All rights reserved.
import Foundation
@preconcurrency import AVFoundation
import AudioToolbox

/// Minimal bounded MOV metadata access. Payload copies use 1 MiB chunks.
/// In particular, adding timeline audio never remuxes the video mdat or changes
/// its sample entries, Dolby Vision configuration, PHDR tracks or timecode.
struct ContainerBox {
    var type: String
    var payload: Data
    var data: Data { EBML.uint(UInt64(payload.count + 8), width: 4) + (type.data(using: .isoLatin1) ?? Data(type.utf8)) + payload }
    static func parse(_ data: Data) throws -> [ContainerBox] {
        var result: [ContainerBox] = [], offset = 0
        while offset < data.count {
            guard offset <= data.count - 8 else { throw MatroskaError.invalid("truncated movie metadata") }
            let size = Int(EBML.value(data[offset..<offset + 4]))
            guard size >= 8, size <= data.count - offset else { throw MatroskaError.invalid("invalid movie metadata size") }
            result.append(ContainerBox(type: String(data: data[offset + 4..<offset + 8], encoding: .isoLatin1)!, payload: data.subdata(in: offset + 8..<offset + size)))
            offset += size
        }
        return result
    }
    static func sampleExtensions(_ data: Data) throws -> [ContainerBox] {
        var boxes: [ContainerBox] = [], offset = 0
        while offset < data.count {
            if data.count - offset == 4 && data.suffix(4).allSatisfy({ $0 == 0 }) { break }
            guard offset <= data.count - 8 else { throw MatroskaError.invalid("truncated sample-entry extension") }
            let count = Int(try word(data, offset))
            guard count >= 8 && count <= data.count - offset else { throw MatroskaError.invalid("invalid sample-entry extension") }
            boxes.append(contentsOf: try parse(data.subdata(in: offset..<offset + count)))
            offset += count
        }
        return boxes
    }
    func child(_ type: String) throws -> ContainerBox {
        guard let child = try Self.parse(payload).first(where: { $0.type == type }) else { throw MatroskaError.invalid("missing movie \(type)") }
        return child
    }
    static func word(_ data: Data, _ offset: Int, _ count: Int = 4) throws -> UInt64 {
        guard offset >= 0, count > 0, offset <= data.count - count else { throw MatroskaError.invalid("truncated movie field") }
        return EBML.value(data[offset..<offset + count])
    }
    static func replace(_ data: inout Data, at offset: Int, value: UInt64, width: Int = 4) throws {
        guard offset >= 0, offset <= data.count - width else { throw MatroskaError.invalid("truncated mutable movie field") }
        data.replaceSubrange(offset..<offset + width, with: EBML.uint(value, width: width))
    }
    struct Location { let type: String; let offset: UInt64; let size: UInt64; let header: UInt64 }
    static func locations(_ file: FileHandle) throws -> [Location] {
        let end = try file.seekToEnd()
        var offset: UInt64 = 0, result: [Location] = []
        while offset < end {
            let head = try EBML.read(file, offset, Int(min(16, end - offset)))
            guard head.count >= 8 else { throw MatroskaError.invalid("truncated top-level movie atom") }
            let small = EBML.value(head.prefix(4)), header: UInt64 = small == 1 ? 16 : 8
            let size = small == 0 ? end - offset : (small == 1 ? EBML.value(head[8..<16]) : small)
            guard size >= header, size <= end - offset else { throw MatroskaError.invalid("invalid top-level movie atom") }
            result.append(Location(type: String(decoding: head[4..<8], as: UTF8.self), offset: offset, size: size, header: header))
            offset += size
        }
        return result
    }
    static func movie(_ file: FileHandle, _ locations: [Location]) throws -> (Location, ContainerBox) {
        guard let location = locations.first(where: { $0.type == "moov" }), location.size <= 256 * 1024 * 1024 else {
            throw MatroskaError.invalid("missing or oversized movie metadata")
        }
        return (location, ContainerBox(type: "moov", payload: try EBML.read(file, location.offset + location.header, Int(location.size - location.header))))
    }
}

enum AMATimelineAudio {
    /// CAF files contain the actual negotiated host PCM. No audio encoder or
    /// source-clip reconstruction participates in this path.
    static func append(to videoURL: URL, audioURLs: [URL], interleaveStereo: Bool = false, expectedDuration: CMTime? = nil, cancelled: @escaping @Sendable () -> Bool) async throws {
        guard !audioURLs.isEmpty else { return }
        var files = audioURLs
        var stereo: URL?
        defer { if let stereo { try? FileManager.default.removeItem(at: stereo) } }
        if interleaveStereo && audioURLs.count == 2 {
            let url = videoURL.deletingLastPathComponent().appendingPathComponent(".ama-stereo-\(UUID().uuidString).caf")
            try interleave(audioURLs, to: url, cancelled: cancelled)
            stereo = url; files = [url]
        }
        let audioMovie = videoURL.deletingLastPathComponent().appendingPathComponent(".ama-audio-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: audioMovie) }
        let writer = try AVAssetWriter(outputURL: audioMovie, fileType: .mov)
        let duration: CMTime
        if let expectedDuration { duration = expectedDuration }
        else { duration = try await AVURLAsset(url: videoURL).load(.duration) }
        writer.movieTimeScale = duration.timescale
        struct Pump { let reader: AVAssetReader; let output: AVAssetReaderTrackOutput; let input: AVAssetWriterInput; var sample: CMSampleBuffer? }
        var pumps: [Pump] = []
        for url in files {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let format = try await track.load(.formatDescriptions).first else { throw MatroskaError.invalid("host PCM track is unreadable") }
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: .zero, duration: duration)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            guard reader.canAdd(output), writer.canAdd(input) else { throw MatroskaError.invalid("MOV rejected negotiated host PCM") }
            reader.add(output); writer.add(input)
            pumps.append(Pump(reader: reader, output: output, input: input))
        }
        guard writer.startWriting() else { throw writer.error ?? MatroskaError.invalid("PCM movie did not start") }
        writer.startSession(atSourceTime: .zero)
        do {
            for index in pumps.indices {
                guard pumps[index].reader.startReading() else { throw pumps[index].reader.error ?? MatroskaError.invalid("host PCM reader did not start") }
                pumps[index].sample = pumps[index].output.copyNextSampleBuffer()
            }
            var deadline = ProcessInfo.processInfo.systemUptime + 30
            while pumps.contains(where: { $0.sample != nil }) {
                if cancelled() { throw CancellationError() }
                var progressed = false
                for index in pumps.indices where pumps[index].sample != nil && pumps[index].input.isReadyForMoreMediaData {
                    guard pumps[index].input.append(pumps[index].sample!) else { throw writer.error ?? MatroskaError.invalid("MOV rejected host PCM sample") }
                    pumps[index].sample = autoreleasepool { pumps[index].output.copyNextSampleBuffer() }
                    if pumps[index].sample == nil { pumps[index].input.markAsFinished() }
                    progressed = true
                }
                if progressed { deadline = ProcessInfo.processInfo.systemUptime + 30 }
                else {
                    guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                        throw writer.error ?? MatroskaError.invalid("host PCM mux timed out")
                    }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            for pump in pumps {
                guard pump.reader.status == .completed else { throw pump.reader.error ?? MatroskaError.invalid("host PCM delivery is incomplete") }
                pump.input.markAsFinished()
            }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? MatroskaError.invalid("host PCM movie did not complete") }
            try NativeContainerAudio.append(source: NativeMovieFile(url: audioMovie), to: videoURL)
        } catch {
            writer.cancelWriting(); for pump in pumps { pump.reader.cancelReading() }; throw error
        }
    }

    /// Interleave the actual negotiated mono sample words, preserving every
    /// bit. The host's stereo mix is delivered as numbered L/R mono tracks.
    private static func interleave(_ urls: [URL], to destination: URL, cancelled: () -> Bool) throws {
        var inputs: [AudioFileID] = [], formats: [AudioStreamBasicDescription] = [], lengths: [UInt64] = []
        defer { for input in inputs { AudioFileClose(input) } }
        for url in urls {
            var input: AudioFileID?
            guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &input) == noErr, let input else {
                throw MatroskaError.invalid("host stereo channel could not be opened")
            }
            inputs.append(input)
            var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFileGetProperty(input, kAudioFilePropertyDataFormat, &size, &format) == noErr,
                  format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame == 1,
                  format.mFramesPerPacket == 1, format.mBytesPerFrame > 0 else {
                throw MatroskaError.invalid("host stereo mix did not deliver mono PCM channels")
            }
            formats.append(format)
            var bytes: UInt64 = 0; size = UInt32(MemoryLayout<UInt64>.size)
            guard AudioFileGetProperty(input, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr else {
                throw MatroskaError.invalid("host stereo channel length is unavailable")
            }
            lengths.append(bytes)
        }
        let left = formats[0], right = formats[1]
        guard left.mSampleRate == right.mSampleRate, left.mFormatFlags == right.mFormatFlags,
              left.mBitsPerChannel == right.mBitsPerChannel, left.mBytesPerFrame == right.mBytesPerFrame,
              lengths[0] == lengths[1] else { throw MatroskaError.invalid("host L/R channel layouts or lengths differ") }
        var format = left
        format.mChannelsPerFrame = 2; format.mBytesPerFrame *= 2; format.mBytesPerPacket *= 2
        var created: AudioFileID?
        guard AudioFileCreateWithURL(destination as CFURL, kAudioFileCAFType, &format, [], &created) == noErr, let created else {
            throw MatroskaError.invalid("host stereo transaction could not be created")
        }
        defer { AudioFileClose(created) }
        let word = Int(left.mBytesPerFrame), capacity = max(word, (1024 * 1024 / word) * word)
        var offset: UInt64 = 0
        while offset < lengths[0] {
            if cancelled() { throw CancellationError() }
            let count = Int(min(UInt64(capacity), lengths[0] - offset))
            var channels = [Data(count: count), Data(count: count)]
            for index in 0..<2 {
                var actual = UInt32(count)
                let status = channels[index].withUnsafeMutableBytes { AudioFileReadBytes(inputs[index], false, Int64(offset), &actual, $0.baseAddress!) }
                guard status == noErr, actual == count else { throw MatroskaError.invalid("incomplete host stereo channel") }
            }
            var interleaved = Data(count: count * 2)
            interleaved.withUnsafeMutableBytes { destination in
                channels[0].withUnsafeBytes { l in channels[1].withUnsafeBytes { r in
                    for sample in 0..<(count / word) {
                        memcpy(destination.baseAddress!.advanced(by: sample * word * 2), l.baseAddress!.advanced(by: sample * word), word)
                        memcpy(destination.baseAddress!.advanced(by: sample * word * 2 + word), r.baseAddress!.advanced(by: sample * word), word)
                    }
                } }
            }
            var written = UInt32(interleaved.count)
            let status = interleaved.withUnsafeBytes { AudioFileWriteBytes(created, false, Int64(offset * 2), &written, $0.baseAddress!) }
            guard status == noErr, written == interleaved.count else { throw MatroskaError.invalid("host stereo words could not be written") }
            offset += UInt64(count)
        }
    }
}
