import AVFoundation

func compositionVideoTrackIndex(_ track: AVCompositionTrack) -> Int {
    let rawValue = Int(track.trackID)
    if rawValue >= 1001 {
        return rawValue - 1001
    }
    return rawValue
}

func compositionTrackIsActive(_ track: AVCompositionTrack, over timeRange: CMTimeRange) -> Bool {
    for segment in track.segments where !segment.isEmpty {
        let target = segment.timeMapping.target
        let intersection = CMTimeRangeGetIntersection(target, otherRange: timeRange)
        if intersection.duration > .zero {
            return true
        }
    }
    return false
}

func buildTimelineVideoComposition(
    composition: AVMutableComposition,
    descriptor: TimelineDescriptor
) -> AVMutableVideoComposition {
    let videoTracks = composition.tracks(withMediaType: .video)
    let videoComposition = AVMutableVideoComposition()
    videoComposition.frameDuration = descriptor.frameRate.value > 0
        && descriptor.frameRate.timescale > 0
        ? descriptor.frameRate
        : CMTime(value: 1, timescale: 24)
    videoComposition.renderSize = descriptor.resolution.width > 0
        && descriptor.resolution.height > 0
        ? descriptor.resolution
        : CGSize(width: 1920, height: 1080)

    guard !videoTracks.isEmpty else {
        videoComposition.instructions = []
        return videoComposition
    }

    var boundaries: [CMTime] = [.zero]
    for track in videoTracks {
        for segment in track.segments where !segment.isEmpty {
            boundaries.append(segment.timeMapping.target.start)
            boundaries.append(segment.timeMapping.target.end)
        }
    }

    let sortedBoundaries = boundaries.sorted { lhs, rhs in
        CMTimeCompare(lhs, rhs) < 0
    }.reduce(into: [CMTime]()) { partial, time in
        if let last = partial.last, CMTimeCompare(last, time) == 0 {
            return
        }
        partial.append(time)
    }

    var instructions: [AVVideoCompositionInstructionProtocol] = []
    if sortedBoundaries.count >= 2 {
        for idx in 0..<(sortedBoundaries.count - 1) {
            let start = sortedBoundaries[idx]
            let end = sortedBoundaries[idx + 1]
            guard CMTimeCompare(end, start) > 0 else { continue }

            let timeRange = CMTimeRange(start: start, end: end)
            let activeTracks = videoTracks
                .filter { compositionTrackIsActive($0, over: timeRange) }
                .sorted { lhs, rhs in
                    compositionVideoTrackIndex(lhs) > compositionVideoTrackIndex(rhs)
                }

            guard !activeTracks.isEmpty else { continue }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = timeRange
            instruction.enablePostProcessing = true
            instruction.layerInstructions = activeTracks.map { track in
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(track.preferredTransform, at: start)
                return layer
            }
            instructions.append(instruction)
        }
    }

    if instructions.isEmpty {
        let fallbackInstruction = AVMutableVideoCompositionInstruction()
        fallbackInstruction.timeRange = CMTimeRange(
            start: .zero,
            duration: composition.duration
        )
        let activeTracks = videoTracks.sorted { lhs, rhs in
            compositionVideoTrackIndex(lhs) > compositionVideoTrackIndex(rhs)
        }
        fallbackInstruction.layerInstructions = activeTracks.map { track in
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(track.preferredTransform, at: .zero)
            return layer
        }
        instructions = [fallbackInstruction]
    }

    videoComposition.instructions = instructions
    return videoComposition
}
