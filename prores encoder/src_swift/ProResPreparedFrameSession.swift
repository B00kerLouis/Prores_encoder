// B00kerLouis. Framework-only opt-in high-precision external-color delivery.
import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox
import Darwin

/// RGB chromaticities. Every supported set uses the D65 white point.
public enum ProResPreparedPrimaries: String, Sendable {
    case rec709, rec2020, p3D65
}

public enum ProResPreparedWhitePoint: String, Sendable { case d65 }

/// The actual transfer already applied to the supplied RGB samples.
public enum ProResPreparedTransfer: String, Sendable {
    case bt709
    case pq
}

public enum ProResPreparedRange: String, Sendable { case full, video }

/// Describes pixels, not a requested grade. RGBAHalf uses full-domain RGB;
/// ProRes subsequently codes YCbCr in video range. PQ is absolute (1 = 10000
/// nits); BT.709 maps 1 to referenceWhiteNits. nominalPeakNits is mastering
/// metadata and never triggers tone mapping. The caller owns the declaration's
/// agreement with externally processed pixels.
public struct ProResPreparedColorDescriptor: Sendable, Equatable {
    public let primaries: ProResPreparedPrimaries
    public let whitePoint: ProResPreparedWhitePoint
    public let transfer: ProResPreparedTransfer
    public let range: ProResPreparedRange
    public let referenceWhiteNits: Float
    public let nominalPeakNits: Float
    /// Explicit mastering black level. Nil omits ST2086 rather than inventing
    /// a mastering display fact for externally prepared pixels.
    public let masteringMinimumNits: Float?

    public init(primaries: ProResPreparedPrimaries, whitePoint: ProResPreparedWhitePoint = .d65,
                transfer: ProResPreparedTransfer, range: ProResPreparedRange = .full,
                referenceWhiteNits: Float, nominalPeakNits: Float, masteringMinimumNits: Float? = nil) {
        self.primaries = primaries; self.whitePoint = whitePoint; self.transfer = transfer
        self.range = range; self.referenceWhiteNits = referenceWhiteNits
        self.nominalPeakNits = nominalPeakNits
        self.masteringMinimumNits = masteringMinimumNits
    }

    fileprivate func validate() throws {
        guard range == .full else { throw ProResPreparedFrameError.invalidConfiguration("RGBAHalf requires full-domain RGB, not video-range RGB words.") }
        guard referenceWhiteNits.isFinite, nominalPeakNits.isFinite,
              referenceWhiteNits > 0, nominalPeakNits >= referenceWhiteNits, nominalPeakNits <= 10000 else {
            throw ProResPreparedFrameError.invalidConfiguration("Luminance requires 0 < reference white <= nominal peak <= 10000 nits.")
        }
        if transfer == .bt709, nominalPeakNits != referenceWhiteNits {
            throw ProResPreparedFrameError.invalidConfiguration("BT.709 normalized RGB requires nominal peak equal to reference white; extended SDR is not negotiated.")
        }
        if let minimum = masteringMinimumNits {
            guard transfer == .pq, minimum.isFinite, minimum >= 0, minimum < nominalPeakNits else {
                throw ProResPreparedFrameError.invalidConfiguration("Explicit mastering minimum requires PQ and 0 <= minimum < nominal peak.")
            }
        }
    }

    fileprivate var colorSpace: SourceColorSpace {
        let p: String
        let m: String
        switch primaries {
        case .rec709: p = kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String; m = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
        case .rec2020: p = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String; m = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String
        case .p3D65: p = kCMFormatDescriptionColorPrimaries_P3_D65 as String; m = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
        }
        return SourceColorSpace(primaries: p,
            transfer: transfer == .pq ? kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String : kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
            matrix: m, masteringDisplayColorVolume: masteringDisplay, contentLightLevelInfo: nil,
            mxfPrimaries: nil, mxfTransfer: nil, mxfMatrix: nil)
    }

    fileprivate var masteringDisplay: Data? {
        guard transfer == .pq, let minimum = masteringMinimumNits else { return nil }
        let coordinates: [UInt16]
        switch primaries {
        case .rec709: coordinates = [15000,30000,7500,3000,32000,16500,15635,16450]
        case .rec2020: coordinates = [8500,39850,6550,2300,35400,14600,15635,16450]
        case .p3D65: coordinates = [13250,34500,7500,3000,34000,16000,15635,16450]
        }
        var bytes = Data()
        for v in coordinates { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 255)) }
        for v in [UInt32((nominalPeakNits * 10000).rounded()), UInt32((minimum * 10000).rounded())] {
            for shift in [24,16,8,0] { bytes.append(UInt8((v >> shift) & 255)) }
        }
        return bytes
    }

    fileprivate func attach(to buffer: CVPixelBuffer) {
        let c = colorSpace
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, c.primaries! as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, c.transfer! as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, c.matrix! as CFString, .shouldPropagate)
        if let masteringDisplay { CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, masteringDisplay as CFData, .shouldPropagate) }
        else { CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey) }
    }
}

public enum ProResPreparedCodec: String, Sendable, CaseIterable {
    case proxy, proRes422LT, proRes422, proRes422HQ, proRes4444, proRes4444XQ
    fileprivate var codecType: CMVideoCodecType {
        switch self {
        case .proxy: return kCMVideoCodecType_AppleProRes422Proxy
        case .proRes422LT: return kCMVideoCodecType_AppleProRes422LT
        case .proRes422: return kCMVideoCodecType_AppleProRes422
        case .proRes422HQ: return kCMVideoCodecType_AppleProRes422HQ
        case .proRes4444: return kCMVideoCodecType_AppleProRes4444
        case .proRes4444XQ: return 0x61703478
        }
    }
}

/// Optional parameter-only transform. Rows multiply absolute linear RGB nits
/// after input EOTF and before output OETF. Coefficients include any desired
/// gamut conversion; there is no implicit gamut conversion/adaptation, tone
/// mapping, or dependency on an external color-management library. Negative
/// results clip to zero; BT.709 clips at reference white and PQ at 10000 nits.
public struct ProResExternalRGBMatrix: Sendable {
    public let inputColor: ProResPreparedColorDescriptor
    public let row0: SIMD3<Float>
    public let row1: SIMD3<Float>
    public let row2: SIMD3<Float>
    public init(inputColor: ProResPreparedColorDescriptor, row0: SIMD3<Float>, row1: SIMD3<Float>, row2: SIMD3<Float>) {
        self.inputColor = inputColor; self.row0 = row0; self.row1 = row1; self.row2 = row2
    }
}

/// Register before the producer commits its command buffer. Metal completion
/// handlers may not be added after commit; this token safely remembers both
/// already-completed and in-flight work without adding a late Metal handler.
private final class PreparedProducerCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var observers: [@Sendable (Error?) -> Void] = []
    func complete(_ error: Error?) {
        lock.lock()
        result = error.map { .failure($0) } ?? .success(())
        let pending = observers; observers.removeAll(); lock.unlock()
        for observer in pending { observer(error) }
    }
    func observe(_ observer: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        if let result {
            lock.unlock()
            switch result { case .success: observer(nil); case .failure(let error): observer(error) }
        } else { observers.append(observer); lock.unlock() }
    }
}

public final class ProResPreparedMetalProducer: @unchecked Sendable {
    private let command: MTLCommandBuffer
    private let completion = PreparedProducerCompletion()
    public let deviceRegistryID: UInt64
    public init(commandBuffer: MTLCommandBuffer) throws {
        guard commandBuffer.status == .notEnqueued || commandBuffer.status == .enqueued else {
            throw ProResPreparedFrameError.invalidFrame("Register the producer completion token before committing its command buffer.")
        }
        command = commandBuffer; deviceRegistryID = commandBuffer.commandQueue.device.registryID
        let completion = completion
        commandBuffer.addCompletedHandler { command in
            let error: Error? = command.status == .completed ? nil : ProResPreparedFrameError.gpu(command.error?.localizedDescription ?? "External Metal producer failed.")
            completion.complete(error)
        }
    }
    fileprivate func validate(device: MTLDevice) throws {
        guard deviceRegistryID == device.registryID else { throw ProResPreparedFrameError.invalidFrame("The producer command buffer uses another Metal device.") }
        guard command.status == .committed || command.status == .scheduled || command.status == .completed else {
            throw ProResPreparedFrameError.invalidFrame("The registered producer command buffer must already be committed and successful.")
        }
    }
    fileprivate func observe(_ observer: @escaping @Sendable (Error?) -> Void) { completion.observe(observer) }
    fileprivate var gpuSeconds: Double { max(0, command.gpuEndTime - command.gpuStartTime) }
}

/// External GPU work must already be committed on this session's Metal device.
/// The pre-registered producer token observes completion asynchronously.
/// `.completed` is the caller's explicit guarantee that all CPU/GPU writes are
/// complete and visible. Neither case transfers command-queue ownership.
public enum ProResPreparedFrameReadiness: @unchecked Sendable {
    case completed
    case metal(ProResPreparedMetalProducer)
}

public enum ProResPreparedFrameError: LocalizedError {
    case invalidConfiguration(String), invalidFrame(String), gpu(String), encoding(String)
    case bufferPoolExhausted
    case closed
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let s), .invalidFrame(let s), .gpu(let s), .encoding(let s): return s
        case .bufferPoolExhausted: return "The bounded RGBAHalf pool is exhausted. Release a completed frame before requesting another."
        case .closed: return "The prepared-frame session is closed."
        }
    }
}

/// Completion of a successful append means the input may be modified/reused.
/// On cancellation it still waits for outstanding producer/transform GPU work.
public final class ProResPreparedFrameSubmission: @unchecked Sendable {
    public let presentationTime: CMTime
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    fileprivate init(pts: CMTime) { presentationTime = pts }
    public func waitUntilReleased() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    fileprivate func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let pending = waiters; waiters.removeAll(); lock.unlock()
        for waiter in pending { waiter.resume(with: result) }
    }
}

public struct ProResPreparedFrameStatistics: Sendable {
    public let acceptedFrames: Int64
    public let writtenFrames: Int64
    public let retainedFrames: Int
    public let peakRetainedFrames: Int
    /// Sums of Metal command GPU intervals, excluding CPU setup and VT's
    /// internal work. A producer interval can include its unrelated commands.
    public let matrixGPUSeconds: Double
    public let externalProducerGPUSeconds: Double
}

private final class PreparedFrameRecord: @unchecked Sendable {
    let index: Int64
    let source: CVPixelBuffer
    let receipt: ProResPreparedFrameSubmission
    var gpuPending = true
    var ready = false
    var output: CVPixelBuffer?
    var producer: ProResPreparedMetalProducer?
    init(index: Int64, source: CVPixelBuffer, receipt: ProResPreparedFrameSubmission) {
        self.index = index; self.source = source; self.receipt = receipt
    }
}

/// Framework-only, explicitly selected high-precision streaming encoder.
/// No existing file/CLI/AMA frame path calls this class. Setup validates and
/// allocates resources once. tryAppend never waits for GPU/codec capacity and
/// returns nil for backpressure; callers await a prior receipt before retrying.
/// Frames are CFR, start at zero and use exact rational PTS. Inputs must remain
/// immutable until their receipt resolves. Retention is bounded by capacity.
/// IOSurface/Metal compatibility does not promise absence of driver/codec copies.
public final class ProResPreparedFrameSession: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let frameDuration: CMTime
    public let device: MTLDevice
    public let color: ProResPreparedColorDescriptor
    public let inputColor: ProResPreparedColorDescriptor
    public let capacity: Int
    /// The only negotiated layout: interleaved RGBA little-endian IEEE half,
    /// 16 bits/component; byte stride is supplied by CVPixelBuffer, >= width*8.
    public let pixelFormat: OSType = kCVPixelFormatType_64RGBAHalf
    public let codedRange: ProResPreparedRange = .video
    /// True when ProRes does not advertise MaxFrameDelayCount. The facade
    /// drains the codec at bounded batch saturation, never waits for a GPU
    /// command per frame, and never assumes an ignored delay property worked.
    public let usesBackpressureCodecDrain: Bool
    private let pool: CVPixelBufferPool
    private let textureCache: CVMetalTextureCache
    private let compression: ProResSession
    private let transform: PreparedMatrixPipeline?
    private let transaction: DirectOutputTransaction
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.proresencoder.prepared.frames", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var accepting = true
    private var cancelRequested = false
    private var terminalError: Error?
    private var committed = false
    private var nextIndex: Int64 = 0
    private var retainedCount = 0
    private var peakRetained = 0
    private var writtenCount: Int64 = 0
    private var matrixGPUSeconds = 0.0
    private var producerGPUSeconds = 0.0
    // The remaining state belongs exclusively to queue.
    private var records: [Int64: PreparedFrameRecord] = [:]
    private var nextSubmit: Int64 = 0
    private var finishWaiter: CheckedContinuation<Void, Error>?
    private var finishRequested = false
    private var flushed = false
    private var finalizing = false

    /// Supports ProRes/MOV only. Other existing output formats are rejected
    /// here, before any frame or final file can be changed. No audio/DV replay
    /// is hidden behind this entry point. For externally prepared pixels omit
    /// matrix; supplying matrix explicitly selects the separate Metal path.
    public init(outputURL: URL, width: Int, height: Int,
                frameRateNumerator: Int32, frameRateDenominator: Int32,
                codec: ProResPreparedCodec = .proRes4444XQ, container: ProResOutputFormat = .mov,
                color: ProResPreparedColorDescriptor, matrix: ProResExternalRGBMatrix? = nil,
                capacity: Int = 4, device: MTLDevice) throws {
        guard outputURL.isFileURL, container == .mov, outputURL.pathExtension.lowercased() == "mov",
              width > 0, height > 0, width <= 16384, height <= 16384,
              width.isMultiple(of: 2), height.isMultiple(of: 2),
              frameRateNumerator > 0, frameRateDenominator > 0,
              Double(frameRateNumerator) / Double(frameRateDenominator) <= 240,
              (2...16).contains(capacity),
              Int64(width) * Int64(height) * 8 * Int64(capacity) <= 1_073_741_824 else {
            throw ProResPreparedFrameError.invalidConfiguration("Prepared frames require a file .mov URL, MOV/ProRes, even raster <= 16384, 0 < fps <= 240, and capacity 2...16.")
        }
        try color.validate(); try matrix?.inputColor.validate()
        if let matrix {
            guard [matrix.row0, matrix.row1, matrix.row2].allSatisfy({ row in
                row.x.isFinite && row.y.isFinite && row.z.isFinite &&
                (abs(Double(row.x)) + abs(Double(row.y)) + abs(Double(row.z))) * 10000 < Double(Float.greatestFiniteMagnitude)
            }) else {
                throw ProResPreparedFrameError.invalidConfiguration("Matrix rows must be finite and cannot overflow Float in the supported 10000-nit domain.")
            }
        }
        self.width = width; self.height = height; self.device = device; self.color = color
        self.inputColor = matrix?.inputColor ?? color; self.capacity = capacity
        frameDuration = CMTime(value: Int64(frameRateDenominator), timescale: frameRateNumerator)
        pool = try PreparedMatrixPipeline.makePool(width: width, height: height, capacity: capacity)
        textureCache = try PreparedMatrixPipeline.makeCache(device)
        transform = try matrix.map { try PreparedMatrixPipeline(device: device, width: width, height: height, capacity: capacity, matrix: $0, outputColor: color) }
        // Verify texture compatibility during setup even when there is no matrix.
        try PreparedMatrixPipeline.validatePool(pool, device: device, width: width, height: height, capacity: capacity)
        compression = try ProResSession(width: width, height: height, codecType: codec.codecType,
            fpsHint: max(1, Int((Double(frameRateNumerator) / Double(frameRateDenominator)).rounded())),
            colorSpace: color.colorSpace, sourcePixelFormat: kCVPixelFormatType_64RGBAHalf, maximumFrameDelay: capacity - 1)
        usesBackpressureCodecDrain = try !compression.configurePreparedFrameStreaming(maximumFrameDelay: capacity - 1)
        transaction = DirectOutputTransaction(finalURL: outputURL)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: transaction.workingURL, fileType: .mov)
        writer.movieTimeScale = frameRateNumerator
        compression.setEncodedSampleHandler { [weak self] sample in
            guard let self else { return }
            self.queue.async { self.appendCompressed(sample.buf) }
        }
    }

    /// Optional bounded producer pool. External CVPixelBuffers are also
    /// accepted if they meet the same format, dimensions and Metal contract.
    public func makePixelBuffer() throws -> CVPixelBuffer {
        lock.lock(); let open = accepting && !cancelRequested; lock.unlock()
        guard open else { throw ProResPreparedFrameError.closed }
        return try PreparedMatrixPipeline.allocate(pool, capacity: capacity)
    }

    public var statistics: ProResPreparedFrameStatistics {
        lock.lock(); defer { lock.unlock() }
        return ProResPreparedFrameStatistics(acceptedFrames: nextIndex, writtenFrames: writtenCount,
            retainedFrames: retainedCount, peakRetainedFrames: peakRetained,
            matrixGPUSeconds: matrixGPUSeconds, externalProducerGPUSeconds: producerGPUSeconds)
    }

    /// Returns nil without retaining/consuming the frame when capacity is full.
    /// A submitted Metal command buffer must use device.registryID. Work from
    /// different producer queues is permitted and drained in accepted PTS order.
    public func tryAppend(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime,
                          readiness: ProResPreparedFrameReadiness) throws -> ProResPreparedFrameSubmission? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == pixelFormat,
              CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height,
              !CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetBytesPerRow(pixelBuffer) >= width * 8,
              CVPixelBufferGetBytesPerRow(pixelBuffer).isMultiple(of: 8) else {
            throw ProResPreparedFrameError.invalidFrame("The frame must match the negotiated interleaved RGBAHalf raster/stride; no 8-bit fallback is available.")
        }
        if case .metal(let producer) = readiness { try producer.validate(device: device) }
        try autoreleasepool { _ = try PreparedMatrixPipeline.texture(pixelBuffer, cache: textureCache, width: width, height: height) }
        lock.lock()
        guard accepting, !cancelRequested, terminalError == nil else { let error = terminalError ?? ProResPreparedFrameError.closed; lock.unlock(); throw error }
        guard retainedCount < capacity else { lock.unlock(); return nil }
        guard nextIndex < Int64.max / frameDuration.value,
              CMTIME_IS_NUMERIC(presentationTime), presentationTime.epoch == 0,
              CMTimeCompare(presentationTime, CMTime(value: nextIndex * frameDuration.value, timescale: frameDuration.timescale)) == 0 else {
            lock.unlock(); throw ProResPreparedFrameError.invalidFrame("PTS must be consecutive zero-based CFR timestamps at the negotiated exact rational rate.")
        }
        let record = PreparedFrameRecord(index: nextIndex, source: pixelBuffer,
            receipt: ProResPreparedFrameSubmission(pts: presentationTime))
        nextIndex += 1; retainedCount += 1; peakRetained = max(peakRetained, retainedCount)
        // Enqueue registration while holding the admission lock, so finish and
        // concurrent producers cannot overtake an accepted frame.
        queue.async { self.records[record.index] = record }
        lock.unlock()
        switch readiness {
        case .completed: queue.async { self.producerCompleted(record, error: nil) }
        case .metal(let producer):
            record.producer = producer
            producer.observe { [self, record] error in
                queue.async { self.producerCompleted(record, error: error) }
            }
        }
        return record.receipt
    }

    /// Flushes only compressed samples, writes truthful static HDR metadata,
    /// then atomically replaces the final file on its own volume. It never
    /// decodes/replays a carrier. Await this off the GUI's synchronous path.
    public func finish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if committed { lock.unlock(); continuation.resume(); return }
            if let terminalError { lock.unlock(); continuation.resume(throwing: terminalError); return }
            guard accepting else { lock.unlock(); continuation.resume(throwing: ProResPreparedFrameError.closed); return }
            accepting = false
            queue.async {
                self.finishRequested = true; self.finishWaiter = continuation
                self.advance()
            }
            lock.unlock()
        }
    }

    /// Immediately stops admission. In-flight producer GPU buffers remain
    /// retained until their completion handlers run; their receipts then fail.
    public func cancel() {
        lock.lock()
        guard !committed else { lock.unlock(); return }
        cancelRequested = true; accepting = false
        queue.async { self.fail(CancellationError()) }
        lock.unlock()
    }

    private var failure: Error? {
        lock.lock(); defer { lock.unlock() }
        return terminalError ?? (cancelRequested ? CancellationError() : nil)
    }

    private func producerCompleted(_ record: PreparedFrameRecord, error: Error?) {
        record.gpuPending = false
        if let producer = record.producer { lock.lock(); producerGPUSeconds += producer.gpuSeconds; lock.unlock() }
        record.producer = nil
        if let error { fail(error) }
        if let failure { release(record, result: .failure(failure)); return }
        if let transform {
            do {
                record.gpuPending = true
                let work = try transform.encode(record.source)
                record.output = work.buffer
                let resources = PreparedMatrixTextures(work.textures)
                work.command.addCompletedHandler { [self, record, resources] command in
                    let error: Error? = command.status == .completed ? nil : ProResPreparedFrameError.gpu(command.error?.localizedDescription ?? "External matrix Metal work failed.")
                    let gpuSeconds = max(0, command.gpuEndTime - command.gpuStartTime)
                    queue.async {
                        _ = resources // Keep wrappers, without a command -> work -> command cycle.
                        record.gpuPending = false
                        self.lock.lock(); self.matrixGPUSeconds += gpuSeconds; self.lock.unlock()
                        if let error { self.fail(error) }
                        if let failure = self.failure { self.release(record, result: .failure(failure)); return }
                        record.ready = true; self.advance()
                    }
                }
                work.command.commit()
            } catch { record.gpuPending = false; fail(error) }
        } else { record.output = record.source; record.ready = true; advance() }
    }

    private func advance() {
        if let failure { fail(failure); return }
        while let record = records[nextSubmit], record.ready {
            if let failure { fail(failure); return }
            guard let picture = record.output else { fail(ProResPreparedFrameError.encoding("A prepared frame has no output buffer.")); return }
            color.attach(to: picture)
            guard compression.submit(pixelBuffer: picture, pts: record.receipt.presentationTime, duration: frameDuration) else {
                fail(compression.callbackError ?? ProResPreparedFrameError.encoding("VideoToolbox rejected a prepared RGBAHalf frame.")); return
            }
            nextSubmit += 1
        }
        lock.lock(); let admitted = nextIndex; let saturated = retainedCount == capacity; lock.unlock()
        if usesBackpressureCodecDrain, !finishRequested, saturated, nextSubmit == admitted {
            do { try compression.completeFramesChecked() } catch { fail(error); return }
        }
        if finishRequested, !flushed {
            lock.lock(); let count = nextIndex; lock.unlock()
            if nextSubmit == count {
                guard count > 0 else { fail(ProResPreparedFrameError.encoding("No prepared video frames were submitted.")); return }
                flushed = true
                do { try compression.completeFramesChecked() } catch { fail(error); return }
            }
        }
        if flushed, records.isEmpty, !finalizing { finalize() }
    }

    private func appendCompressed(_ sample: CMSampleBuffer) {
        if let failure { fail(failure); return }
        do {
            guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
                  let description = CMSampleBufferGetFormatDescription(sample) else { throw ProResPreparedFrameError.encoding("An encoded frame has no valid format description.") }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            lock.lock(); let expected = writtenCount; lock.unlock()
            guard let record = records[expected], CMTimeCompare(pts, record.receipt.presentationTime) == 0 else { throw ProResPreparedFrameError.encoding("ProRes output is missing, duplicated or out of presentation order.") }
            if input == nil {
                let c = color.colorSpace
                for (key, value) in [(kCMFormatDescriptionExtension_ColorPrimaries, c.primaries!), (kCMFormatDescriptionExtension_TransferFunction, c.transfer!), (kCMFormatDescriptionExtension_YCbCrMatrix, c.matrix!)] {
                    guard CMFormatDescriptionGetExtension(description, extensionKey: key) as? String == value else { throw ProResPreparedFrameError.encoding("VideoToolbox did not preserve the negotiated color declaration (\(key)).") }
                }
                let track = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
                track.expectsMediaDataInRealTime = false; track.mediaTimeScale = frameDuration.timescale
                guard writer.canAdd(track) else { throw ProResPreparedFrameError.encoding("MOV rejected the prepared ProRes format.") }
                writer.add(track)
                guard writer.startWriting() else { throw writer.error ?? ProResPreparedFrameError.encoding("The prepared MOV writer did not start.") }
                writer.startSession(atSourceTime: .zero); input = track
            }
            guard let input else { throw ProResPreparedFrameError.encoding("The prepared video track is missing.") }
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while !input.isReadyForMoreMediaData {
                if let failure { throw failure }
                guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else { throw writer.error ?? ProResPreparedFrameError.encoding("MOV stopped accepting prepared samples.") }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.append(sample) else { throw writer.error ?? ProResPreparedFrameError.encoding("MOV rejected an encoded prepared frame.") }
            lock.lock(); writtenCount += 1; lock.unlock()
            release(record, result: .success(())); advance()
        } catch { fail(error) }
    }

    private func release(_ record: PreparedFrameRecord, result: Result<Void, Error>) {
        guard records.removeValue(forKey: record.index) != nil else { return }
        lock.lock(); retainedCount -= 1; lock.unlock()
        record.receipt.resolve(result)
    }

    private func fail(_ error: Error) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        let actual = terminalError!; accepting = false
        lock.unlock()
        compression.invalidate(); writer.cancelWriting()
        for record in Array(records.values) where !record.gpuPending { release(record, result: .failure(actual)) }
        try? FileManager.default.removeItem(at: transaction.workingURL)
        finishWaiter?.resume(throwing: actual); finishWaiter = nil
    }

    private func finalize() {
        guard let input else { fail(ProResPreparedFrameError.encoding("No encoded video track is available.")); return }
        finalizing = true; input.markAsFinished()
        lock.lock(); let frames = nextIndex; lock.unlock()
        writer.endSession(atSourceTime: CMTime(value: frames * frameDuration.value, timescale: frameDuration.timescale))
        writer.finishWriting { [self] in
            queue.async {
                do {
                    if let failure = self.failure { throw failure }
                    guard self.writer.status == .completed else { throw self.writer.error ?? ProResPreparedFrameError.encoding("Prepared MOV did not finish.") }
                    if let mastering = self.color.masteringDisplay {
                        try patchProResStaticHDRSampleEntryBoxes(in: self.transaction.workingURL,
                            masteringDisplayColorVolume: mastering, contentLightLevelInfo: nil, inPlacePrivateCarrier: true)
                    }
                    // Cancellation and commit have a single linearization point.
                    self.lock.lock()
                    if self.cancelRequested { self.lock.unlock(); throw CancellationError() }
                    let status = rename(self.transaction.workingURL.path, self.transaction.finalURL.path)
                    if status == 0 { self.committed = true }
                    self.lock.unlock()
                    guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    self.compression.invalidate()
                    self.finishWaiter?.resume(); self.finishWaiter = nil
                } catch { self.fail(error) }
            }
        }
    }

    deinit {
        compression.invalidate()
        if !committed {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: transaction.workingURL)
            for record in records.values { record.receipt.resolve(.failure(CancellationError())) }
        }
    }
}

private struct PreparedMatrixUniforms {
    var row0: SIMD4<Float>
    var row1: SIMD4<Float>
    var row2: SIMD4<Float>
    var inputWhite: Float
    var outputWhite: Float
    var inputPQ: UInt32
    var outputPQ: UInt32
}

private final class PreparedMatrixGPUWork: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let command: MTLCommandBuffer
    let textures: [CVMetalTexture]
    init(buffer: CVPixelBuffer, command: MTLCommandBuffer, textures: [CVMetalTexture]) {
        self.buffer = buffer; self.command = command; self.textures = textures
    }
}

private final class PreparedMatrixTextures: @unchecked Sendable {
    let textures: [CVMetalTexture]
    init(_ textures: [CVMetalTexture]) { self.textures = textures }
}

private final class PreparedMatrixResourceToken: NSObject {}

/// Separate from the existing MetalColorPipeline: no old uniforms, shaders or
/// per-frame behavior are changed by the opt-in absolute-linear matrix path.
private final class PreparedMatrixPipeline {
    private let pool: CVPixelBufferPool
    private let cache: CVMetalTextureCache
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let width: Int, height: Int, capacity: Int
    private var uniforms: PreparedMatrixUniforms
    init(device: MTLDevice, width: Int, height: Int, capacity: Int,
         matrix: ProResExternalRGBMatrix, outputColor: ProResPreparedColorDescriptor) throws {
        self.width = width; self.height = height; self.capacity = capacity
        guard let queue = device.makeCommandQueue(),
              let library = EmbeddedMetalLibrary.load(device: device, bundle: Bundle(for: PreparedMatrixResourceToken.self), requiredFunctions: ["prepared_absolute_rgb_matrix"]),
              let function = library.makeFunction(name: "prepared_absolute_rgb_matrix") else { throw ProResPreparedFrameError.gpu("The independent prepared-frame Metal kernel is unavailable.") }
        self.queue = queue; pipeline = try device.makeComputePipelineState(function: function)
        cache = try Self.makeCache(device)
        pool = try Self.makePool(width: width, height: height, capacity: capacity)
        try Self.validatePool(pool, device: device, width: width, height: height, capacity: capacity)
        uniforms = PreparedMatrixUniforms(row0: SIMD4(matrix.row0, 0), row1: SIMD4(matrix.row1, 0), row2: SIMD4(matrix.row2, 0),
            inputWhite: matrix.inputColor.referenceWhiteNits, outputWhite: outputColor.referenceWhiteNits,
            inputPQ: matrix.inputColor.transfer == .pq ? 1 : 0, outputPQ: outputColor.transfer == .pq ? 1 : 0)
    }
    static func makeCache(_ device: MTLDevice) throws -> CVMetalTextureCache {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw ProResPreparedFrameError.gpu("CVMetalTextureCache setup failed: \(status).") }
        return cache
    }
    static func makePool(width: Int, height: Int, capacity: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: capacity] as CFDictionary,
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
             kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
             kCVPixelBufferMetalCompatibilityKey as String: true,
             kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw ProResPreparedFrameError.gpu("RGBAHalf pool setup failed: \(status).") }
        return pool
    }
    static func allocate(_ pool: CVPixelBufferPool, capacity: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: capacity] as CFDictionary, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold { throw ProResPreparedFrameError.bufferPoolExhausted }
        guard status == kCVReturnSuccess, let buffer else { throw ProResPreparedFrameError.gpu("RGBAHalf pool allocation failed: \(status).") }
        return buffer
    }
    static func validatePool(_ pool: CVPixelBufferPool, device: MTLDevice, width: Int, height: Int, capacity: Int) throws {
        try autoreleasepool {
            let cache = try makeCache(device)
            var warm: [CVPixelBuffer] = []
            for _ in 0..<capacity { warm.append(try allocate(pool, capacity: capacity)) }
            _ = try texture(warm[0], cache: cache, width: width, height: height)
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
    static func texture(_ buffer: CVPixelBuffer, cache: CVMetalTextureCache, width: Int, height: Int) throws -> CVMetalTexture {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .rgba16Float, width, height, 0, &texture)
        guard status == kCVReturnSuccess, let texture, CVMetalTextureGetTexture(texture) != nil else { throw ProResPreparedFrameError.gpu("RGBAHalf Metal texture binding failed: \(status).") }
        return texture
    }
    func encode(_ source: CVPixelBuffer) throws -> PreparedMatrixGPUWork {
        let destination = try Self.allocate(pool, capacity: capacity)
        let a = try Self.texture(source, cache: cache, width: width, height: height)
        let b = try Self.texture(destination, cache: cache, width: width, height: height)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw ProResPreparedFrameError.gpu("Prepared matrix could not create Metal work.") }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(CVMetalTextureGetTexture(a), index: 0); encoder.setTexture(CVMetalTextureGetTexture(b), index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<PreparedMatrixUniforms>.stride, index: 0)
        let w = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
        encoder.endEncoding()
        return PreparedMatrixGPUWork(buffer: destination, command: command, textures: [a,b])
    }
}
