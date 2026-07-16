// CompositionBuilder.swift
// Builds a media composition from a parsed timeline descriptor.
// The timeline encoder consumes the resulting composition.

import Foundation
import AVFoundation
import CoreMedia

/// Structural failures that prevent a timeline composition from being assembled.
public enum CompositionBuilderError: Error {
    case noClips
    case trackInsertionFailed(String)
}

/// Separates composition lanes by media type and source timeline index.
private struct CompositionTrackKey: Hashable {
    let mediaType: AVMediaType
    let trackIndex: Int
}

/// Tracks one mutable composition track and its occupied time extent.
private struct CompositionLane {
    let track: AVMutableCompositionTrack
    var endTime: CMTime
    var inheritedVideoTransform: Bool
}

/// Inserts parsed clips into non-overlapping composition lanes.
public final class CompositionBuilder {

    /// Creates a stateless composition builder.
    public init() {}

    /// Build an AVMutableComposition from a parsed timeline descriptor.
    public func build(from descriptor: TimelineDescriptor) throws -> AVMutableComposition {
        guard !descriptor.clips.isEmpty else {
            throw CompositionBuilderError.noClips
        }

        let composition = AVMutableComposition()

        // Keep video/audio namespaces separate so A1 does not collide with V1.
        let grouped = Dictionary(grouping: descriptor.clips) {
            CompositionTrackKey(mediaType: $0.mediaType, trackIndex: $0.trackIndex)
        }
        let sortedKeys = grouped.keys.sorted { lhs, rhs in
            if lhs.mediaType != rhs.mediaType {
                return mediaSortOrder(lhs.mediaType) < mediaSortOrder(rhs.mediaType)
            }
            return lhs.trackIndex < rhs.trackIndex
        }

        for key in sortedKeys {
            guard let clipsForTrack = grouped[key] else { continue }

            let mediaType = key.mediaType
            var lanes: [CompositionLane] = []
            for clip in clipsForTrack.sorted(by: clipSortOrder) {
                let assetForClip = AVURLAsset(url: clip.sourceURL)

                // Select the source track matching the clip media type.
                guard let sourceTrack = loadTracksSynchronously(
                    from: assetForClip,
                    mediaType: mediaType
                ).first else {
                    print("[CompositionBuilder] Warning: no \(mediaType.rawValue) track in \(clip.sourceURL.lastPathComponent), skipping clip.")
                    continue
                }

                do {
                    let laneIndex = try laneIndexForInsertion(
                        clip: clip,
                        key: key,
                        mediaType: mediaType,
                        composition: composition,
                        lanes: &lanes)
                    if mediaType == .video, !lanes[laneIndex].inheritedVideoTransform {
                        lanes[laneIndex].track.preferredTransform = loadPreferredTransformSynchronously(
                            from: sourceTrack)
                        lanes[laneIndex].inheritedVideoTransform = true
                    }
                    try lanes[laneIndex].track.insertTimeRange(
                        clip.sourceRange,
                        of: sourceTrack,
                        at: clip.timelineRange.start)
                    lanes[laneIndex].endTime = maxTime(
                        lanes[laneIndex].endTime,
                        CMTimeAdd(clip.timelineRange.start, clip.timelineRange.duration))
                } catch {
                    print("[CompositionBuilder] Warning: insertTimeRange failed for \(clip.sourceURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        return composition
    }

    /// Convenience async variant that pre-loads asset tracks before insertion.
    public func buildAsync(from descriptor: TimelineDescriptor) async throws -> AVMutableComposition {
        guard !descriptor.clips.isEmpty else {
            throw CompositionBuilderError.noClips
        }

        let composition = AVMutableComposition()
        let grouped = Dictionary(grouping: descriptor.clips) {
            CompositionTrackKey(mediaType: $0.mediaType, trackIndex: $0.trackIndex)
        }
        let sortedKeys = grouped.keys.sorted { lhs, rhs in
            if lhs.mediaType != rhs.mediaType {
                return mediaSortOrder(lhs.mediaType) < mediaSortOrder(rhs.mediaType)
            }
            return lhs.trackIndex < rhs.trackIndex
        }

        for key in sortedKeys {
            guard let clipsForTrack = grouped[key] else { continue }
            let mediaType = key.mediaType
            var lanes: [CompositionLane] = []
            for clip in clipsForTrack.sorted(by: clipSortOrder) {
                let assetForClip = AVURLAsset(url: clip.sourceURL)

                // Load source tracks before insertion.
                let sourceTracks = try? await assetForClip.loadTracks(withMediaType: mediaType)
                guard let sourceTrack = sourceTracks?.first else {
                    print("[CompositionBuilder] Warning: no \(mediaType.rawValue) track in \(clip.sourceURL.lastPathComponent), skipping.")
                    continue
                }

                do {
                    let laneIndex = try laneIndexForInsertion(
                        clip: clip,
                        key: key,
                        mediaType: mediaType,
                        composition: composition,
                        lanes: &lanes)
                    if mediaType == .video, !lanes[laneIndex].inheritedVideoTransform {
                        lanes[laneIndex].track.preferredTransform =
                            (try? await sourceTrack.load(.preferredTransform)) ?? .identity
                        lanes[laneIndex].inheritedVideoTransform = true
                    }
                    try lanes[laneIndex].track.insertTimeRange(
                        clip.sourceRange,
                        of: sourceTrack,
                        at: clip.timelineRange.start)
                    lanes[laneIndex].endTime = maxTime(
                        lanes[laneIndex].endTime,
                        CMTimeAdd(clip.timelineRange.start, clip.timelineRange.duration))
                } catch {
                    print("[CompositionBuilder] Warning: \(error.localizedDescription)")
                }
            }
        }

        return composition
    }

    /// Reuses the first lane ending before the clip, or creates a new lane.
    private func laneIndexForInsertion(
        clip: ClipDescriptor,
        key: CompositionTrackKey,
        mediaType: AVMediaType,
        composition: AVMutableComposition,
        lanes: inout [CompositionLane]
    ) throws -> Int {
        let start = clip.timelineRange.start
        if let reusable = lanes.firstIndex(where: { CMTimeCompare($0.endTime, start) <= 0 }) {
            return reusable
        }

        guard let track = composition.addMutableTrack(
            withMediaType: mediaType,
            preferredTrackID: preferredTrackID(for: key, laneIndex: lanes.count)) else {
            throw CompositionBuilderError.trackInsertionFailed(
                "Could not add \(mediaType.rawValue) track \(key.trackIndex) lane \(lanes.count)")
        }
        lanes.append(CompositionLane(track: track, endTime: .zero, inheritedVideoTransform: false))
        return lanes.count - 1
    }

    /// Encodes media namespace, track index, and overlap lane into a stable track ID.
    private func preferredTrackID(for key: CompositionTrackKey, laneIndex: Int) -> CMPersistentTrackID {
        let base = key.mediaType == .video ? 1_000 : 2_000
        return CMPersistentTrackID(base + key.trackIndex * 100 + laneIndex + 1)
    }

    /// Returns the later of two media times.
    private func maxTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        CMTimeCompare(lhs, rhs) >= 0 ? lhs : rhs
    }

    /// Places video namespaces before audio and unknown media namespaces.
    private func mediaSortOrder(_ mediaType: AVMediaType) -> Int {
        switch mediaType {
        case .video: return 0
        case .audio: return 1
        default:     return 2
        }
    }

    /// Orders clips by start time, then source URL for deterministic insertion.
    private func clipSortOrder(_ lhs: ClipDescriptor, _ rhs: ClipDescriptor) -> Bool {
        let timeCompare = CMTimeCompare(lhs.timelineRange.start, rhs.timelineRange.start)
        if timeCompare != 0 {
            return timeCompare < 0
        }
        let durationCompare = CMTimeCompare(lhs.timelineRange.duration, rhs.timelineRange.duration)
        if durationCompare != 0 {
            return durationCompare < 0
        }
        return lhs.sourceURL.path < rhs.sourceURL.path
    }
}

/// Bridges asynchronous track loading for the synchronous build entry point.
private func loadTracksSynchronously(
    from asset: AVAsset,
    mediaType: AVMediaType
) -> [AVAssetTrack] {
    let semaphore = DispatchSemaphore(value: 0)
    let assetRef = SendableRef(asset)
    let box = SynchronousResultBox<[AVAssetTrack]>()
    Task {
        box.value = (try? await assetRef.value.loadTracks(withMediaType: mediaType)) ?? []
        semaphore.signal()
    }
    semaphore.wait()
    return box.value ?? []
}

/// Bridges asynchronous transform loading and falls back to identity.
private func loadPreferredTransformSynchronously(from track: AVAssetTrack) -> CGAffineTransform {
    let semaphore = DispatchSemaphore(value: 0)
    let trackRef = SendableRef(track)
    let box = SynchronousResultBox<CGAffineTransform>()
    Task {
        box.value = (try? await trackRef.value.load(.preferredTransform)) ?? .identity
        semaphore.signal()
    }
    semaphore.wait()
    return box.value ?? .identity
}

/// Transfers one asynchronously loaded value to a semaphore-waiting caller.
private final class SynchronousResultBox<T>: @unchecked Sendable {
    var value: T?
}
