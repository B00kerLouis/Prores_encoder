import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Metal

private final class CMUMetalResourceBundleToken: NSObject {}

private struct CMUMetalUniforms {
    var width: UInt32
    var height: UInt32
    var matrixID: UInt32
    var fullRange: UInt32
    var lumaCoefficients: SIMD4<Float>
}

private struct CMUPartialStatsGPU {
    var sums0: SIMD4<Float>
    var sums1: SIMD4<Float>
}

private final class CMUStatsSlot {
    let histogram: MTLBuffer
    let extrema: MTLBuffer
    let partials: MTLBuffer

    init?(device: MTLDevice, groupCount: Int) {
        guard let histogram = device.makeBuffer(
            length: 4096 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ),
        let extrema = device.makeBuffer(
            length: 3 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ),
        let partials = device.makeBuffer(
            length: groupCount * MemoryLayout<CMUPartialStatsGPU>.stride,
            options: .storageModeShared
        ) else {
            return nil
        }
        self.histogram = histogram
        self.extrema = extrema
        self.partials = partials
    }

    func reset() {
        histogram.contents().initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: histogram.length
        )
        let extremaValues = extrema.contents().bindMemory(to: UInt32.self, capacity: 3)
        extremaValues[0] = 0
        extremaValues[1] = 0
        extremaValues[2] = 10_000_000
    }
}

private final class CMUPendingFrame {
    let commandBuffer: MTLCommandBuffer
    let slot: CMUStatsSlot
    let pixelBuffer: CVPixelBuffer
    let retainedTextures: [CVMetalTexture]
    let frameIndex: Int64
    let ptsSeconds: Double
    let groupCount: Int

    init(
        commandBuffer: MTLCommandBuffer,
        slot: CMUStatsSlot,
        pixelBuffer: CVPixelBuffer,
        retainedTextures: [CVMetalTexture],
        frameIndex: Int64,
        ptsSeconds: Double,
        groupCount: Int
    ) {
        self.commandBuffer = commandBuffer
        self.slot = slot
        self.pixelBuffer = pixelBuffer
        self.retainedTextures = retainedTextures
        self.frameIndex = frameIndex
        self.ptsSeconds = ptsSeconds
        self.groupCount = groupCount
    }

    func finish() throws -> CMUFrameStats {
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(pixelBuffer) {}
        withExtendedLifetime(retainedTextures) {}
        guard commandBuffer.status == .completed else {
            throw CMUError.commandExecutionFailed(
                commandBuffer.error?.localizedDescription
                    ?? "status \(commandBuffer.status.rawValue)"
            )
        }

        let extremaValues = slot.extrema.contents().bindMemory(
            to: UInt32.self,
            capacity: 3
        )
        let partialValues = slot.partials.contents().bindMemory(
            to: CMUPartialStatsGPU.self,
            capacity: groupCount
        )
        let histogramValues = slot.histogram.contents().bindMemory(
            to: UInt32.self,
            capacity: 4096
        )

        var lumaSum = Double.zero
        var redSum = Double.zero
        var greenSum = Double.zero
        var blueSum = Double.zero
        var saturationSum = Double.zero
        var sampleCount = Double.zero
        for index in 0..<groupCount {
            let partial = partialValues[index]
            lumaSum += Double(partial.sums0.x)
            redSum += Double(partial.sums0.y)
            greenSum += Double(partial.sums0.z)
            blueSum += Double(partial.sums0.w)
            saturationSum += Double(partial.sums1.x)
            sampleCount += Double(partial.sums1.y)
        }
        let divisor = max(sampleCount, 1)

        return CMUFrameStats(
            frameIndex: frameIndex,
            ptsSeconds: ptsSeconds,
            maxRGBNits: Float(extremaValues[0]) / 1000,
            maxLumaNits: Float(extremaValues[1]) / 1000,
            minLumaNits: Float(extremaValues[2]) / 1000,
            avgLumaNits: Float(lumaSum / divisor),
            percentile01: cmuPercentile(histogramValues, fraction: 0.001),
            percentile10: cmuPercentile(histogramValues, fraction: 0.10),
            percentile50: cmuPercentile(histogramValues, fraction: 0.50),
            percentile90: cmuPercentile(histogramValues, fraction: 0.90),
            percentile99: cmuPercentile(histogramValues, fraction: 0.99),
            percentile999: cmuPercentile(histogramValues, fraction: 0.999),
            avgR: Float(redSum / divisor),
            avgG: Float(greenSum / divisor),
            avgB: Float(blueSum / divisor),
            avgSaturation: Float(saturationSum / divisor)
        )
    }
}

final class CMUMetalAnalyzer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CMUError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw CMUError.commandQueueUnavailable
        }
        guard let library = Self.loadLibrary(device: device) else {
            throw CMUError.metalLibraryUnavailable
        }
        guard let function = library.makeFunction(name: "cmu_analyze_yuv") else {
            throw CMUError.metalFunctionUnavailable("cmu_analyze_yuv")
        }
        self.device = device
        self.commandQueue = commandQueue
        pipeline = try device.makeComputePipelineState(function: function)

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let cache else {
            throw CMUError.textureCreationFailed("texture cache", status)
        }
        textureCache = cache
    }

    func analyze(
        url: URL,
        descriptor: CMUAssetDescriptor,
        source: CMUAnalysisSource,
        masteringPeakNits: Float,
        timecode: CMUTimecodeReference,
        colorTransform: ResolvedColorTransform? = nil
    ) async throws -> CMUAnalysisDocument {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CMUError.noVideoTrack(url)
        }
        let colorPipeline = try colorTransform.map {
            try MetalColorPipeline(
                transform: $0,
                width: descriptor.width,
                height: descriptor.height,
                pixelFormat: descriptor.signalRange.pixelFormat
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(
                value: descriptor.signalRange.pixelFormat
            ),
            kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as Any,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CMUError.readerOutputUnavailable
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CMUError.readerStartFailed(
                reader.error?.localizedDescription ?? "unknown reader error"
            )
        }

        let threadgroupWidth = 16
        let threadgroupHeight = 16
        let groupsX = (descriptor.width + threadgroupWidth - 1) / threadgroupWidth
        let groupsY = (descriptor.height + threadgroupHeight - 1) / threadgroupHeight
        let groupCount = groupsX * groupsY
        let slots = try (0..<3).map { _ -> CMUStatsSlot in
            guard let slot = CMUStatsSlot(device: device, groupCount: groupCount) else {
                throw CMUError.bufferAllocationFailed
            }
            return slot
        }

        var availableSlots = slots
        var pending: [CMUPendingFrame] = []
        var frameStats: [CMUFrameStats] = []
        frameStats.reserveCapacity(Int(max(await estimateFrameCount(asset: asset), 0)))
        var decodedFrameIndex: Int64 = 0
        var firstPTS: CMTime?
        var lastEndPTS: CMTime?

        while true {
            if availableSlots.isEmpty {
                let completed = pending.removeFirst()
                frameStats.append(try completed.finish())
                availableSlots.append(completed.slot)
            }

            let sample: CMSampleBuffer? = autoreleasepool {
                output.copyNextSampleBuffer()
            }
            guard let sample else { break }
            guard let decodedPixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let pixelBuffer = try colorPipeline?.process(
                decodedPixelBuffer,
                pts: pts
            ) ?? decodedPixelBuffer
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            guard pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                  CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
                throw CMUError.unsupportedPixelBuffer(pixelFormat)
            }

            let duration = CMSampleBufferGetDuration(sample)
            if firstPTS == nil { firstPTS = pts }
            let endPTS: CMTime
            if duration.isNumeric && duration > .zero {
                endPTS = CMTimeAdd(pts, duration)
            } else {
                endPTS = CMTimeAdd(
                    pts,
                    CMTime(
                        value: CMTimeValue(descriptor.editRate.denominator),
                        timescale: CMTimeScale(descriptor.editRate.numerator)
                    )
                )
            }
            if lastEndPTS == nil || CMTimeCompare(endPTS, lastEndPTS!) > 0 {
                lastEndPTS = endPTS
            }

            let slot = availableSlots.removeLast()
            slot.reset()
            pending.append(
                try submit(
                    pixelBuffer: pixelBuffer,
                    slot: slot,
                    descriptor: descriptor,
                    frameIndex: timecode.startFrame + decodedFrameIndex,
                    ptsSeconds: pts.isNumeric ? pts.seconds : Double(decodedFrameIndex) / descriptor.editRate.fps,
                    groupsX: groupsX,
                    groupsY: groupsY,
                    groupCount: groupCount
                )
            )
            decodedFrameIndex += 1
        }

        for completed in pending {
            frameStats.append(try completed.finish())
        }

        guard reader.status == .completed else {
            throw CMUError.readerFailed(
                reader.error?.localizedDescription ?? "status \(reader.status.rawValue)"
            )
        }
        guard !frameStats.isEmpty else {
            throw CMUError.noDecodedFrames
        }

        let exactDuration: Double
        if let firstPTS, let lastEndPTS {
            exactDuration = max(CMTimeSubtract(lastEndPTS, firstPTS).seconds, 0)
        } else {
            exactDuration = Double(frameStats.count) / descriptor.editRate.fps
        }
        let level1 = cmuBuildLevel1(frameStats)
        let maxCLL = Int((frameStats.map(\.maxRGBNits).max() ?? 0).rounded())
        let maxFALL = Int((frameStats.map(\.avgLumaNits).max() ?? 0).rounded())
        let frameCount = Int64(frameStats.count)

        return CMUAnalysisDocument(
            schemaVersion: "5.1.0",
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            author: "Dolby Laboratories",
            software: "Connect Mapping Unit",
            softwareVersion: "1.2.0",
            analysisSource: source,
            media: descriptor,
            masteringPeakNits: masteringPeakNits,
            timecode: timecode,
            durationFrames: frameCount,
            durationSeconds: exactDuration,
            recordIn: timecode.startFrame,
            recordOut: timecode.startFrame + frameCount - 1,
            maxCLL: max(maxCLL, maxFALL),
            maxFALL: maxFALL,
            level1Like: level1,
            outputID: UUID(),
            trackID: UUID(),
            shotID: UUID(),
            frames: frameStats
        )
    }

    private func submit(
        pixelBuffer: CVPixelBuffer,
        slot: CMUStatsSlot,
        descriptor: CMUAssetDescriptor,
        frameIndex: Int64,
        ptsSeconds: Double,
        groupsX: Int,
        groupsY: Int,
        groupCount: Int
    ) throws -> CMUPendingFrame {
        var retainedTextures: [CVMetalTexture] = []
        let yTexture = try makeTexture(
            pixelBuffer: pixelBuffer,
            plane: 0,
            pixelFormat: .r16Unorm,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            label: "CMU luma",
            retained: &retainedTextures
        )
        let uvTexture = try makeTexture(
            pixelBuffer: pixelBuffer,
            plane: 1,
            pixelFormat: .rg16Unorm,
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            label: "CMU chroma",
            retained: &retainedTextures
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw CMUError.commandEncodingFailed
        }
        commandBuffer.label = "CMU Metal HDR frame \(frameIndex)"
        encoder.label = "CMU PQ statistics"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(yTexture, index: 0)
        encoder.setTexture(uvTexture, index: 1)
        encoder.setBuffer(slot.histogram, offset: 0, index: 0)
        encoder.setBuffer(slot.extrema, offset: 0, index: 1)
        encoder.setBuffer(slot.partials, offset: 0, index: 2)

        var uniforms = CMUMetalUniforms(
            width: UInt32(descriptor.width),
            height: UInt32(descriptor.height),
            matrixID: descriptor.matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String) ? 0 : 1,
            fullRange: descriptor.signalRange == .full ? 1 : 0,
            lumaCoefficients: descriptor.primaries.gamut.lumaCoefficients
        )
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CMUMetalUniforms>.stride,
            index: 3
        )
        encoder.dispatchThreadgroups(
            MTLSize(width: groupsX, height: groupsY, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()

        return CMUPendingFrame(
            commandBuffer: commandBuffer,
            slot: slot,
            pixelBuffer: pixelBuffer,
            retainedTextures: retainedTextures,
            frameIndex: frameIndex,
            ptsSeconds: ptsSeconds,
            groupCount: groupCount
        )
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        plane: Int,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        label: String,
        retained: inout [CVMetalTexture]
    ) throws -> MTLTexture {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw CMUError.textureCreationFailed(label, status)
        }
        texture.label = label
        retained.append(cvTexture)
        return texture
    }

    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        EmbeddedMetalLibrary.load(
            device: device,
            bundle: Bundle(for: CMUMetalResourceBundleToken.self),
            requiredFunctions: ["cmu_analyze_yuv"]
        )
    }
}

private func cmuPercentile(
    _ histogram: UnsafeMutablePointer<UInt32>,
    fraction: Double
) -> Float {
    var total: UInt64 = 0
    for index in 0..<4096 {
        total += UInt64(histogram[index])
    }
    guard total > 0 else { return 0 }
    let target = max(UInt64(ceil(Double(total) * fraction)), 1)
    var cumulative: UInt64 = 0
    for index in 0..<4096 {
        cumulative += UInt64(histogram[index])
        if cumulative >= target {
            let normalized = Double(index) / 4095
            return Float(pow(2, normalized * log2(10001)) - 1)
        }
    }
    return 10_000
}

private func cmuBuildLevel1(_ frames: [CMUFrameStats]) -> CMULevel1Like {
    let minimum = min(
        min(max(cmuNitsToPQNormalized(frames.map(\.minLumaNits).min() ?? 0), 0), 1),
        12.0 / 4095.0
    )
    let maximum = max(
        min(max(cmuNitsToPQNormalized(frames.map(\.percentile999).max() ?? 0), 0), 1),
        2081.0 / 4095.0
    )
    let middle = min(
        max(
            min(max(cmuNitsToPQNormalized(cmuMedian(frames.map(\.percentile50))), 0), 1),
            1229.0 / 4095.0
        ),
        maximum - (1.0 / 4095.0)
    )
    return CMULevel1Like(
        min: minimum,
        mid: middle,
        max: maximum
    )
}

private func cmuNitsToPQNormalized(_ nits: Float) -> Float {
    let m1 = 2610.0 / 16384.0
    let m2 = 2523.0 / 32.0
    let c1 = 3424.0 / 4096.0
    let c2 = 2413.0 / 128.0
    let c3 = 2392.0 / 128.0
    let normalized = max(0, min(Double(nits) / 10_000.0, 1))
    let powered = pow(normalized, m1)
    return Float(pow((c1 + c2 * powered) / (1 + c3 * powered), m2))
}

private func cmuMedian(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}
