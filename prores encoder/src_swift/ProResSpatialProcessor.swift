// B00kerLouis. Framework-only explicit RGBAHalf spatial processing.
import Foundation
import CoreMedia
import CoreVideo
import Metal

public struct ProResSpatialStatistics: Sendable {
    public let pendingGPUFrames: Int
    public let peakPendingGPUFrames: Int
    public let encodedDispatches: Int64
    public let passthroughFrames: Int64
    public let workingSetBoundBytes: Int64
}

fileprivate final class SpatialCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let pending = waiters; waiters.removeAll(); lock.unlock()
        for waiter in pending { waiter.resume(with: result) }
    }
}

/// Retain this output until an encoder accepts it. The encoder then retains
/// pixelBuffer through its own receipt. GPU source/textures remain independently
/// retained by the caller's command buffer until completion or uncommitted
/// command destruction. No command buffer is strongly held by this lease.
public final class ProResSpatialFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let isPassthrough: Bool
    private let completion: SpatialCompletion
    fileprivate init(buffer: CVPixelBuffer, passthrough: Bool, completion: SpatialCompletion) {
        pixelBuffer = buffer; isPassthrough = passthrough; self.completion = completion
    }
    public func waitForGPUCompletion() async throws { try await completion.wait() }
}

private final class SpatialState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pending = 0, peak = 0
    private var dispatches: Int64 = 0, passthrough: Int64 = 0
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func admit() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw ProResSpatialError.cancelled }
        guard pending < capacity else { return false }
        pending += 1; peak = max(peak, pending); return true
    }
    func finished() { lock.lock(); pending -= 1; lock.unlock() }
    func encoded(passthrough: Bool) {
        lock.lock()
        if passthrough { self.passthrough += 1 } else { dispatches += 1 }
        lock.unlock()
    }
    func snapshot(bound: Int64) -> ProResSpatialStatistics {
        lock.lock(); defer { lock.unlock() }
        return .init(pendingGPUFrames: pending, peakPendingGPUFrames: peak, encodedDispatches: dispatches,
                     passthroughFrames: passthrough, workingSetBoundBytes: bound)
    }
}

/// Captured by Metal, never owning Metal's command. Deinit also resolves a
/// discarded, uncommitted command; there is no command/handler ownership cycle.
private final class SpatialGPUResources: @unchecked Sendable {
    private var buffers: [CVPixelBuffer]
    private var textures: [CVMetalTexture]
    private let completion: SpatialCompletion
    private let state: SpatialState
    private var done = false
    init(buffers: [CVPixelBuffer], textures: [CVMetalTexture], completion: SpatialCompletion, state: SpatialState) {
        self.buffers = buffers; self.textures = textures; self.completion = completion; self.state = state
    }
    func complete(_ error: Error?) {
        guard !done else { return }; done = true
        buffers.removeAll(); textures.removeAll(); state.finished()
        let actual = error ?? (state.isCancelled ? ProResSpatialError.cancelled : nil)
        completion.resolve(actual.map { .failure($0) } ?? .success(()))
    }
    deinit { complete(ProResSpatialError.invalidCommand("The uncommitted spatial command was discarded.")) }
}

private struct SpatialUniforms {
    var content: SIMD4<Float>
    var scale: Float
    var whiteNits: Float
    var pq: UInt32
    var linearLight: UInt32
    var opaqueAlpha: UInt32
    var transparentPadding: UInt32
    var unitScale: UInt32
    var reserved: UInt32 = 0
}
private final class SpatialResourceToken: NSObject {}

/// Opt-in fixed-bilinear spatial processing; interpolationDomain names the
/// color domain, not the filter. Default source geometry is a true no-op and
/// allocates no pool/cache/PSO, encodes no dispatch and copies no pixel payload.
/// Prefer selecting the V1 encoder directly at setup when plan.isPassthrough.
public final class ProResSpatialProcessor: @unchecked Sendable {
    public let plan: ProResSpatialPlan
    public let color: ProResPreparedColorDescriptor
    public let device: MTLDevice
    public let capacity: Int
    public let interpolationDomain: ProResSpatialInterpolationDomain
    public let alpha: ProResSpatialAlpha
    public let padding: ProResSpatialPadding
    public let maximumSourceBytesPerRow: Int
    public let workingSetBoundBytes: Int64
    private let state: SpatialState
    private let lock = NSLock()
    private let pool: CVPixelBufferPool?
    private let cache: CVMetalTextureCache?
    private let pipeline: MTLComputePipelineState?
    private let maximumSourceDataBytes: Int
    private var uniforms: SpatialUniforms

    /// Recommended composition: capacity/device/input color come from the
    /// encoder. Matching capacity prevents a spatial-pool/codec-drain deadlock.
    public convenience init(plan: ProResSpatialPlan, encodingSession: ProResPreparedFrameSession,
                            interpolationDomain: ProResSpatialInterpolationDomain = .linearLight,
                            alpha: ProResSpatialAlpha = .straight, padding: ProResSpatialPadding = .opaqueBlack,
                            maximumSourceBytesPerRow: Int? = nil) throws {
        try self.init(plan: plan, color: encodingSession.inputColor, device: encodingSession.device,
            capacity: encodingSession.capacity, interpolationDomain: interpolationDomain, alpha: alpha,
            padding: padding, maximumSourceBytesPerRow: maximumSourceBytesPerRow)
        try validate(encodingSession: encodingSession)
    }

    /// Standalone use must explicitly validate its eventual encoder. The
    /// working-set bound covers retained source plane data plus owned output
    /// plane data at capacity; it excludes VT/driver allocations.
    public init(plan: ProResSpatialPlan, color: ProResPreparedColorDescriptor, device: MTLDevice,
                capacity: Int = 4, interpolationDomain: ProResSpatialInterpolationDomain = .linearLight,
                alpha: ProResSpatialAlpha = .straight, padding: ProResSpatialPadding = .opaqueBlack,
                maximumSourceBytesPerRow: Int? = nil) throws {
        guard (2...16).contains(capacity), color.range == .full,
              color.referenceWhiteNits.isFinite, color.nominalPeakNits.isFinite,
              color.referenceWhiteNits > 0, color.nominalPeakNits >= color.referenceWhiteNits,
              color.nominalPeakNits <= 10000,
              color.transfer != .bt709 || color.referenceWhiteNits == color.nominalPeakNits,
              !(alpha == .opaque && padding == .transparentBlack) else {
            throw ProResSpatialError.unsupportedInput("Spatial processing requires valid full-domain BT.709/PQ color, capacity 2...16, and consistent alpha/padding semantics.")
        }
        if let minimum = color.masteringMinimumNits {
            guard color.transfer == .pq, minimum.isFinite, minimum >= 0, minimum < color.nominalPeakNits else { throw ProResSpatialError.unsupportedInput("Invalid explicit mastering minimum.") }
        }
        let sourceRow = maximumSourceBytesPerRow ?? ((plan.source.raster.width * 8 + 255) / 256 * 256)
        guard sourceRow >= plan.source.raster.width * 8, sourceRow.isMultiple(of: 8) else {
            throw ProResSpatialError.invalidGeometry("Invalid source stride bound.")
        }
        self.plan = plan; self.color = color; self.device = device; self.capacity = capacity
        self.interpolationDomain = interpolationDomain; self.alpha = alpha; self.padding = padding
        self.maximumSourceBytesPerRow = sourceRow
        maximumSourceDataBytes = Int(try SpatialWorkingSetBudget.planeBytes(row: sourceRow, height: plan.source.raster.height))
        _ = try SpatialWorkingSetBudget.total(source: Int64(maximumSourceDataBytes), output: 0, capacity: capacity)
        state = SpatialState(capacity: capacity)
        uniforms = .init(content: SIMD4(Float(plan.contentRect.x), Float(plan.contentRect.y), Float(plan.contentRect.width), Float(plan.contentRect.height)),
            scale: Float(plan.scale), whiteNits: color.referenceWhiteNits, pq: color.transfer == .pq ? 1 : 0,
            linearLight: interpolationDomain == .linearLight ? 1 : 0, opaqueAlpha: alpha == .opaque ? 1 : 0,
            transparentPadding: padding == .transparentBlack ? 1 : 0, unitScale: plan.isPixelAlignedUnitScale ? 1 : 0)
        if plan.isPassthrough {
            pool = nil; cache = nil; pipeline = nil; workingSetBoundBytes = 0
            return
        }
        let outputRowBound = (plan.canvas.width * 8 + 255) / 256 * 256
        _ = try SpatialWorkingSetBudget.total(source: Int64(maximumSourceDataBytes),
            output: SpatialWorkingSetBudget.planeBytes(row: outputRowBound, height: plan.canvas.height), capacity: capacity)
        guard let library = EmbeddedMetalLibrary.load(device: device, bundle: Bundle(for: SpatialResourceToken.self), requiredFunctions: ["prores_spatial_rgba_half"]),
              let function = library.makeFunction(name: "prores_spatial_rgba_half") else { throw ProResSpatialError.metal("The independent spatial Metal function is unavailable.") }
        pipeline = try device.makeComputePipelineState(function: function)
        var madeCache: CVMetalTextureCache?
        let cs = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &madeCache)
        guard cs == 0, let madeCache else { throw ProResSpatialError.metal("Spatial texture-cache setup failed: \(cs).") }
        cache = madeCache
        var madePool: CVPixelBufferPool?
        let ps = CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: capacity] as CFDictionary,
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf, kCVPixelBufferWidthKey as String: plan.canvas.width,
             kCVPixelBufferHeightKey as String: plan.canvas.height, kCVPixelBufferMetalCompatibilityKey as String: true,
             kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &madePool)
        guard ps == 0, let madePool else { throw ProResSpatialError.metal("Spatial output-pool setup failed: \(ps).") }
        pool = madePool
        let outputDataBytes = try autoreleasepool {
            var warm: [CVPixelBuffer] = []
            for _ in 0..<capacity { guard let frame = try Self.allocate(madePool, capacity: capacity) else { throw ProResSpatialError.metal("Spatial prewarm exceeded its own capacity.") }; warm.append(frame) }
            _ = try Self.texture(warm[0], cache: madeCache)
            CVMetalTextureCacheFlush(madeCache, 0)
            return CVPixelBufferGetDataSize(warm[0])
        }
        workingSetBoundBytes = try SpatialWorkingSetBudget.total(source: Int64(maximumSourceDataBytes), output: Int64(outputDataBytes), capacity: capacity)
    }

    public func validate(encodingSession: ProResPreparedFrameSession) throws {
        guard encodingSession.width == plan.canvas.width, encodingSession.height == plan.canvas.height,
              encodingSession.device.registryID == device.registryID, encodingSession.inputColor == color,
              capacity >= encodingSession.capacity else {
            throw ProResSpatialError.invalidGeometry("Spatial canvas/device/input color must match the encoder, and spatial capacity must be >= encoder capacity to guarantee batch-drain progress.")
        }
    }
    public var statistics: ProResSpatialStatistics { state.snapshot(bound: workingSetBoundBytes) }
    public func cancel() { state.cancel() }

    /// No internal command is created or committed. With .sameCommandBuffer,
    /// producer writes must already be encoded earlier in this same command.
    /// .completed explicitly asserts CPU/GPU writes are finished/visible.
    /// Register ProResPreparedMetalProducer before committing this command.
    /// Nil command is allowed only for no-op geometry with .completed input.
    /// Nil output is nonblocking pool backpressure; retain/retry after a prior
    /// encoder receipt and release the corresponding spatial lease.
    public func encode(_ source: CVPixelBuffer, into command: MTLCommandBuffer? = nil,
                       readiness: ProResSpatialInputReadiness) throws -> ProResSpatialFrame? {
        lock.lock(); defer { lock.unlock() }
        if state.isCancelled { throw ProResSpatialError.cancelled }
        try validateInput(source)
        if let command {
            guard command.status == .notEnqueued, command.commandQueue.device.registryID == device.registryID,
                  command.retainedReferences else { throw ProResSpatialError.invalidCommand("Spatial commands must be notEnqueued, use the configured device and retain their resources.") }
        } else {
            guard plan.isPassthrough, readiness == .completed else { throw ProResSpatialError.invalidCommand("Actual spatial processing requires a caller-owned uncommitted command buffer; nil is only a CPU/GPU-complete no-op.") }
            let completion = SpatialCompletion(); completion.resolve(.success(())); state.encoded(passthrough: true)
            return .init(buffer: source, passthrough: true, completion: completion)
        }
        guard let command else { throw ProResSpatialError.invalidCommand("Missing spatial command.") }
        guard try state.admit() else { return nil }
        var registered = false
        defer { if !registered { state.finished() } }
        let completion = SpatialCompletion()
        let result: ProResSpatialFrame?
        if plan.isPassthrough {
            let resources = SpatialGPUResources(buffers: [source], textures: [], completion: completion, state: state)
            command.addCompletedHandler { command in resources.complete(command.status == .completed ? nil : ProResSpatialError.metal(command.error?.localizedDescription ?? "Spatial producer command failed.")) }
            result = .init(buffer: source, passthrough: true, completion: completion)
        } else {
            guard let pool, let cache, let pipeline else { throw ProResSpatialError.metal("Spatial resources are missing.") }
            result = try autoreleasepool {
                guard let destination = try Self.allocate(pool, capacity: capacity) else { return nil }
                let inputTexture = try Self.texture(source, cache: cache), outputTexture = try Self.texture(destination, cache: cache)
                guard let encoder = command.makeComputeCommandEncoder() else { throw ProResSpatialError.metal("Spatial compute encoding failed.") }
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(CVMetalTextureGetTexture(inputTexture), index: 0); encoder.setTexture(CVMetalTextureGetTexture(outputTexture), index: 1)
                encoder.setBytes(&uniforms, length: MemoryLayout<SpatialUniforms>.stride, index: 0)
                let w = pipeline.threadExecutionWidth
                encoder.dispatchThreads(MTLSize(width: plan.canvas.width, height: plan.canvas.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
                encoder.endEncoding()
                attachOutputMetadata(destination)
                let resources = SpatialGPUResources(buffers: [source,destination], textures: [inputTexture,outputTexture], completion: completion, state: state)
                command.addCompletedHandler { command in resources.complete(command.status == .completed ? nil : ProResSpatialError.metal(command.error?.localizedDescription ?? "Spatial command failed.")) }
                return .init(buffer: destination, passthrough: false, completion: completion)
            }
        }
        guard let result else { return nil }
        registered = true; state.encoded(passthrough: plan.isPassthrough)
        return result
    }

    private func validateInput(_ source: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_64RGBAHalf,
              !CVPixelBufferIsPlanar(source), CVPixelBufferGetWidth(source) == plan.source.raster.width,
              CVPixelBufferGetHeight(source) == plan.source.raster.height,
              CVPixelBufferGetBytesPerRow(source) >= plan.source.raster.width * 8,
              CVPixelBufferGetBytesPerRow(source) <= maximumSourceBytesPerRow,
              CVPixelBufferGetBytesPerRow(source).isMultiple(of: 8),
              CVPixelBufferGetDataSize(source) <= maximumSourceDataBytes else { throw ProResSpatialError.unsupportedInput("Source must match negotiated interleaved RGBAHalf geometry and source stride/data bound.") }
        func dictionary(_ key: CFString) throws -> [String: Any]? {
            guard let value = CVBufferCopyAttachment(source, key, nil) else { return nil }
            guard let result = value as? [String: Any] else { throw ProResSpatialError.unsupportedInput("Malformed source geometry attachment: \(key).") }
            return result
        }
        func number(_ d: [String: Any], _ k: CFString) throws -> Double {
            guard let value = (d[k as String] as? NSNumber)?.doubleValue, value.isFinite else { throw ProResSpatialError.unsupportedInput("Incomplete/nonfinite source geometry attachment.") }
            return value
        }
        if let d = try dictionary(kCVImageBufferPixelAspectRatioKey) {
            let h = try number(d,kCVImageBufferPixelAspectRatioHorizontalSpacingKey), v = try number(d,kCVImageBufferPixelAspectRatioVerticalSpacingKey)
            guard h > 0, h == v else { throw ProResSpatialError.unsupportedInput("Non-square source pixel aspect ratio is unsupported.") }
        }
        for key in [kCVImageBufferCleanApertureKey,kCVImageBufferPreferredCleanApertureKey] {
            if let d = try dictionary(key) {
                guard try number(d,kCVImageBufferCleanApertureWidthKey) == Double(plan.source.raster.width),
                      try number(d,kCVImageBufferCleanApertureHeightKey) == Double(plan.source.raster.height),
                      try number(d,kCVImageBufferCleanApertureHorizontalOffsetKey) == 0,
                      try number(d,kCVImageBufferCleanApertureVerticalOffsetKey) == 0 else { throw ProResSpatialError.unsupportedInput("Non-full or offset source clean aperture is unsupported.") }
            }
        }
        if let d = try dictionary(kCVImageBufferDisplayDimensionsKey) {
            guard try number(d,kCVImageBufferDisplayWidthKey) == Double(plan.source.raster.width),
                  try number(d,kCVImageBufferDisplayHeightKey) == Double(plan.source.raster.height) else { throw ProResSpatialError.unsupportedInput("Source display dimensions must match the declared square/full raster.") }
        }
        if let mode = CVBufferCopyAttachment(source,kCVImageBufferAlphaChannelModeKey,nil) as? String,
           mode == kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String { throw ProResSpatialError.unsupportedInput("Premultiplied input must be converted to the declared straight/opaque representation by its producer.") }
    }

    private func attachOutputMetadata(_ destination: CVPixelBuffer) {
        let width = plan.canvas.width, height = plan.canvas.height
        CVBufferSetAttachment(destination,kCVImageBufferCleanApertureKey,[kCVImageBufferCleanApertureWidthKey as String:width,kCVImageBufferCleanApertureHeightKey as String:height,kCVImageBufferCleanApertureHorizontalOffsetKey as String:0,kCVImageBufferCleanApertureVerticalOffsetKey as String:0] as CFDictionary,.shouldPropagate)
        CVBufferSetAttachment(destination,kCVImageBufferPixelAspectRatioKey,[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String:1,kCVImageBufferPixelAspectRatioVerticalSpacingKey as String:1] as CFDictionary,.shouldPropagate)
        CVBufferSetAttachment(destination,kCVImageBufferDisplayDimensionsKey,[kCVImageBufferDisplayWidthKey as String:width,kCVImageBufferDisplayHeightKey as String:height] as CFDictionary,.shouldPropagate)
        let p: CFString = color.primaries == .rec709 ? kCVImageBufferColorPrimaries_ITU_R_709_2 : color.primaries == .rec2020 ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_P3_D65
        CVBufferSetAttachment(destination,kCVImageBufferColorPrimariesKey,p,.shouldPropagate)
        CVBufferSetAttachment(destination,kCVImageBufferTransferFunctionKey,color.transfer == .pq ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(destination,kCVImageBufferYCbCrMatrixKey,color.primaries == .rec2020 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(destination,kCVImageBufferAlphaChannelModeKey,kCVImageBufferAlphaChannelMode_StraightAlpha,.shouldPropagate)
        // Geometry changes invalidate source picture-measured light metadata.
        // The encoder may add only the explicitly configured mastering display.
        CVBufferRemoveAttachment(destination,kCVImageBufferContentLightLevelInfoKey)
        CVBufferRemoveAttachment(destination,kCVImageBufferMasteringDisplayColorVolumeKey)
    }
    private static func allocate(_ pool: CVPixelBufferPool, capacity: Int) throws -> CVPixelBuffer? {
        var result: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,[kCVPixelBufferPoolAllocationThresholdKey as String:capacity] as CFDictionary,&result)
        if status == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard status == 0, let result else { throw ProResSpatialError.metal("Spatial output allocation failed: \(status).") }
        return result
    }
    private static func texture(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache) throws -> CVMetalTexture {
        var value: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,buffer,nil,.rgba16Float,CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer),0,&value)
        guard status == 0, let value, CVMetalTextureGetTexture(value) != nil else { throw ProResSpatialError.metal("Spatial RGBAHalf Metal binding failed: \(status).") }
        return value
    }
}
