// Copyright © 2026 B00kerLouis. All rights reserved.
// Compile with Matroska.swift, MatroskaAsset.swift, AMATimelineAudio.swift and
// NativeContainerAudio.swift. This checks packets without an audio decoder.
import Foundation
import CryptoKit

@main struct NativePacketChecks {
    struct Record: Codable, Equatable {
        let entryFourCC: [String]
        let entrySHA256: [String]
        let packets: Int
        let payloadSHA256: String
    }
    static func records(_ source: NativeMovieFile) throws -> [Record] {
        let file = try FileHandle(forReadingFrom: source.url)
        defer { try? file.close() }
        return try source.tracks.filter { $0.handler == "soun" }.map { track in
            var digest = SHA256()
            for packet in track.packets { digest.update(data: try EBML.read(file, packet.offset, Int(packet.size))) }
            return Record(entryFourCC: track.descriptions.map(\.type), entrySHA256: track.descriptions.map { SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined() },
                packets: track.packets.count, payloadSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
    static func main() throws {
        let a = CommandLine.arguments
        guard a.count >= 3 else { throw MatroskaError.invalid("Usage: native-packets inspect|append|compare movie [movie]") }
        let first = try NativeMovieFile(url: URL(fileURLWithPath: a[2]))
        if a[1] == "append" {
            try NativeContainerAudio.append(source: first, to: URL(fileURLWithPath: a[3]))
            print("PASS native append")
        } else if a[1] == "compare" {
            let expected = try records(first)
            let actual: [Record]
            if URL(fileURLWithPath: a[3]).pathExtension == "mkv" {
                let source = try MatroskaAssetSource(url: URL(fileURLWithPath: a[3]), primaryOnly: false)
                actual = try records(source.nativeMovie)
                MatroskaAssetSource.release(url: source.asset.url)
            } else { actual = try records(NativeMovieFile(url: URL(fileURLWithPath: a[3]))) }
            guard expected == actual else {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(expected), as: UTF8.self))
                print(String(decoding: try encoder.encode(actual), as: UTF8.self))
                throw MatroskaError.invalid("audio packet or complete sample entry changed")
            }
            print("PASS complete sample entries and payload hashes for \(actual.count) audio tracks")
        } else {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(records(first)), as: UTF8.self))
        }
    }
}
