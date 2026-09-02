// Produces Profile 7 base and enhancement layers, reconstructs the base layer,
// generates residual pixels on the GPU, and combines both layers with metadata.

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// Creates errors in the Profile 7 pipeline's diagnostic domain.
private enum DolbyVisionProfile7Error {
    /// Wraps a localized failure message and numeric status.
    static func make(_ message: String, code: Int = 1) -> NSError {
        NSError(
            domain: "DolbyVisionProfile7",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// Pixel offsets describing the visible image inside a Profile 7 canvas.
struct DolbyVisionProfile7ActiveArea: Sendable, Equatable {
    let left: Int
    let right: Int
    let top: Int
    let bottom: Int
}

/// Keeps Profile 7 pixel padding and Level 5 metadata on one shared geometry plan.
struct DolbyVisionProfile7RasterPlan: Sendable {
    let sourceWidth: Int
    let sourceHeight: Int
    let encodedWidth: Int
    let encodedHeight: Int
    let defaultActiveArea: DolbyVisionProfile7ActiveArea

    /// Places the source in the UHD Profile 7.6 canvas without scaling. This
    /// implementation emits the level-6 half-resolution 1920x1080 EL; accepting
    /// an HD canvas would incorrectly produce a forbidden 960x540 EL.
    init(sourceWidth: Int, sourceHeight: Int) throws {
        guard sourceWidth > 0, sourceHeight > 0,
              sourceWidth.isMultiple(of: 2), sourceHeight.isMultiple(of: 2) else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7.6 requires positive, even source dimensions; got " +
                "\(sourceWidth)x\(sourceHeight)."
            )
        }

        let canvas = (3840, 2160)
        guard sourceWidth <= canvas.0, sourceHeight <= canvas.1,
              sourceWidth == canvas.0 || sourceHeight == canvas.1 else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7.6 source \(sourceWidth)x\(sourceHeight) cannot be padded " +
                "without scaling to the required 3840x2160 level-6 canvas."
            )
        }

        let horizontalDifference = canvas.0 - sourceWidth
        let verticalDifference = canvas.1 - sourceHeight
        let left = horizontalDifference / 2
        let right = horizontalDifference - left
        let top = verticalDifference / 2
        let bottom = verticalDifference - top
        guard left.isMultiple(of: 2), top.isMultiple(of: 2) else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7.6 padding must start on a 4:2:0 chroma sample; computed " +
                "left/top offsets are \(left)/\(top)."
            )
        }

        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        encodedWidth = canvas.0
        encodedHeight = canvas.1
        defaultActiveArea = DolbyVisionProfile7ActiveArea(
            left: left,
            right: right,
            top: top,
            bottom: bottom
        )
    }

    /// Calculates Level 5 active-area offsets from the actual encoded canvas.
    func activeArea(imageAspectRatio: Double) throws -> DolbyVisionProfile7ActiveArea {
        guard imageAspectRatio.isFinite, imageAspectRatio > 0 else {
            throw DolbyVisionProfile7Error.make(
                "Dolby Vision Level 5 image aspect ratio must be finite and positive."
            )
        }
        let canvasAspectRatio = Double(encodedWidth) / Double(encodedHeight)
        if abs(canvasAspectRatio - imageAspectRatio) < 1.0e-9 {
            return DolbyVisionProfile7ActiveArea(left: 0, right: 0, top: 0, bottom: 0)
        }

        let area: DolbyVisionProfile7ActiveArea
        if imageAspectRatio > canvasAspectRatio {
            let imageHeight = Int((Double(encodedWidth) / imageAspectRatio).rounded())
            guard imageHeight > 0, imageHeight <= encodedHeight else {
                throw DolbyVisionProfile7Error.make(
                    "Dolby Vision Level 5 image aspect ratio \(imageAspectRatio) " +
                    "does not fit \(encodedWidth)x\(encodedHeight)."
                )
            }
            let difference = encodedHeight - imageHeight
            let top = difference / 2
            area = DolbyVisionProfile7ActiveArea(
                left: 0,
                right: 0,
                top: top,
                bottom: difference - top
            )
        } else {
            let imageWidth = Int((Double(encodedHeight) * imageAspectRatio).rounded())
            guard imageWidth > 0, imageWidth <= encodedWidth else {
                throw DolbyVisionProfile7Error.make(
                    "Dolby Vision Level 5 image aspect ratio \(imageAspectRatio) " +
                    "does not fit \(encodedWidth)x\(encodedHeight)."
                )
            }
            let difference = encodedWidth - imageWidth
            let left = difference / 2
            area = DolbyVisionProfile7ActiveArea(
                left: left,
                right: difference - left,
                top: 0,
                bottom: 0
            )
        }
        guard [area.left, area.right, area.top, area.bottom].allSatisfy({ $0 <= 8191 }) else {
            throw DolbyVisionProfile7Error.make(
                "Dolby Vision Level 5 offsets exceed their 13-bit representation."
            )
        }
        return area
    }
}

/// CPU-side layout mirrored by the Profile 7 Metal preparation kernels.
private struct Profile7RasterUniforms {
    var sourceWidth: UInt32
    var sourceHeight: UInt32
    var canvasWidth: UInt32
    var canvasHeight: UInt32
    var leftOffset: UInt32
    var topOffset: UInt32
    var reserved0: UInt32 = 0
    var reserved1: UInt32 = 0
}

/// Receives one asynchronous reconstruction result.
private final class Profile7DecodeWaiter {
    let semaphore = DispatchSemaphore(value: 0)
    var status: OSStatus = noErr
    var pixelBuffer: CVPixelBuffer?
}

/// Decodes encoded base-layer samples to the pixels used for residual generation.
private final class Profile7ReconstructionDecoder {
    private var session: VTDecompressionSession?

    /// Releases the active reconstruction session.
    deinit {
        invalidate()
    }

    /// Decodes one base-layer sample and returns its reconstructed pixel buffer.
    func decode(_ sampleBuffer: CMSampleBuffer) throws -> CVPixelBuffer {
        if session == nil {
            try createSession(for: sampleBuffer)
        }
        guard let session else {
            throw DolbyVisionProfile7Error.make("Profile 7 BL decoder is unavailable.")
        }

        let waiter = Profile7DecodeWaiter()
        // The decoder owns this reference until it invokes the callback. A
        // timeout must not leave an unretained frameRefcon that can later
        // dereference a deallocated waiter.
        let waiterReference = Unmanaged.passRetained(waiter)
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: waiterReference.toOpaque(),
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            waiterReference.release()
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

    /// Invalidates and clears the current decompression session.
    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    /// Creates a session from the first sample's video format description.
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
                    .takeRetainedValue()
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

/// Supplies the module bundle used while locating packaged GPU functions.
private final class Profile7MetalBundleToken {}

/// Prepares the 10-bit BL and projects a 12-bit composer-domain residual into
/// the half-resolution 10-bit enhancement layer.
private final class Profile7MetalResidualGenerator {
    private struct ProjectionScratch {
        let target: MTLTexture
        let horizontal: MTLTexture
        let halfResolution: MTLTexture
        let verticalUpsample: MTLTexture
        let fullUpsample: MTLTexture
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]
    private let textureCache: CVMetalTextureCache
    private let baseLayerPool: CVPixelBufferPool
    private let enhancementLayerPool: CVPixelBufferPool
    private let rasterPlan: DolbyVisionProfile7RasterPlan
    private let rasterUniforms: Profile7RasterUniforms
    private let lumaScratch: ProjectionScratch
    private let chromaScratch: ProjectionScratch
    let width: Int
    let height: Int

    private static let functionNames = [
        "p7_prepare_bl_luma",
        "p7_prepare_bl_chroma",
        "p7_make_target_luma",
        "p7_make_target_chroma",
        "p7_adjoint_horizontal_luma",
        "p7_adjoint_horizontal_chroma",
        "p7_adjoint_vertical_luma",
        "p7_adjoint_vertical_chroma",
        "p7_upsample_vertical_luma",
        "p7_upsample_vertical_chroma",
        "p7_upsample_horizontal_luma",
        "p7_upsample_horizontal_chroma",
        "p7_subtract_projection_luma",
        "p7_subtract_projection_chroma",
        "p7_finalize_luma",
        "p7_finalize_chroma"
    ]

    /// Creates the composer-matched projection resources and reusable output pools.
    init(rasterPlan: DolbyVisionProfile7RasterPlan) throws {
        guard rasterPlan.encodedWidth.isMultiple(of: 4),
              rasterPlan.encodedHeight.isMultiple(of: 4) else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7.6 encoded dimensions must be divisible by 4; got " +
                "\(rasterPlan.encodedWidth)x\(rasterPlan.encodedHeight)."
            )
        }
        self.rasterPlan = rasterPlan
        width = rasterPlan.encodedWidth / 2
        height = rasterPlan.encodedHeight / 2
        rasterUniforms = Profile7RasterUniforms(
            sourceWidth: UInt32(rasterPlan.sourceWidth),
            sourceHeight: UInt32(rasterPlan.sourceHeight),
            canvasWidth: UInt32(rasterPlan.encodedWidth),
            canvasHeight: UInt32(rasterPlan.encodedHeight),
            leftOffset: UInt32(rasterPlan.defaultActiveArea.left),
            topOffset: UInt32(rasterPlan.defaultActiveArea.top)
        )

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = Self.loadLibrary(device: device) else {
            throw DolbyVisionProfile7Error.make(
                "The Profile 7 Metal residual kernels are unavailable."
            )
        }
        self.device = device
        self.commandQueue = commandQueue
        var createdPipelines: [String: MTLComputePipelineState] = [:]
        for name in Self.functionNames {
            guard let function = library.makeFunction(name: name) else {
                throw DolbyVisionProfile7Error.make(
                    "The Profile 7 Metal function \(name) is unavailable."
                )
            }
            createdPipelines[name] = try device.makeComputePipelineState(function: function)
        }
        pipelines = createdPipelines

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

        baseLayerPool = try Self.makePixelBufferPool(
            width: rasterPlan.encodedWidth,
            height: rasterPlan.encodedHeight
        )
        enhancementLayerPool = try Self.makePixelBufferPool(width: width, height: height)

        lumaScratch = try Self.makeProjectionScratch(
            device: device,
            componentFormat: .r32Float,
            fullWidth: rasterPlan.encodedWidth,
            fullHeight: rasterPlan.encodedHeight
        )
        chromaScratch = try Self.makeProjectionScratch(
            device: device,
            componentFormat: .rg32Float,
            fullWidth: rasterPlan.encodedWidth / 2,
            fullHeight: rasterPlan.encodedHeight / 2
        )
    }

    /// Quantizes and pads the high-precision 4:2:2 source into the HDR10 BL canvas.
    func makeBaseLayerInput(source: CVPixelBuffer) throws -> CVPixelBuffer {
        try validateSource(source)
        let output = try allocatePixelBuffer(from: baseLayerPool, propagating: source)
        var retainedTextures: [CVMetalTexture] = []
        let sourceY = try makeTexture(
            pixelBuffer: source,
            plane: 0,
            pixelFormat: .r16Unorm,
            width: rasterPlan.sourceWidth,
            height: rasterPlan.sourceHeight,
            retained: &retainedTextures
        )
        let sourceUV = try makeTexture(
            pixelBuffer: source,
            plane: 1,
            pixelFormat: .rg16Unorm,
            width: rasterPlan.sourceWidth / 2,
            height: rasterPlan.sourceHeight,
            retained: &retainedTextures
        )
        let outputY = try makeTexture(
            pixelBuffer: output,
            plane: 0,
            pixelFormat: .r16Unorm,
            width: rasterPlan.encodedWidth,
            height: rasterPlan.encodedHeight,
            retained: &retainedTextures
        )
        let outputUV = try makeTexture(
            pixelBuffer: output,
            plane: 1,
            pixelFormat: .rg16Unorm,
            width: rasterPlan.encodedWidth / 2,
            height: rasterPlan.encodedHeight / 2,
            retained: &retainedTextures
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DolbyVisionProfile7Error.make(
                "Could not create the Profile 7 BL preparation command buffer."
            )
        }
        var uniforms = rasterUniforms
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_prepare_bl_luma",
            textures: [sourceY, outputY],
            output: outputY,
            bytes: &uniforms
        )
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_prepare_bl_chroma",
            textures: [sourceUV, outputUV],
            output: outputUV,
            bytes: &uniforms
        )
        try complete(commandBuffer, stage: "base-layer preparation")
        _ = retainedTextures
        return output
    }

    /// Computes full-resolution forward-NLQ targets and projects them into a
    /// half-resolution P010 enhancement frame.
    func makeEnhancementLayer(
        source: CVPixelBuffer,
        reconstructedBaseLayer: CVPixelBuffer
    ) throws -> CVPixelBuffer {
        try validateSource(source)
        guard CVPixelBufferGetPixelFormatType(reconstructedBaseLayer) ==
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetWidth(reconstructedBaseLayer) == rasterPlan.encodedWidth,
              CVPixelBufferGetHeight(reconstructedBaseLayer) == rasterPlan.encodedHeight else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7 residual analysis requires reconstructed \(rasterPlan.encodedWidth)x" +
                "\(rasterPlan.encodedHeight) P010 BL frames."
            )
        }

        let outputPixelBuffer = try allocatePixelBuffer(
            from: enhancementLayerPool,
            propagating: source
        )

        var retainedTextures: [CVMetalTexture] = []
        let sourceY = try makeTexture(
            pixelBuffer: source,
            plane: 0,
            pixelFormat: .r16Unorm,
            width: rasterPlan.sourceWidth,
            height: rasterPlan.sourceHeight,
            retained: &retainedTextures
        )
        let reconstructedY = try makeTexture(
            pixelBuffer: reconstructedBaseLayer,
            plane: 0,
            pixelFormat: .r16Unorm,
            width: rasterPlan.encodedWidth,
            height: rasterPlan.encodedHeight,
            retained: &retainedTextures
        )
        let outputY = try makeTexture(
            pixelBuffer: outputPixelBuffer,
            plane: 0,
            pixelFormat: .r16Unorm,
            width: width,
            height: height,
            retained: &retainedTextures
        )
        let sourceUV = try makeTexture(
            pixelBuffer: source,
            plane: 1,
            pixelFormat: .rg16Unorm,
            width: rasterPlan.sourceWidth / 2,
            height: rasterPlan.sourceHeight,
            retained: &retainedTextures
        )
        let reconstructedUV = try makeTexture(
            pixelBuffer: reconstructedBaseLayer,
            plane: 1,
            pixelFormat: .rg16Unorm,
            width: rasterPlan.encodedWidth / 2,
            height: rasterPlan.encodedHeight / 2,
            retained: &retainedTextures
        )
        let outputUV = try makeTexture(
            pixelBuffer: outputPixelBuffer,
            plane: 1,
            pixelFormat: .rg16Unorm,
            width: width / 2,
            height: height / 2,
            retained: &retainedTextures
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DolbyVisionProfile7Error.make(
                "Could not create the Profile 7 Metal command buffer."
            )
        }
        var uniforms = rasterUniforms
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_make_target_luma",
            textures: [sourceY, reconstructedY, lumaScratch.target],
            output: lumaScratch.target,
            bytes: &uniforms
        )
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_make_target_chroma",
            textures: [sourceUV, reconstructedUV, chromaScratch.target],
            output: chromaScratch.target,
            bytes: &uniforms
        )
        try encodeProjection(
            commandBuffer: commandBuffer,
            scratch: lumaScratch,
            output: outputY,
            suffix: "luma"
        )
        try encodeProjection(
            commandBuffer: commandBuffer,
            scratch: chromaScratch,
            output: outputUV,
            suffix: "chroma"
        )
        try complete(commandBuffer, stage: "composer-domain residual projection")
        _ = retainedTextures
        return outputPixelBuffer
    }

    /// Encodes a normalized adjoint projection followed by one residual
    /// back-projection. Constants are exact for DC because each axis divides
    /// the upsampler adjoint by its factor-of-two sample expansion.
    private func encodeProjection(
        commandBuffer: MTLCommandBuffer,
        scratch: ProjectionScratch,
        output: MTLTexture,
        suffix: String
    ) throws {
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_adjoint_horizontal_\(suffix)",
            textures: [scratch.target, scratch.horizontal],
            output: scratch.horizontal
        )
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_adjoint_vertical_\(suffix)",
            textures: [scratch.horizontal, scratch.halfResolution],
            output: scratch.halfResolution
        )
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_upsample_vertical_\(suffix)",
            textures: [scratch.halfResolution, scratch.verticalUpsample],
            output: scratch.verticalUpsample
        )
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_upsample_horizontal_\(suffix)",
            textures: [scratch.verticalUpsample, scratch.fullUpsample],
            output: scratch.fullUpsample
        )
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_subtract_projection_\(suffix)",
            textures: [scratch.target, scratch.fullUpsample],
            output: scratch.target
        )
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_adjoint_horizontal_\(suffix)",
            textures: [scratch.target, scratch.horizontal],
            output: scratch.horizontal
        )
        try encode(
            commandBuffer: commandBuffer,
            function: "p7_finalize_\(suffix)",
            textures: [scratch.horizontal, scratch.halfResolution, output],
            output: output
        )
    }

    /// Encodes one compute pass with optional CPU-mirrored uniforms.
    private func encode(
        commandBuffer: MTLCommandBuffer,
        function: String,
        textures: [MTLTexture],
        output: MTLTexture,
        bytes: UnsafeMutableRawPointer? = nil,
        byteCount: Int = 0
    ) throws {
        guard let pipeline = pipelines[function] else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7 Metal pipeline \(function) was not initialized."
            )
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DolbyVisionProfile7Error.make(
                "Could not create the Profile 7 Metal compute encoder."
            )
        }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        if let bytes, byteCount > 0 {
            encoder.setBytes(bytes, length: byteCount, index: 0)
        }
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

    /// Type-safe wrapper that binds one value as Metal buffer zero.
    private func encode<T>(
        commandBuffer: MTLCommandBuffer,
        function: String,
        textures: [MTLTexture],
        output: MTLTexture,
        bytes value: inout T
    ) throws {
        try withUnsafeMutableBytes(of: &value) { rawBuffer in
            try encode(
                commandBuffer: commandBuffer,
                function: function,
                textures: textures,
                output: output,
                bytes: rawBuffer.baseAddress,
                byteCount: rawBuffer.count
            )
        }
    }

    /// Commits a synchronous Profile 7 GPU stage and surfaces command errors.
    private func complete(_ commandBuffer: MTLCommandBuffer, stage: String) throws {
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7 \(stage) failed: " +
                "\(commandBuffer.error?.localizedDescription ?? "unknown Metal error")."
            )
        }
    }

    /// Enforces the precision-preserving source format used only by Profile 7.
    private func validateSource(_ source: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(source) ==
                kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
              CVPixelBufferGetWidth(source) == rasterPlan.sourceWidth,
              CVPixelBufferGetHeight(source) == rasterPlan.sourceHeight else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7 source analysis requires \(rasterPlan.sourceWidth)x" +
                "\(rasterPlan.sourceHeight) 16-bit bi-planar 4:2:2 video."
            )
        }
    }

    /// Allocates one pooled P010 frame and carries source color attachments.
    private func allocatePixelBuffer(
        from pool: CVPixelBufferPool,
        propagating source: CVPixelBuffer
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        if status != kCVReturnSuccess || pixelBuffer == nil {
            CVPixelBufferPoolFlush(pool, .excessBuffers)
            status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &pixelBuffer
            )
        }
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw DolbyVisionProfile7Error.make(
                "Could not allocate a Profile 7 pixel buffer: \(status).",
                code: Int(status)
            )
        }
        CVBufferPropagateAttachments(source, pixelBuffer)
        return pixelBuffer
    }

    /// Binds a pixel-buffer plane to a Metal texture and retains the backing wrapper.
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

    /// Creates one reusable Metal-compatible P010 pool.
    private static func makePixelBufferPool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let poolAttributes = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: NSNumber(value: 16)
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
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes,
            pixelAttributes,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw DolbyVisionProfile7Error.make(
                "Could not create a Profile 7 P010 pool: \(status).",
                code: Int(status)
            )
        }
        return pool
    }

    /// Allocates the five private textures used by one separable projection.
    private static func makeProjectionScratch(
        device: MTLDevice,
        componentFormat: MTLPixelFormat,
        fullWidth: Int,
        fullHeight: Int
    ) throws -> ProjectionScratch {
        func make(_ width: Int, _ height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: componentFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DolbyVisionProfile7Error.make(
                    "Could not allocate Profile 7 projection texture \(width)x\(height)."
                )
            }
            return texture
        }

        return try ProjectionScratch(
            target: make(fullWidth, fullHeight),
            horizontal: make(fullWidth / 2, fullHeight),
            halfResolution: make(fullWidth / 2, fullHeight / 2),
            verticalUpsample: make(fullWidth / 2, fullHeight),
            fullUpsample: make(fullWidth, fullHeight)
        )
    }

    /// Loads the residual function from embedded or packaged GPU code.
    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        EmbeddedMetalLibrary.load(
            device: device,
            bundle: Bundle(for: Profile7MetalBundleToken.self),
            requiredFunctions: functionNames
        )
    }
}

/// Carries the muxed sample and its independently encoded layer components.
struct DolbyVisionProfile7EncodedFrame {
    let muxedSample: CMSampleBuffer
    let baseLayerSample: CMSampleBuffer
    let enhancementLayerSample: CMSampleBuffer
    let rpuNALUnit: Data
}

/// Coordinates base encode, reconstruction, residual generation, enhancement encode,
/// metadata generation, and final sample assembly.
final class DolbyVisionProfile7Encoder: @unchecked Sendable {
    private let baseLayerEncoder: ProResSession
    private let enhancementLayerEncoder: ProResSession
    private let reconstructionDecoder = Profile7ReconstructionDecoder()
    private let residualGenerator: Profile7MetalResidualGenerator
    private let fpsInfo: FramerateInfo
    private let baseLayerBitrateBitsPerSecond: Int
    private let enhancementLayerBitrateBitsPerSecond: Int
    private var accessUnitFrameIndex: UInt64 = 0
    private var framesSinceBufferingPeriod: UInt64 = 0
    private var muxedFormatDescription: CMFormatDescription?
    private let bFrames: Bool
    private var pendingSources: [Int64: Profile7PendingSource] = [:]
    private var pendingBaseLayers: [Int64: CMSampleBuffer] = [:]
    private var pendingResiduals: [Int64: CVPixelBuffer] = [:]
    private var nextELSubmitIndex: Int64?
    private var completedAfterPassEnd: [DolbyVisionProfile7EncodedFrame] = []

    private struct Profile7PendingSource {
        let pixelBuffer: CVPixelBuffer
        let rpuNALUnit: Data
        let hdr10Metadata: HEVCHDR10Metadata?
        let pts: CMTime
        let duration: CMTime
    }

    /// Configures both layer encoders and the reconstruction/residual stages.
    init(
        rasterPlan: DolbyVisionProfile7RasterPlan,
        fpsInfo: FramerateInfo,
        colorSpace: SourceColorSpace?,
        bitrateMbps: Double,
        allIntra: Bool = false,
        bFrames: Bool? = nil,
        bitrateMode: VideoBitrateMode = .vbr,
        multiPass: Bool? = nil,
        sourceFrameCount: Int = 0,
        sourceTimeRange: CMTimeRange = .invalid
    ) throws {
        guard bitrateMbps > 0 else {
            throw DolbyVisionProfile7Error.make(
                "Profile 7.6 requires a positive total HEVC bitrate."
            )
        }
        self.fpsInfo = fpsInfo
        if resolvedHEVCBFrames(explicit: bFrames, allIntra: allIntra) {
            print(
                "[DoVi] Profile 7.6 dual-layer requires matching BL/EL picture types; --b-frames is ignored."
            )
        }
        self.bFrames = false
        baseLayerBitrateBitsPerSecond = Int((
            bitrateMbps *
                DolbyVisionProfile7EncodingDefaults.baseLayerBitrateFraction *
                1_000_000.0
        ).rounded())
        enhancementLayerBitrateBitsPerSecond = Int((
            bitrateMbps *
                DolbyVisionProfile7EncodingDefaults.enhancementLayerBitrateFraction *
                1_000_000.0
        ).rounded())
        residualGenerator = try Profile7MetalResidualGenerator(rasterPlan: rasterPlan)
        let p7ColorSpace = SourceColorSpace.hevcHDR10(basedOn: colorSpace)
        let fpsHint = max(1, Int(fpsInfo.fps.rounded()))

        let baseLayerOptions = HEVCEncodeOptions(
            // Keep a stable whole-percent split between the base and
            // enhancement layers.
            bitrateMbps: bitrateMbps *
                DolbyVisionProfile7EncodingDefaults.baseLayerBitrateFraction,
            dvProfile: .profile76,
            keyFrameIntervalSeconds:
                DolbyVisionProfile7EncodingDefaults.keyFrameIntervalSeconds,
            allIntra: allIntra,
            bFrames: false,
            bitrateMode: bitrateMode,
            multiPass: multiPass
        )

        let enhancementLayerOptions = HEVCEncodeOptions(
            bitrateMbps: bitrateMbps *
                DolbyVisionProfile7EncodingDefaults.enhancementLayerBitrateFraction,
            dvProfile: nil,
            keyFrameIntervalSeconds:
                DolbyVisionProfile7EncodingDefaults.keyFrameIntervalSeconds,
            allIntra: allIntra,
            bFrames: false,
            bitrateMode: bitrateMode,
            multiPass: multiPass
        )

        baseLayerEncoder = try ProResSession(
            width: rasterPlan.encodedWidth,
            height: rasterPlan.encodedHeight,
            codecType: kCMVideoCodecType_HEVC,
            fpsHint: fpsHint,
            colorSpace: p7ColorSpace,
            hevcOptions: baseLayerOptions,
            sourceFrameCount: sourceFrameCount,
            sourceTimeRange: sourceTimeRange
        )

        enhancementLayerEncoder = try ProResSession(
            width: residualGenerator.width,
            height: residualGenerator.height,
            codecType: kCMVideoCodecType_HEVC,
            fpsHint: fpsHint,
            colorSpace: p7ColorSpace,
            hevcOptions: enhancementLayerOptions,
            sourceFrameCount: sourceFrameCount,
            sourceTimeRange: sourceTimeRange
        )
        if self.bFrames {
            baseLayerEncoder.enableEncodedSampleQueue()
            enhancementLayerEncoder.enableEncodedSampleQueue()
        }
    }

    /// True when both layer encoders attached VideoToolbox multi-pass storage.
    var isMultiPassEnabled: Bool {
        baseLayerEncoder.isMultiPassEnabled || enhancementLayerEncoder.isMultiPassEnabled
    }

    /// Encodes one source frame and returns any muxed Profile 7 samples that are now ready.
    func encode(
        sourcePixelBuffer: CVPixelBuffer,
        pts: CMTime,
        duration: CMTime,
        rpuNALUnit: Data,
        hdr10Metadata: HEVCHDR10Metadata?
    ) throws -> [DolbyVisionProfile7EncodedFrame] {
        if !bFrames {
            return [try encodeImmediate(
                sourcePixelBuffer: sourcePixelBuffer,
                pts: pts,
                duration: duration,
                rpuNALUnit: rpuNALUnit,
                hdr10Metadata: hdr10Metadata
            )]
        }
        let frameIndex = vtFrameIndex(for: pts, fps: fpsInfo)
        if nextELSubmitIndex == nil {
            nextELSubmitIndex = frameIndex
        }
        pendingSources[frameIndex] = Profile7PendingSource(
            pixelBuffer: sourcePixelBuffer,
            rpuNALUnit: rpuNALUnit,
            hdr10Metadata: hdr10Metadata,
            pts: pts,
            duration: duration
        )
        let baseLayerInput = try residualGenerator.makeBaseLayerInput(
            source: sourcePixelBuffer
        )
        guard baseLayerEncoder.submit(
            pixelBuffer: baseLayerInput,
            pts: pts,
            duration: duration
        ) else {
            throw DolbyVisionProfile7Error.make(
                "VideoToolbox failed to submit the Profile 7 base layer."
            )
        }
        return try drainCompletedFrames()
    }

    /// Collects muxed samples that became ready after EndPass or a final flush.
    func finishPending(flushEncoders: Bool = false) throws -> [DolbyVisionProfile7EncodedFrame] {
        var completed = completedAfterPassEnd
        completedAfterPassEnd.removeAll(keepingCapacity: true)
        if flushEncoders {
            baseLayerEncoder.flush()
            baseLayerEncoder.waitForEncodedCallbacks()
        }
        completed += try drainCompletedFrames()
        if flushEncoders {
            enhancementLayerEncoder.flush()
            enhancementLayerEncoder.waitForEncodedCallbacks()
            completed += try drainCompletedFrames()
        }
        return completed
    }

    /// Closed-loop encode used when B-frames are disabled.
    private func encodeImmediate(
        sourcePixelBuffer: CVPixelBuffer,
        pts: CMTime,
        duration: CMTime,
        rpuNALUnit: Data,
        hdr10Metadata: HEVCHDR10Metadata?
    ) throws -> DolbyVisionProfile7EncodedFrame {
        let baseLayerInput = try residualGenerator.makeBaseLayerInput(
            source: sourcePixelBuffer
        )
        guard let baseLayerSample = baseLayerEncoder.encode(
            pixelBuffer: baseLayerInput,
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
        return try muxEncodedLayers(
            baseLayerSample: baseLayerSample,
            enhancementLayerSample: enhancementLayerSample,
            rpuNALUnit: rpuNALUnit,
            hdr10Metadata: hdr10Metadata
        )
    }

    private func drainCompletedFrames() throws -> [DolbyVisionProfile7EncodedFrame] {
        var completed: [DolbyVisionProfile7EncodedFrame] = []
        for baseLayerSample in baseLayerEncoder.drainEncodedSamples() {
            let pts = CMSampleBufferGetPresentationTimeStamp(baseLayerSample)
            let frameIndex = vtFrameIndex(for: pts, fps: fpsInfo)
            guard let source = pendingSources[frameIndex] else {
                throw DolbyVisionProfile7Error.make(
                    "Profile 7 base-layer sample has no matching source frame."
                )
            }
            let reconstructedBaseLayer = try reconstructionDecoder.decode(baseLayerSample)
            pendingBaseLayers[frameIndex] = baseLayerSample
            pendingResiduals[frameIndex] = try residualGenerator.makeEnhancementLayer(
                source: source.pixelBuffer,
                reconstructedBaseLayer: reconstructedBaseLayer
            )
            try submitReadyEnhancementLayers()
        }
        for enhancementLayerSample in enhancementLayerEncoder.drainEncodedSamples() {
            let pts = CMSampleBufferGetPresentationTimeStamp(enhancementLayerSample)
            let frameIndex = vtFrameIndex(for: pts, fps: fpsInfo)
            guard let baseLayerSample = pendingBaseLayers.removeValue(forKey: frameIndex),
                  let source = pendingSources.removeValue(forKey: frameIndex) else {
                throw DolbyVisionProfile7Error.make(
                    "Profile 7 enhancement-layer sample has no matching base layer."
                )
            }
            completed.append(
                try muxEncodedLayers(
                    baseLayerSample: baseLayerSample,
                    enhancementLayerSample: enhancementLayerSample,
                    rpuNALUnit: source.rpuNALUnit,
                    hdr10Metadata: source.hdr10Metadata
                )
            )
        }
        return completed
    }

    /// VideoToolbox requires EncodeFrame in presentation order. BL reconstructs
    /// in decode order, so residuals are buffered and submitted by PTS.
    private func submitReadyEnhancementLayers() throws {
        guard var index = nextELSubmitIndex else { return }
        while let residual = pendingResiduals.removeValue(forKey: index),
              let source = pendingSources[index] {
            guard enhancementLayerEncoder.submit(
                pixelBuffer: residual,
                pts: source.pts,
                duration: source.duration
            ) else {
                throw DolbyVisionProfile7Error.make(
                    "VideoToolbox failed to submit the Profile 7 enhancement layer."
                )
            }
            index += 1
        }
        nextELSubmitIndex = index
    }

    private func muxEncodedLayers(
        baseLayerSample: CMSampleBuffer,
        enhancementLayerSample: CMSampleBuffer,
        rpuNALUnit: Data,
        hdr10Metadata: HEVCHDR10Metadata?
    ) throws -> DolbyVisionProfile7EncodedFrame {
        let isSync = sampleBufferIsSync(baseLayerSample)
        let framesSinceBPForPicture = isSync ? 0 : framesSinceBufferingPeriod + 1
        let concatenationFlag = isSync && accessUnitFrameIndex > 0
        let sample = try sampleBufferByMuxingDolbyVisionProfile7(
            baseLayerSample: baseLayerSample,
            enhancementLayerSample: enhancementLayerSample,
            rpuNALUnit: rpuNALUnit,
            hdr10Metadata: hdr10Metadata,
            fpsInfo: fpsInfo,
            baseLayerBitrateBitsPerSecond: baseLayerBitrateBitsPerSecond,
            enhancementLayerBitrateBitsPerSecond: enhancementLayerBitrateBitsPerSecond,
            framesSinceBufferingPeriod: framesSinceBPForPicture,
            concatenationFlag: concatenationFlag,
            existingFormatDescription: muxedFormatDescription
        )
        guard sampleBufferContainsHEVCDolbyVisionEL(sample),
              sampleBufferContainsHEVCDolbyVisionRPU(sample) else {
            throw DolbyVisionProfile7Error.make(
                "The encoded Profile 7 sample is missing its EL or RPU NAL unit."
            )
        }
        muxedFormatDescription = CMSampleBufferGetFormatDescription(sample)
        if isSync {
            framesSinceBufferingPeriod = 0
        } else {
            framesSinceBufferingPeriod += 1
        }
        accessUnitFrameIndex += 1
        return DolbyVisionProfile7EncodedFrame(
            muxedSample: sample,
            baseLayerSample: baseLayerSample,
            enhancementLayerSample: enhancementLayerSample,
            rpuNALUnit: rpuNALUnit
        )
    }

    /// Updates `SourceFrameCount` on both layer encoders before the next pass.
    func setSourceFrameCount(_ count: Int) {
        baseLayerEncoder.setSourceFrameCount(count)
        enhancementLayerEncoder.setSourceFrameCount(count)
    }

    /// Starts one VideoToolbox pass on both layer encoders.
    func beginCompressionPass(isFinal: Bool = false) throws {
        accessUnitFrameIndex = 0
        framesSinceBufferingPeriod = 0
        muxedFormatDescription = nil
        pendingSources.removeAll(keepingCapacity: true)
        pendingBaseLayers.removeAll(keepingCapacity: true)
        pendingResiduals.removeAll(keepingCapacity: true)
        nextELSubmitIndex = nil
        completedAfterPassEnd.removeAll(keepingCapacity: true)
        baseLayerEncoder.resetEncodedSampleQueue()
        enhancementLayerEncoder.resetEncodedSampleQueue()
        try baseLayerEncoder.beginCompressionPass(isFinal: isFinal)
        try enhancementLayerEncoder.beginCompressionPass(isFinal: isFinal)
    }

    /// Ends the current pass and unions any extra time ranges both layers still want.
    /// With B-frames, the base layer must EndPass and reconstruct before the
    /// enhancement layer EndPass, or the delayed EL frames are submitted too late.
    func endCompressionPass(evaluateFurtherPasses: Bool = true) throws -> Bool {
        if !bFrames {
            completedAfterPassEnd.removeAll(keepingCapacity: true)
            let baseWantsMore = try baseLayerEncoder.endCompressionPass(
                evaluateFurtherPasses: evaluateFurtherPasses
            )
            let enhancementWantsMore = try enhancementLayerEncoder.endCompressionPass(
                evaluateFurtherPasses: evaluateFurtherPasses
            )
            return baseWantsMore || enhancementWantsMore
        }
        let baseWantsMore = try baseLayerEncoder.endCompressionPass(
            evaluateFurtherPasses: evaluateFurtherPasses
        )
        var completed = try drainLayerUntilCaughtUp(baseLayerEncoder)
        if let index = nextELSubmitIndex, !pendingResiduals.isEmpty {
            let buffered = pendingResiduals.keys.sorted()
            throw DolbyVisionProfile7Error.make(
                "Profile 7 enhancement-layer submit stalled at frame \(index); buffered residuals \(buffered); pending BL callbacks \(baseLayerEncoder.pendingEncodedCallbacks())."
            )
        }
        let enhancementWantsMore = try enhancementLayerEncoder.endCompressionPass(
            evaluateFurtherPasses: evaluateFurtherPasses
        )
        completed += try drainLayerUntilCaughtUp(enhancementLayerEncoder)
        completedAfterPassEnd = completed
        return baseWantsMore || enhancementWantsMore
    }

    /// Drains layer callbacks until VideoToolbox has delivered every submitted frame.
    private func drainLayerUntilCaughtUp(_ encoder: ProResSession) throws -> [DolbyVisionProfile7EncodedFrame] {
        var completed: [DolbyVisionProfile7EncodedFrame] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            completed += try drainCompletedFrames()
            if encoder.pendingEncodedCallbacks() == 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        completed += try drainCompletedFrames()
        return completed
    }

    /// Combined next-pass ranges from the base and enhancement encoders.
    func timeRangesForNextPass() throws -> [CMTimeRange] {
        let baseRanges = try baseLayerEncoder.timeRangesForNextPass()
        let enhancementRanges = try enhancementLayerEncoder.timeRangesForNextPass()
        return mergedVTTimeRanges(baseRanges, enhancementRanges)
    }

    /// Flushes delayed frames from both layer encoders.
    func finish() {
        baseLayerEncoder.flush()
        enhancementLayerEncoder.flush()
    }

    /// Releases decoder and encoder resources after completion or failure.
    func invalidate() {
        reconstructionDecoder.invalidate()
        baseLayerEncoder.invalidate()
        enhancementLayerEncoder.invalidate()
    }
}
