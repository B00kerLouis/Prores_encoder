import Foundation
import CoreMedia
import CoreVideo
import Metal

private final class MetalColorResourceBundleToken: NSObject {}

enum MetalColorPipelineError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case libraryUnavailable
    case functionUnavailable(String)
    case pixelBufferPoolFailed(CVReturn)
    case pixelBufferAllocationFailed(CVReturn)
    case unsupportedPixelFormat(OSType)
    case textureCreationFailed(String, CVReturn)
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
        case .commandEncodingFailed:
            return "Metal color conversion could not create a command buffer/encoder."
        case .commandExecutionFailed(let detail):
            return "Metal color conversion command failed: \(detail)."
        }
    }
}

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
}

final class MetalColorPipeline: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let outputPool: CVPixelBufferPool
    private let linearTexture: MTLTexture
    private let encodedTexture: MTLTexture
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
            outputLuma: resolved.outputGamut.lumaCoefficients
        )
    }

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

        try encode(
            pipeline: transform,
            commandBuffer: commandBuffer,
            textures: [linearTexture, encodedTexture],
            width: width,
            height: height
        )

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

    private static func isSupported(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_32BGRA
    }
}

private func fourCC(_ code: OSType) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}
