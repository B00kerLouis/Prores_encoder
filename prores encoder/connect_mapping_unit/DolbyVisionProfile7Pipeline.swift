import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

private enum DolbyVisionProfile7Error {
    static func make(_ message: String, code: Int = 1) -> NSError {
        NSError(
            domain: "DolbyVisionProfile7",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private final class Profile7DecodeWaiter {
    let semaphore = DispatchSemaphore(value: 0)
    var status: OSStatus = noErr
    var pixelBuffer: CVPixelBuffer?
}

private final class Profile7ReconstructionDecoder {
    private var session: VTDecompressionSession?

    deinit {
        invalidate()
    }

    func decode(_ sampleBuffer: CMSampleBuffer) throws -> CVPixelBuffer {
        if session == nil {
            try createSession(for: sampleBuffer)
        }
        guard let session else {
            throw DolbyVisionProfile7Error.make("Profile 7 BL decoder is unavailable.")
        }

        let waiter = Profile7DecodeWaiter()
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: Unmanaged.passUnretained(waiter).toOpaque(),
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            throw DolbyVisionProfile7Error.make(
                "VideoToolbox BL reconstruction decode submission failed: \(status).",
                code: Int(status)
            )
        }
        if waiter.semaphore.wait(timeout: .now() + 5) == .timedOut {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            if waiter.semaphore.wait(timeout: .now() + 1) == .timedOut {
                throw DolbyVisionProfile7Error.make(
                    "Timed out waiting for the reconstructed Profile 7 base layer."
                )
            }
        }
        guard waiter.status == noErr, let pixelBuffer = waiter.pixelBuffer else {
            throw DolbyVisionProfile7Error.make(
                "VideoToolbox BL reconstruction decode failed: \(waiter.status).",
                code: Int(waiter.status)
            )
        }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) ==
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7 BL decoder did not return P010 video."
            )
        }
        return pixelBuffer
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    private func createSession(for sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw DolbyVisionProfile7Error.make(
                "The encoded Profile 7 base layer has no format description."
            )
        }
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { _, sourceFrameRefCon, status, _, imageBuffer, _, _ in
                guard let sourceFrameRefCon else { return }
                let waiter = Unmanaged<Profile7DecodeWaiter>
                    .fromOpaque(sourceFrameRefCon)
                    .takeUnretainedValue()
                waiter.status = status
                waiter.pixelBuffer = imageBuffer
                waiter.semaphore.signal()
            },
            decompressionOutputRefCon: nil
        )
        let decoderSpecification = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String:
                kCFBooleanTrue as Any,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String:
                kCFBooleanTrue as Any
        ] as CFDictionary
        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as Any,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ] as CFDictionary
        var createdSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &createdSession
        )
        guard status == noErr, let createdSession else {
            throw DolbyVisionProfile7Error.make(
                "Could not create the hardware BL reconstruction decoder: \(status).",
                code: Int(status)
            )
        }
        session = createdSession
    }
}

private final class Profile7MetalBundleToken {}

private final class Profile7MetalResidualGenerator {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let lumaPipeline: MTLComputePipelineState
    private let chromaPipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let pixelBufferPool: CVPixelBufferPool
    let width: Int
    let height: Int

    init(baseLayerWidth: Int, baseLayerHeight: Int) throws {
        guard baseLayerWidth > 0, baseLayerHeight > 0,
              baseLayerWidth.isMultiple(of: 4),
              baseLayerHeight.isMultiple(of: 4) else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7.6 requires BL dimensions divisible by 4; got " +
                "\(baseLayerWidth)x\(baseLayerHeight)."
            )
        }
        width = baseLayerWidth / 2
        height = baseLayerHeight / 2
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = Self.loadLibrary(device: device),
              let lumaFunction = library.makeFunction(name: "p7_make_luma_residual"),
              let chromaFunction = library.makeFunction(name: "p7_make_chroma_residual") else {
            throw DolbyVisionProfile7Error.make(
                "The Profile 7 Metal residual kernels are unavailable."
            )
        }
        self.device = device
        self.commandQueue = commandQueue
        lumaPipeline = try device.makeComputePipelineState(function: lumaFunction)
        chromaPipeline = try device.makeComputePipelineState(function: chromaFunction)

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw DolbyVisionProfile7Error.make(
                "Could not create the Profile 7 Metal texture cache: \(cacheStatus).",
                code: Int(cacheStatus)
            )
        }
        textureCache = cache

        let poolAttributes = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: NSNumber(value: 3)
        ] as CFDictionary
        let pixelAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as Any,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ] as CFDictionary
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes,
            pixelAttributes,
            &pool
        )
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw DolbyVisionProfile7Error.make(
                "Could not create the Profile 7 EL pixel-buffer pool: \(poolStatus).",
                code: Int(poolStatus)
            )
        }
        pixelBufferPool = pool
    }

    func makeEnhancementLayer(
        source: CVPixelBuffer,
        reconstructedBaseLayer: CVPixelBuffer
    ) throws -> CVPixelBuffer {
        let expectedWidth = width * 2
        let expectedHeight = height * 2
        for pixelBuffer in [source, reconstructedBaseLayer] {
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) ==
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                  CVPixelBufferGetWidth(pixelBuffer) == expectedWidth,
                  CVPixelBufferGetHeight(pixelBuffer) == expectedHeight else {
                throw DolbyVisionProfile7Error.make(
                    "Profile 7 Metal residual analysis requires matching \(expectedWidth)x" +
                    "\(expectedHeight) P010 source and reconstructed BL frames."
                )
            }
        }

        var outputPixelBuffer: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pixelBufferPool,
            &outputPixelBuffer
        )
        if status != kCVReturnSuccess || outputPixelBuffer == nil {
            CVPixelBufferPoolFlush(pixelBufferPool, .excessBuffers)
            status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pixelBufferPool,
                &outputPixelBuffer
            )
        }
        guard status == kCVReturnSuccess, let outputPixelBuffer else {
            throw DolbyVisionProfile7Error.make(
                "Could not allocate the Profile 7 enhancement-layer frame: \(status).",
                code: Int(status)
            )
        }
        CVBufferPropagateAttachments(source, outputPixelBuffer)

        var retainedTextures: [CVMetalTexture] = []
        let sourceY = try makeTexture(
            pixelBuffer: source, plane: 0, pixelFormat: .r16Unorm,
            width: expectedWidth, height: expectedHeight, retained: &retainedTextures
        )
        let reconstructedY = try makeTexture(
            pixelBuffer: reconstructedBaseLayer, plane: 0, pixelFormat: .r16Unorm,
            width: expectedWidth, height: expectedHeight, retained: &retainedTextures
        )
        let outputY = try makeTexture(
            pixelBuffer: outputPixelBuffer, plane: 0, pixelFormat: .r16Unorm,
            width: width, height: height, retained: &retainedTextures
        )
        let sourceUV = try makeTexture(
            pixelBuffer: source, plane: 1, pixelFormat: .rg16Unorm,
            width: expectedWidth / 2, height: expectedHeight / 2, retained: &retainedTextures
        )
        let reconstructedUV = try makeTexture(
            pixelBuffer: reconstructedBaseLayer, plane: 1, pixelFormat: .rg16Unorm,
            width: expectedWidth / 2, height: expectedHeight / 2, retained: &retainedTextures
        )
        let outputUV = try makeTexture(
            pixelBuffer: outputPixelBuffer, plane: 1, pixelFormat: .rg16Unorm,
            width: width / 2, height: height / 2, retained: &retainedTextures
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DolbyVisionProfile7Error.make(
                "Could not create the Profile 7 Metal command buffer."
            )
        }
        try encode(
            commandBuffer: commandBuffer,
            pipeline: lumaPipeline,
            source: sourceY,
            reconstructed: reconstructedY,
            output: outputY
        )
        try encode(
            commandBuffer: commandBuffer,
            pipeline: chromaPipeline,
            source: sourceUV,
            reconstructed: reconstructedUV,
            output: outputUV
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7 Metal residual analysis failed: " +
                "\(commandBuffer.error?.localizedDescription ?? "unknown Metal error")."
            )
        }
        _ = retainedTextures
        return outputPixelBuffer
    }

    private func encode(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLComputePipelineState,
        source: MTLTexture,
        reconstructed: MTLTexture,
        output: MTLTexture
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DolbyVisionProfile7Error.make(
                "Could not create the Profile 7 Metal compute encoder."
            )
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(reconstructed, index: 1)
        encoder.setTexture(output, index: 2)
        let threadWidth = min(16, pipeline.threadExecutionWidth)
        let threadHeight = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / threadWidth))
        let threads = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let groups = MTLSize(
            width: (output.width + threadWidth - 1) / threadWidth,
            height: (output.height + threadHeight - 1) / threadHeight,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        encoder.endEncoding()
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        plane: Int,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
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
            throw DolbyVisionProfile7Error.make(
                "Could not create a Profile 7 Metal plane texture: \(status).",
                code: Int(status)
            )
        }
        retained.append(cvTexture)
        return texture
    }

    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        EmbeddedMetalLibrary.load(
            device: device,
            bundle: Bundle(for: Profile7MetalBundleToken.self),
            requiredFunctions: [
                "p7_make_luma_residual",
                "p7_make_chroma_residual"
            ]
        )
    }
}

struct DolbyVisionProfile7EncodedFrame {
    let muxedSample: CMSampleBuffer
    let baseLayerSample: CMSampleBuffer
    let enhancementLayerSample: CMSampleBuffer
    let rpuNALUnit: Data
}

final class DolbyVisionProfile7Encoder: @unchecked Sendable {
    private let baseLayerEncoder: ProResSession
    private let enhancementLayerEncoder: ProResSession
    private let reconstructionDecoder = Profile7ReconstructionDecoder()
    private let residualGenerator: Profile7MetalResidualGenerator

    init(
        width: Int,
        height: Int,
        fpsHint: Int,
        colorSpace: SourceColorSpace?,
        bitrateMbps: Double
    ) throws {
        guard bitrateMbps > 0 else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7.6 requires a positive total HEVC bitrate."
            )
        }
        residualGenerator = try Profile7MetalResidualGenerator(
            baseLayerWidth: width,
            baseLayerHeight: height
        )
        let p7ColorSpace = SourceColorSpace.hevcHDR10(basedOn: colorSpace)

        let baseLayerOptions = HEVCEncodeOptions(
            bitrateMbps: bitrateMbps * 0.74,
            dvProfile: .profile76
        )

        let enhancementLayerOptions = HEVCEncodeOptions(
            bitrateMbps: bitrateMbps * 0.26,
            dvProfile: nil
        )

        baseLayerEncoder = try ProResSession(
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            fpsHint: fpsHint,
            colorSpace: p7ColorSpace,
            hevcOptions: baseLayerOptions
        )

        enhancementLayerEncoder = try ProResSession(
            width: residualGenerator.width,
            height: residualGenerator.height,
            codecType: kCMVideoCodecType_HEVC,
            fpsHint: fpsHint,
            colorSpace: p7ColorSpace,
            hevcOptions: enhancementLayerOptions
        )
    }

    func encode(
        sourcePixelBuffer: CVPixelBuffer,
        pts: CMTime,
        duration: CMTime,
        rpuNALUnit: Data,
        hdr10Metadata: HEVCHDR10Metadata?
    ) throws -> DolbyVisionProfile7EncodedFrame {
        guard let baseLayerSample = baseLayerEncoder.encode(
            pixelBuffer: sourcePixelBuffer,
            pts: pts,
            duration: duration
        ) else {
            throw DolbyVisionProfile7Error.make(
                "VideoToolbox failed to encode the Profile 7 base layer."
            )
        }
        let reconstructedBaseLayer = try reconstructionDecoder.decode(baseLayerSample)
        let enhancementPixelBuffer = try residualGenerator.makeEnhancementLayer(
            source: sourcePixelBuffer,
            reconstructedBaseLayer: reconstructedBaseLayer
        )
        guard let enhancementLayerSample = enhancementLayerEncoder.encode(
            pixelBuffer: enhancementPixelBuffer,
            pts: pts,
            duration: duration
        ) else {
            throw DolbyVisionProfile7Error.make(
                "VideoToolbox failed to encode the Profile 7 enhancement layer."
            )
        }
        let sample = try sampleBufferByMuxingDolbyVisionProfile7(
            baseLayerSample: baseLayerSample,
            enhancementLayerSample: enhancementLayerSample,
            rpuNALUnit: rpuNALUnit,
            hdr10Metadata: hdr10Metadata
        )
        guard sampleBufferContainsHEVCDolbyVisionEL(sample),
              sampleBufferContainsHEVCDolbyVisionRPU(sample) else {
            throw DolbyVisionProfile7Error.make(
                "The encoded Profile 7 sample is missing its EL or RPU NAL unit."
            )
        }
        return DolbyVisionProfile7EncodedFrame(
            muxedSample: sample,
            baseLayerSample: baseLayerSample,
            enhancementLayerSample: enhancementLayerSample,
            rpuNALUnit: rpuNALUnit
        )
    }

    func finish() {
        baseLayerEncoder.flush()
        enhancementLayerEncoder.flush()
    }

    func invalidate() {
        reconstructionDecoder.invalidate()
        baseLayerEncoder.invalidate()
        enhancementLayerEncoder.invalidate()
    }
}
