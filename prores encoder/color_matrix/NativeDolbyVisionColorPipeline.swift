// Runs the dedicated Profile 5 / Native Profile 10 color transform without
// changing the generic color-conversion path.

import Foundation
import CoreMedia
import CoreVideo
import Metal

private final class NativeDolbyVisionMetalBundleToken: NSObject {}

final class NativeDolbyVisionColorPipeline: @unchecked Sendable {
    static let inputPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    static let outputPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let outputPool: CVPixelBufferPool
    private let intermediate: MTLTexture
    private let transform: MTLComputePipelineState
    private let packY: MTLComputePipelineState
    private let packUV: MTLComputePipelineState
    private let inputGamut: UInt32
    private let width: Int
    private let height: Int
    private let processLock = NSLock()

    init(width: Int, height: Int, inputGamut: VideoGamut) throws {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw MetalColorPipelineError.unsupportedPixelFormat(Self.outputPixelFormat)
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalColorPipelineError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalColorPipelineError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue
        self.inputGamut = inputGamut == .p3D65 ? VideoGamut.p3D65.rawValue : VideoGamut.rec2020.rawValue
        self.width = width
        self.height = height

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw MetalColorPipelineError.textureCreationFailed("Native DV texture cache", cacheStatus)
        }
        textureCache = cache

        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
            [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: Self.outputPixelFormat),
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

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let intermediate = device.makeTexture(descriptor: descriptor) else {
            throw MetalColorPipelineError.commandEncodingFailed
        }
        self.intermediate = intermediate

        let required = ["native_dv_transform", "native_dv_pack_y", "native_dv_pack_uv"]
        guard let library = Self.loadLibrary(device: device, requiredFunctions: required) else {
            throw MetalColorPipelineError.libraryUnavailable
        }
        transform = try Self.makePipeline("native_dv_transform", library: library, device: device)
        packY = try Self.makePipeline("native_dv_pack_y", library: library, device: device)
        packUV = try Self.makePipeline("native_dv_pack_uv", library: library, device: device)
    }

    func process(_ source: CVPixelBuffer, pts: CMTime) throws -> CVPixelBuffer {
        processLock.lock()
        defer { processLock.unlock() }

        guard CVPixelBufferGetPixelFormatType(source) == Self.inputPixelFormat,
              CVPixelBufferGetWidth(source) == width,
              CVPixelBufferGetHeight(source) == height else {
            throw MetalColorPipelineError.unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(source))
        }

        var destination: CVPixelBuffer?
        var status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &destination)
        if status != kCVReturnSuccess || destination == nil {
            CVPixelBufferPoolFlush(outputPool, .excessBuffers)
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &destination)
        }
        guard status == kCVReturnSuccess, let destination else {
            throw MetalColorPipelineError.pixelBufferAllocationFailed(status)
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalColorPipelineError.commandEncodingFailed
        }
        commandBuffer.label = "Native Dolby Vision IPT \(CMTimeGetSeconds(pts))"

        var retained: [CVMetalTexture] = []
        let sourceY = try makeTexture(
            from: source,
            plane: 0,
            format: .r16Unorm,
            width: width,
            height: height,
            label: "Native DV source Y",
            retained: &retained
        )
        let sourceUV = try makeTexture(
            from: source,
            plane: 1,
            format: .rg16Unorm,
            width: CVPixelBufferGetWidthOfPlane(source, 1),
            height: CVPixelBufferGetHeightOfPlane(source, 1),
            label: "Native DV source UV",
            retained: &retained
        )
        let outputY = try makeTexture(
            from: destination,
            plane: 0,
            format: .r16Unorm,
            width: width,
            height: height,
            label: "Native DV output I",
            retained: &retained
        )
        let outputUV = try makeTexture(
            from: destination,
            plane: 1,
            format: .rg16Unorm,
            width: CVPixelBufferGetWidthOfPlane(destination, 1),
            height: CVPixelBufferGetHeightOfPlane(destination, 1),
            label: "Native DV output PT",
            retained: &retained
        )

        try encode(
            transform,
            textures: [sourceY, sourceUV, intermediate],
            constantValue: inputGamut,
            width: width,
            height: height,
            commandBuffer: commandBuffer
        )
        try encode(
            packY,
            textures: [intermediate, outputY],
            width: width,
            height: height,
            commandBuffer: commandBuffer
        )
        try encode(
            packUV,
            textures: [intermediate, outputUV],
            width: CVPixelBufferGetWidthOfPlane(destination, 1),
            height: CVPixelBufferGetHeightOfPlane(destination, 1),
            commandBuffer: commandBuffer
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        withExtendedLifetime(retained) {}
        guard commandBuffer.status == .completed else {
            throw MetalColorPipelineError.commandExecutionFailed(
                commandBuffer.error?.localizedDescription ?? "status \(commandBuffer.status.rawValue)"
            )
        }
        return destination
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
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
            format,
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

    private func encode(
        _ pipeline: MTLComputePipelineState,
        textures: [MTLTexture],
        constantValue: UInt32? = nil,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalColorPipelineError.commandEncodingFailed
        }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        if var constantValue {
            encoder.setBytes(&constantValue, length: MemoryLayout<UInt32>.size, index: 0)
        }
        let threadWidth = max(pipeline.threadExecutionWidth, 1)
        let threadHeight = max(min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, 16), 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
    }

    private static func makePipeline(
        _ name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw MetalColorPipelineError.functionUnavailable(name)
        }
        return try device.makeComputePipelineState(function: function)
    }

    private static func loadLibrary(
        device: MTLDevice,
        requiredFunctions: [String]
    ) -> MTLLibrary? {
        EmbeddedMetalLibrary.load(
            device: device,
            bundle: Bundle(for: NativeDolbyVisionMetalBundleToken.self),
            requiredFunctions: requiredFunctions
        )
    }
}
