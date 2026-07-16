// Converts decoded pixel buffers through direct color mapping or native LUT
// burn-in and emits pixel buffers tagged for the declared output space.

import Foundation
import CoreMedia
import CoreVideo
import Metal

/// Supplies the module bundle used to locate packaged color kernels.
private final class MetalColorResourceBundleToken: NSObject {}

/// GPU setup, texture binding, LUT upload, and command-execution failures.
enum MetalColorPipelineError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case libraryUnavailable
    case functionUnavailable(String)
    case pixelBufferPoolFailed(CVReturn)
    case pixelBufferAllocationFailed(CVReturn)
    case unsupportedPixelFormat(OSType)
    case textureCreationFailed(String, CVReturn)
    case lutTextureCreationFailed(String)
    case commandEncodingFailed
    case commandExecutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal color conversion was requested, but no Metal device is available. CPU fallback is prohibited."
        case .commandQueueUnavailable:
            return "Metal color conversion could not create a command queue."
        case .libraryUnavailable:
            return "Metal color conversion could not load ColorScienceKernels from the built Metal library."
        case .functionUnavailable(let name):
            return "Metal color conversion kernel '\(name)' is missing."
        case .pixelBufferPoolFailed(let status):
            return "Metal color conversion could not create its CVPixelBufferPool: \(status)."
        case .pixelBufferAllocationFailed(let status):
            return "Metal color conversion could not allocate an output CVPixelBuffer: \(status)."
        case .unsupportedPixelFormat(let format):
            return "Metal color conversion does not support pixel format \(fourCC(format))."
        case .textureCreationFailed(let plane, let status):
            return "Metal color conversion could not bind the \(plane) texture: \(status)."
        case .lutTextureCreationFailed(let detail):
            return "Metal color conversion could not upload the LUT texture: \(detail)."
        case .commandEncodingFailed:
            return "Metal color conversion could not create a command buffer/encoder."
        case .commandExecutionFailed(let detail):
            return "Metal color conversion command failed: \(detail)."
        }
    }
}

/// CPU layout mirrored by `ColorUniforms` in the Metal source.
private struct MetalColorUniforms {
    var matrix0: SIMD4<Float>
    var matrix1: SIMD4<Float>
    var matrix2: SIMD4<Float>
    var inputTransfer: UInt32
    var outputTransfer: UInt32
    var inputYCbCrMatrix: UInt32
    var outputYCbCrMatrix: UInt32
    var sourcePeakNits: Float
    var targetPeakNits: Float
    var chromaVerticalSubsampling: UInt32
    var gamutLimitMode: UInt32
    var inputLuma: SIMD4<Float>
    var outputLuma: SIMD4<Float>
    var lut1DMin: SIMD4<Float>
    var lut1DScale: SIMD4<Float>
    var lut3DMin: SIMD4<Float>
    var lut3DScale: SIMD4<Float>
    var hasLUT1D: UInt32
    var hasLUT3D: UInt32
    var reserved0: UInt32
    var reserved1: UInt32
}

/// Owns reusable textures, output buffers, LUT textures, and compute pipelines.
final class MetalColorPipeline: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let outputPool: CVPixelBufferPool
    private let linearTexture: MTLTexture
    private let encodedTexture: MTLTexture
    private let lut1DTexture: MTLTexture
    private let lut3DTexture: MTLTexture
    private let decodeYUV: MTLComputePipelineState
    private let decodeBGRA: MTLComputePipelineState
    private let transform: MTLComputePipelineState
    private let packY: MTLComputePipelineState
    private let packUV: MTLComputePipelineState
    private let packBGRA: MTLComputePipelineState
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    private let outputColorSpace: SourceColorSpace
    private var uniforms: MetalColorUniforms
    private let processLock = NSLock()

    /// Validates dimensions/format and allocates all resources before frame processing.
    init(
        transform resolved: ResolvedColorTransform,
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalColorPipelineError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalColorPipelineError.commandQueueUnavailable
        }
        guard Self.isSupported(pixelFormat) else {
            throw MetalColorPipelineError.unsupportedPixelFormat(pixelFormat)
        }

        self.device = device
        self.commandQueue = commandQueue
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        outputColorSpace = resolved.outputColorSpace

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw MetalColorPipelineError.textureCreationFailed("texture cache", cacheStatus)
        }
        textureCache = cache

        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 6
            ] as CFDictionary,
            [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
                kCVPixelBufferWidthKey as String: NSNumber(value: width),
                kCVPixelBufferHeightKey as String: NSNumber(value: height),
                kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as Any,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
            ] as CFDictionary,
            &pool
        )
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw MetalColorPipelineError.pixelBufferPoolFailed(poolStatus)
        }
        outputPool = pool

        let intermediateDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        intermediateDescriptor.storageMode = .private
        intermediateDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let linear = device.makeTexture(descriptor: intermediateDescriptor),
              let encoded = device.makeTexture(descriptor: intermediateDescriptor) else {
            throw MetalColorPipelineError.commandEncodingFailed
        }
        linearTexture = linear
        encodedTexture = encoded

        let lutTextures = try Self.makeLUTTextures(device: device, lut: resolved.lut)
        lut1DTexture = lutTextures.oneDimensional
        lut3DTexture = lutTextures.threeDimensional

        guard let library = Self.loadLibrary(device: device) else {
            throw MetalColorPipelineError.libraryUnavailable
        }
        decodeYUV = try Self.makePipeline("color_decode_yuv", library: library, device: device)
        decodeBGRA = try Self.makePipeline("color_decode_bgra", library: library, device: device)
        transform = try Self.makePipeline("color_transform_linear", library: library, device: device)
        packY = try Self.makePipeline("color_pack_y", library: library, device: device)
        packUV = try Self.makePipeline("color_pack_uv", library: library, device: device)
        packBGRA = try Self.makePipeline("color_pack_bgra", library: library, device: device)

        let verticalSubsampling: UInt32 =
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 2 : 1
        uniforms = MetalColorUniforms(
            matrix0: resolved.matrixColumns.0,
            matrix1: resolved.matrixColumns.1,
            matrix2: resolved.matrixColumns.2,
            inputTransfer: resolved.input.oetf.rawValue,
            outputTransfer: resolved.outputOETF.rawValue,
            inputYCbCrMatrix: resolved.input.yCbCrMatrixID,
            outputYCbCrMatrix: resolved.outputGamut.matrixID,
            sourcePeakNits: resolved.input.peakNits,
            targetPeakNits: resolved.targetNits,
            chromaVerticalSubsampling: verticalSubsampling,
            gamutLimitMode: resolved.outputGamut.gamutLimitMode,
            inputLuma: resolved.input.gamut.lumaCoefficients,
            outputLuma: resolved.outputGamut.lumaCoefficients,
            lut1DMin: SIMD4(resolved.lut?.oneDimensional?.domainMin ?? SIMD3(repeating: 0), 0),
            lut1DScale: SIMD4(resolved.lut?.oneDimensional?.domainScale ?? SIMD3(repeating: 1), 0),
            lut3DMin: SIMD4(resolved.lut?.threeDimensional?.domainMin ?? SIMD3(repeating: 0), 0),
            lut3DScale: SIMD4(resolved.lut?.threeDimensional?.domainScale ?? SIMD3(repeating: 1), 0),
            hasLUT1D: resolved.lut?.oneDimensional == nil ? 0 : 1,
            hasLUT3D: resolved.lut?.threeDimensional == nil ? 0 : 1,
            reserved0: 0,
            reserved1: 0
        )
    }

    /// Converts one decoded frame and returns a newly tagged output pixel buffer.
    func process(_ source: CVPixelBuffer, pts: CMTime) throws -> CVPixelBuffer {
        processLock.lock()
        defer { processLock.unlock() }

        guard CVPixelBufferGetPixelFormatType(source) == pixelFormat,
              CVPixelBufferGetWidth(source) == width,
              CVPixelBufferGetHeight(source) == height else {
            throw MetalColorPipelineError.unsupportedPixelFormat(
                CVPixelBufferGetPixelFormatType(source)
            )
        }

        var destination: CVPixelBuffer?
        var allocationStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            outputPool,
            &destination
        )
        if allocationStatus != kCVReturnSuccess || destination == nil {
            CVPixelBufferPoolFlush(outputPool, .excessBuffers)
            allocationStatus = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                outputPool,
                &destination
            )
        }
        guard allocationStatus == kCVReturnSuccess, let destination else {
            throw MetalColorPipelineError.pixelBufferAllocationFailed(allocationStatus)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalColorPipelineError.commandEncodingFailed
        }
        commandBuffer.label = "ProRes Encoder Metal Color \(CMTimeGetSeconds(pts))"

        var retainedTextures: [CVMetalTexture] = []
        if pixelFormat == kCVPixelFormatType_32BGRA {
            let sourceTexture = try makeTexture(
                from: source,
                plane: 0,
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                label: "source BGRA",
                retained: &retainedTextures
            )
            try encode(
                pipeline: decodeBGRA,
                commandBuffer: commandBuffer,
                textures: [sourceTexture, linearTexture],
                width: width,
                height: height
            )
        } else {
            let sourceY = try makeTexture(
                from: source,
                plane: 0,
                pixelFormat: .r16Unorm,
                width: width,
                height: height,
                label: "source Y",
                retained: &retainedTextures
            )
            let sourceUV = try makeTexture(
                from: source,
                plane: 1,
                pixelFormat: .rg16Unorm,
                width: CVPixelBufferGetWidthOfPlane(source, 1),
                height: CVPixelBufferGetHeightOfPlane(source, 1),
                label: "source UV",
                retained: &retainedTextures
            )
            try encode(
                pipeline: decodeYUV,
                commandBuffer: commandBuffer,
                textures: [sourceY, sourceUV, linearTexture],
                width: width,
                height: height
            )
        }

        try encodeTransform(commandBuffer: commandBuffer)

        if pixelFormat == kCVPixelFormatType_32BGRA {
            let outputTexture = try makeTexture(
                from: destination,
                plane: 0,
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                label: "output BGRA",
                retained: &retainedTextures
            )
            try encode(
                pipeline: packBGRA,
                commandBuffer: commandBuffer,
                textures: [encodedTexture, outputTexture],
                width: width,
                height: height
            )
        } else {
            let outputY = try makeTexture(
                from: destination,
                plane: 0,
                pixelFormat: .r16Unorm,
                width: width,
                height: height,
                label: "output Y",
                retained: &retainedTextures
            )
            let outputUVWidth = CVPixelBufferGetWidthOfPlane(destination, 1)
            let outputUVHeight = CVPixelBufferGetHeightOfPlane(destination, 1)
            let outputUV = try makeTexture(
                from: destination,
                plane: 1,
                pixelFormat: .rg16Unorm,
                width: outputUVWidth,
                height: outputUVHeight,
                label: "output UV",
                retained: &retainedTextures
            )
            try encode(
                pipeline: packY,
                commandBuffer: commandBuffer,
                textures: [encodedTexture, outputY],
                width: width,
                height: height
            )
            try encode(
                pipeline: packUV,
                commandBuffer: commandBuffer,
                textures: [encodedTexture, outputUV],
                width: outputUVWidth,
                height: outputUVHeight
            )
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retainedTextures) {}
        guard commandBuffer.status == .completed else {
            throw MetalColorPipelineError.commandExecutionFailed(
                commandBuffer.error?.localizedDescription ?? "status \(commandBuffer.status.rawValue)"
            )
        }

        attachOutputColorMetadata(to: destination)
        return destination
    }

    /// Encodes a generic compute pass for a fixed list of textures.
    private func encode(
        pipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer,
        textures: [MTLTexture],
        width: Int,
        height: Int
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalColorPipelineError.commandEncodingFailed
        }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        withUnsafeBytes(of: &uniforms) { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        let threadWidth = max(pipeline.threadExecutionWidth, 1)
        let threadHeight = max(
            min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, 16),
            1
        )
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
    }

    /// Binds direct/LUT transform resources and dispatches the full image grid.
    private func encodeTransform(commandBuffer: MTLCommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalColorPipelineError.commandEncodingFailed
        }
        encoder.setComputePipelineState(transform)
        encoder.setTexture(linearTexture, index: 0)
        encoder.setTexture(encodedTexture, index: 1)
        encoder.setTexture(lut1DTexture, index: 2)
        encoder.setTexture(lut3DTexture, index: 3)
        withUnsafeBytes(of: &uniforms) { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        let threadWidth = max(transform.threadExecutionWidth, 1)
        let threadHeight = max(
            min(transform.maxTotalThreadsPerThreadgroup / threadWidth, 16),
            1
        )
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
    }

    /// Creates actual or identity textures so shader bindings are always complete.
    private static func makeLUTTextures(
        device: MTLDevice,
        lut: CubeLUT?
    ) throws -> (oneDimensional: MTLTexture, threeDimensional: MTLTexture) {
        let oneDimensional = try makeLUT1DTexture(device: device, lut: lut?.oneDimensional)
        let threeDimensional = try makeLUT3DTexture(device: device, lut: lut?.threeDimensional)
        return (oneDimensional, threeDimensional)
    }

    /// Uploads a one-row RGBA float texture for per-channel LUT sampling.
    private static func makeLUT1DTexture(
        device: MTLDevice,
        lut: CubeLUT1D?
    ) throws -> MTLTexture {
        let size = lut?.size ?? 2
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: size,
            height: 1,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalColorPipelineError.lutTextureCreationFailed("could not allocate the 1D LUT texture.")
        }
        texture.label = lut == nil ? "identity 1D LUT" : "cube 1D LUT"
        let values = lut?.values ?? [
            SIMD4<Float>(0, 0, 0, 1),
            SIMD4<Float>(1, 1, 1, 1)
        ]
        values.withUnsafeBufferPointer { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, size, 1),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: size * MemoryLayout<SIMD4<Float>>.stride
            )
        }
        return texture
    }

    /// Uploads red-fastest RGB samples without changing .cube axis order.
    private static func makeLUT3DTexture(
        device: MTLDevice,
        lut: CubeLUT3D?
    ) throws -> MTLTexture {
        let size = lut?.size ?? 2
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalColorPipelineError.lutTextureCreationFailed("could not allocate the 3D LUT texture.")
        }
        texture.label = lut == nil ? "identity 3D LUT" : "cube 3D LUT"
        // Both .cube storage and Metal 3D textures use the X coordinate as the
        // fastest-varying dimension, so the parsed RGB table is uploaded as-is.
        let values = lut?.values ?? identity3DLUTValues(size: size)
        values.withUnsafeBufferPointer { buffer in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, size, size, size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: size * MemoryLayout<SIMD4<Float>>.stride,
                bytesPerImage: size * size * MemoryLayout<SIMD4<Float>>.stride
            )
        }
        return texture
    }

    /// Generates a red-fastest identity cube for pipelines without a 3D table.
    private static func identity3DLUTValues(size: Int) -> [SIMD4<Float>] {
        let maxIndex = Float(max(size - 1, 1))
        var values: [SIMD4<Float>] = []
        values.reserveCapacity(size * size * size)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    values.append(SIMD4<Float>(
                        Float(red) / maxIndex,
                        Float(green) / maxIndex,
                        Float(blue) / maxIndex,
                        1
                    ))
                }
            }
        }
        return values
    }

    /// Binds one pixel-buffer plane and retains its texture wrapper for command lifetime.
    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
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
            throw MetalColorPipelineError.textureCreationFailed(label, status)
        }
        texture.label = label
        retained.append(cvTexture)
        return texture
    }

    /// Attaches output primaries, transfer, matrix, and timing to a converted buffer.
    private func attachOutputColorMetadata(to pixelBuffer: CVPixelBuffer) {
        if let primaries = outputColorSpace.primaries {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                primaries as CFString,
                .shouldPropagate
            )
        }
        if let transfer = outputColorSpace.transfer {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                transfer as CFString,
                .shouldPropagate
            )
        }
        if let matrix = outputColorSpace.matrix {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                matrix as CFString,
                .shouldPropagate
            )
        }
    }

    /// Resolves a named kernel and creates its compute pipeline state.
    private static func makePipeline(
        _ functionName: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: functionName) else {
            throw MetalColorPipelineError.functionUnavailable(functionName)
        }
        return try device.makeComputePipelineState(function: function)
    }

    /// Loads all required color kernels from embedded or packaged GPU code.
    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        EmbeddedMetalLibrary.load(
            device: device,
            bundle: Bundle(for: MetalColorResourceBundleToken.self),
            requiredFunctions: [
                "color_decode_yuv",
                "color_decode_bgra",
                "color_transform_linear",
                "color_pack_y",
                "color_pack_uv",
                "color_pack_bgra"
            ]
        )
    }

    /// Returns whether the pipeline has decode and pack kernels for a pixel format.
    private static func isSupported(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_32BGRA
    }
}

/// Formats a pixel-format code for diagnostics.
private func fourCC(_ code: OSType) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}
