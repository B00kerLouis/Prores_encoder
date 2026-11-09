// B00kerLouis. SDK-free, opt-in external-color contracts and timing driver.
import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import ProResEncoderFramework

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private final class TextureLifetime: @unchecked Sendable {
    let texture: CVMetalTexture
    init(_ texture: CVMetalTexture) { self.texture = texture }
}

@main struct PreparedFrameContracts {
    static let sdr = ProResPreparedColorDescriptor(primaries: .rec709, transfer: .bt709, referenceWhiteNits: 100, nominalPeakNits: 100)
    static let hdr = ProResPreparedColorDescriptor(primaries: .rec2020, transfer: .pq, referenceWhiteNits: 203, nominalPeakNits: 1000, masteringMinimumNits: 0.005)
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "PreparedContracts", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS \(message)")
    }
    static func reject(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { print("PASS reject \(name): \(error.localizedDescription)"); return }
        throw NSError(domain: "PreparedContracts", code: 2, userInfo: [NSLocalizedDescriptionKey: "Accepted invalid \(name)"])
    }
    static func pq(_ n: Double) -> Double {
        let p = pow(max(n,0)/10000,2610.0/16384)
        return pow((3424.0/4096+2413.0/128*p)/(1+2392.0/128*p),2523.0/32)
    }
    static func decode709(_ v: Double) -> Double { v < 0.081 ? v / 4.5 : pow((v+0.099)/1.099,1/0.45) }
    static func encode709(_ v: Double) -> Double { v < 0.018 ? v*4.5 : 1.099*pow(v,0.45)-0.099 }
    static func fill(_ frame: CVPixelBuffer, pqInput: Bool = false) {
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let p = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: Float16.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)/2
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        for y in 0..<height { for x in 0..<width {
            let t = Double(x)/Double(width-1)
            let value = Float16(pqInput ? pq(t*1000) : t)
            for c in 0..<3 { p[y*stride+x*4+c] = value }
            p[y*stride+x*4+3] = 1
        } }
    }
    static func externalBuffer(width: Int, height: Int, format: OSType = kCVPixelFormatType_64RGBAHalf, metal: Bool = true) throws -> CVPixelBuffer {
        var frame: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,width,height,format,
            [kCVPixelBufferMetalCompatibilityKey as String:metal,kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&frame)
        guard status == 0, let frame else { throw NSError(domain:"CV",code:Int(status)) }
        return frame
    }
    static func encodeProducer(_ command: MTLCommandBuffer, frame: CVPixelBuffer, device: MTLDevice) throws {
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void producer(texture2d<half,access::write> out [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
            if(p.x>=out.get_width() || p.y>=out.get_height()) return;
            half v=half(float(p.x)/float(out.get_width()-1)); out.write(half4(v,v,v,1),p);
        }
        """
        let library = try device.makeLibrary(source:shader,options:nil)
        let pipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"producer")!)
        var cache: CVMetalTextureCache?, texture: CVMetalTexture?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,device,nil,&cache) == 0,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache!,frame,nil,.rgba16Float,CVPixelBufferGetWidth(frame),CVPixelBufferGetHeight(frame),0,&texture) == 0,
              let texture, let encoder = command.makeComputeCommandEncoder() else { throw NSError(domain:"ProducerTexture",code:1) }
        encoder.setComputePipelineState(pipeline); encoder.setTexture(CVMetalTextureGetTexture(texture),index:0)
        encoder.dispatchThreads(MTLSize(width:CVPixelBufferGetWidth(frame),height:CVPixelBufferGetHeight(frame),depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1)); encoder.endEncoding()
        let lifetime = TextureLifetime(texture)
        command.addCompletedHandler { [lifetime] _ in _ = lifetime }
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath:executable); p.arguments = arguments
        let stdout = Pipe(), stderr = Pipe(); p.standardOutput = stdout; p.standardError = stderr
        try p.run(); let data = stdout.fileHandleForReading.readDataToEndOfFile(); let error = stderr.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain:"Process",code:Int(p.terminationStatus),userInfo:[NSLocalizedDescriptionKey:String(decoding:error,as:UTF8.self)]) }
        return data
    }
    static func inspect(_ url: URL, frames: Int, pq: Bool, width: Int) throws -> [String:Any] {
        let data = try run("/opt/homebrew/bin/ffprobe",["-v","error","-show_streams","-show_packets","-of","json",url.path])
        let root = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let stream = (root["streams"] as! [[String:Any]])[0]
        let packets = root["packets"] as! [[String:Any]]
        try require(stream["codec_name"] as? String == "prores", "actual ProRes codec \(url.lastPathComponent)")
        try require(stream["color_primaries"] as? String == (pq ? "bt2020":"bt709"), "actual primaries \(url.lastPathComponent)")
        try require(stream["color_transfer"] as? String == (pq ? "smpte2084":"bt709"), "actual transfer \(url.lastPathComponent)")
        try require(stream["color_range"] as? String == "tv", "coded video range \(url.lastPathComponent)")
        try require(stream["width"] as? Int == width && packets.count == frames, "frame coverage \(url.lastPathComponent)")
        for (i,packet) in packets.enumerated() {
            try require((packet["pts"] as? Int) == i*1001 && (packet["duration"] as? Int) == 1001,"exact rational PTS \(url.lastPathComponent):\(i)")
        }
        return root
    }
    static func appendFrames(_ session: ProResPreparedFrameSession, buffer: CVPixelBuffer, count: Int) async throws {
        var receipts: [ProResPreparedFrameSubmission] = []
        for i in 0..<count {
            while true {
                if let receipt = try session.tryAppend(buffer,presentationTime:CMTime(value:Int64(i)*session.frameDuration.value,timescale:session.frameDuration.timescale),readiness:.completed) {
                    receipts.append(receipt); break
                }
                guard !receipts.isEmpty else { throw NSError(domain:"Backpressure",code:1) }
                try await receipts.removeFirst().waitUntilReleased()
            }
        }
        try await session.finish()
        for receipt in receipts { try await receipt.waitUntilReleased() }
    }
    static func contracts(_ directory: URL, device: MTLDevice) async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let output = directory.appendingPathComponent("validation.mov")
        func session(color: ProResPreparedColorDescriptor = sdr, matrix: ProResExternalRGBMatrix? = nil, capacity: Int = 2, container: ProResOutputFormat = .mov) throws -> ProResPreparedFrameSession {
            try ProResPreparedFrameSession(outputURL:output,width:64,height:32,frameRateNumerator:30000,frameRateDenominator:1001,container:container,color:color,matrix:matrix,capacity:capacity,device:device)
        }
        try reject("MP4") { _ = try session(container:.mp4) }
        try reject("invalid luminance") { _ = try session(color:ProResPreparedColorDescriptor(primaries:.rec709,transfer:.bt709,referenceWhiteNits:.nan,nominalPeakNits:100)) }
        try reject("unnegotiated RGB range") { _ = try session(color:ProResPreparedColorDescriptor(primaries:.rec709,transfer:.bt709,range:.video,referenceWhiteNits:100,nominalPeakNits:100)) }
        try reject("invented SDR peak") { _ = try session(color:ProResPreparedColorDescriptor(primaries:.rec709,transfer:.bt709,referenceWhiteNits:100,nominalPeakNits:1000)) }
        try reject("invalid mastering min") { _ = try session(color:ProResPreparedColorDescriptor(primaries:.rec2020,transfer:.pq,referenceWhiteNits:203,nominalPeakNits:1000,masteringMinimumNits:1000)) }
        try reject("nonfinite matrix") { _ = try session(matrix:ProResExternalRGBMatrix(inputColor:sdr,row0:[.nan,0,0],row1:[0,1,0],row2:[0,0,1])) }
        try reject("overflow matrix") { _ = try session(matrix:ProResExternalRGBMatrix(inputColor:sdr,row0:[.greatestFiniteMagnitude,0,0],row1:[0,1,0],row2:[0,0,1])) }
        let validation = try session()
        print("PHASE validation session initialized")
        let frame = try validation.makePixelBuffer(); fill(frame)
        print("PHASE first bounded pool buffer allocated")
        let second = try validation.makePixelBuffer()
        print("PHASE second bounded pool buffer allocated")
        try reject("pool allocation bound") { _ = try validation.makePixelBuffer() }
        try reject("8-bit input") { _ = try validation.tryAppend(externalBuffer(width:64,height:32,format:kCVPixelFormatType_32BGRA),presentationTime:.zero,readiness:.completed) }
        try reject("raster mismatch") { _ = try validation.tryAppend(externalBuffer(width:32,height:32),presentationTime:.zero,readiness:.completed) }
        try reject("nonzero first PTS") { _ = try validation.tryAppend(frame,presentationTime:CMTime(value:1001,timescale:30000),readiness:.completed) }
        let producerQueue = device.makeCommandQueue()!
        let notCommitted = producerQueue.makeCommandBuffer()!
        let uncommittedToken = try ProResPreparedMetalProducer(commandBuffer:notCommitted)
        try reject("uncommitted producer") { _ = try validation.tryAppend(frame,presentationTime:.zero,readiness:.metal(uncommittedToken)) }
        validation.cancel(); _ = second

        // Command-buffer completion token is registered before commit. The
        // shared-event wait deliberately keeps frame 0 incomplete while frame
        // 1 completes on another producer queue.
        let ordered = try session()
        let a = try ordered.makePixelBuffer(), b = try ordered.makePixelBuffer(); fill(a); fill(b)
        let event = device.makeSharedEvent()!
        let command0 = producerQueue.makeCommandBuffer()!; command0.encodeWaitForEvent(event,value:1)
        CVPixelBufferLockBaseAddress(a,[]); memset(CVPixelBufferGetBaseAddress(a)!,0,CVPixelBufferGetBytesPerRow(a)*32); CVPixelBufferUnlockBaseAddress(a,[])
        try encodeProducer(command0,frame:a,device:device)
        let token0 = try ProResPreparedMetalProducer(commandBuffer:command0); command0.commit()
        let r0 = try ordered.tryAppend(a,presentationTime:.zero,readiness:.metal(token0))!
        try reject("duplicate PTS") { _ = try ordered.tryAppend(b,presentationTime:.zero,readiness:.completed) }
        try reject("invalid PTS") { _ = try ordered.tryAppend(b,presentationTime:.invalid,readiness:.completed) }
        let command1 = device.makeCommandQueue()!.makeCommandBuffer()!
        try encodeProducer(command1,frame:b,device:device)
        let token1 = try ProResPreparedMetalProducer(commandBuffer:command1)
        let completed = CompletionFlag(); command1.addCompletedHandler { _ in completed.set() }; command1.commit()
        while !completed.isSet { try await Task.sleep(for:.milliseconds(1)) }
        try reject("late producer token registration") { _ = try ProResPreparedMetalProducer(commandBuffer:command1) }
        let r1 = try ordered.tryAppend(b,presentationTime:CMTime(value:1001,timescale:30000),readiness:.metal(token1))!
        try require(try ordered.tryAppend(a,presentationTime:CMTime(value:2002,timescale:30000),readiness:.completed) == nil,"nonblocking bounded admission")
        try await Task.sleep(for:.milliseconds(30))
        try require(ordered.statistics.writtenFrames == 0,"GPU completion order cannot reorder PTS")
        event.signaledValue = 1
        try await ordered.finish(); try await r0.waitUntilReleased(); try await r1.waitUntilReleased()
        _ = try inspect(output,frames:2,pq:false,width:64)
        let producerRGB = try run("/opt/homebrew/bin/ffmpeg",["-v","error","-i",output.path,"-frames:v","1","-pix_fmt","rgb48le","-f","rawvideo","pipe:1"])
        let producerLevels = producerRGB.withUnsafeBytes { Set($0.bindMemory(to:UInt16.self)) }
        try require(producerLevels.count > 32,"external GPU producer pixels reach encoder after completion")
        try require(ordered.statistics.retainedFrames == 0 && ordered.statistics.peakRetainedFrames == 2,"all ordered buffers released at capacity 2")

        let sentinel = Data("existing-final-output".utf8); try sentinel.write(to:output)
        let cancelled = try session()
        let pending = try cancelled.makePixelBuffer(); fill(pending)
        let cancelEvent = device.makeSharedEvent()!
        let command = producerQueue.makeCommandBuffer()!; command.encodeWaitForEvent(cancelEvent,value:1)
        let token = try ProResPreparedMetalProducer(commandBuffer:command); command.commit()
        let receipt = try cancelled.tryAppend(pending,presentationTime:.zero,readiness:.metal(token))!
        let released = CompletionFlag()
        let observer = Task { do { try await receipt.waitUntilReleased() } catch {}; released.set() }
        cancelled.cancel()
        try await Task.sleep(for:.milliseconds(30))
        try require(!released.isSet && cancelled.statistics.retainedFrames == 1,"cancel retains unfinished external GPU input")
        cancelEvent.signaledValue = 1
        await observer.value
        try require(cancelled.statistics.retainedFrames == 0,"cancel releases input after producer completes")
        try require(try Data(contentsOf:output) == sentinel,"cancel preserves existing final bytes")
        do { try await cancelled.finish(); throw NSError(domain:"CancelledFinish",code:1) } catch is CancellationError {} catch ProResPreparedFrameError.closed {}
        let unused = try session()
        do { try await unused.finish(); throw NSError(domain:"EmptyFinish",code:1) } catch ProResPreparedFrameError.encoding {}
        try require(try Data(contentsOf:output) == sentinel,"empty finish preserves existing final bytes")
        for _ in 0..<4 {
            let matrix = ProResExternalRGBMatrix(inputColor:sdr,row0:[1,0,0],row1:[0,1,0],row2:[0,0,1])
            let cancelledMatrix = try session(matrix:matrix)
            let frame = try cancelledMatrix.makePixelBuffer(); fill(frame)
            let receipt = try cancelledMatrix.tryAppend(frame,presentationTime:.zero,readiness:.completed)!
            cancelledMatrix.cancel()
            do { try await receipt.waitUntilReleased() } catch {}
            try require(cancelledMatrix.statistics.retainedFrames == 0,"cancel releases matrix work and input")
        }

        // Exercise the actual new GPU shader through the public session and
        // independently decode compressed ProRes as 16-bit nonlinear RGB.
        var summary: [[String:Any]] = []
        for mode in ["sdr-prepared","sdr-identity","sdr-half-linear","pq-prepared","pq-identity","sdr-to-pq"] {
            let pqInput = mode.hasPrefix("pq"), pqOutput = pqInput || mode == "sdr-to-pq"
            let outputColor = pqOutput ? hdr : sdr
            let sourceColor = pqInput ? hdr : sdr
            let matrix: ProResExternalRGBMatrix? = mode.hasSuffix("prepared") ? nil : ProResExternalRGBMatrix(inputColor:sourceColor,
                row0:mode == "sdr-half-linear" ? [0.5,0,0] : [1,0,0],row1:[0,1,0],row2:[0,0,1])
            let url = directory.appendingPathComponent(mode+".mov")
            let encoded = try ProResPreparedFrameSession(outputURL:url,width:1024,height:16,frameRateNumerator:30000,frameRateDenominator:1001,color:outputColor,matrix:matrix,capacity:2,device:device)
            let ramp = try encoded.makePixelBuffer(); fill(ramp,pqInput:pqInput)
            try await appendFrames(encoded,buffer:ramp,count:12)
            let info = try inspect(url,frames:12,pq:pqOutput,width:1024)
            let raw = try run("/opt/homebrew/bin/ffmpeg",["-v","error","-i",url.path,"-frames:v","1","-pix_fmt","rgb48le","-f","rawvideo","pipe:1"])
            var maxError = 0.0, sumSquared = 0.0; var count = 0; var levels = Set<UInt16>()
            raw.withUnsafeBytes { bytes in
                let codes = bytes.bindMemory(to:UInt16.self)
                for x in 8..<1016 {
                    let input = Double(Float16(pqInput ? pq(Double(x)/1023*1000) : Double(x)/1023))
                    let linear = pqInput ? 0.0 : decode709(input)*100
                    for c in 0..<3 {
                        let expected = mode == "sdr-half-linear" && c == 0 ? encode709(linear*0.5/100) : (mode == "sdr-to-pq" ? pq(linear) : input)
                        let actual = Double(codes[(8*1024+x)*3+c])/65535
                        let error = abs(expected-actual); maxError = max(maxError,error); sumSquared += error*error; count += 1
                    }
                    levels.insert(codes[(8*1024+x)*3+1])
                }
            }
            try require(maxError < 0.008,"independent decoded signal error \(mode): \(maxError)")
            try require(levels.count > 500,"high precision distinct ramp levels \(mode): \(levels.count)")
            if pqOutput {
                let bytes = try Data(contentsOf:url)
                let box = bytes.range(of:Data("mdcv".utf8))
                try require(box != nil,"explicit PQ mastering box \(mode)")
                if let box { let payload = bytes[box.upperBound..<box.upperBound+24]; try require(Array(payload.suffix(4)) == [0,0,0,50],"explicit 0.005-nit mastering minimum") }
            }
            summary.append(["mode":mode,"max_signal_error":maxError,"rms_signal_error":sqrt(sumSquared/Double(count)),"distinct_ramp_levels":levels.count,"statistics":["accepted":encoded.statistics.acceptedFrames,"written":encoded.statistics.writtenFrames,"retained":encoded.statistics.retainedFrames,"peak_retained":encoded.statistics.peakRetainedFrames],"probe":info])
        }
        for codec in ProResPreparedCodec.allCases {
            let url = directory.appendingPathComponent("codec-\(codec.rawValue).mov")
            let encoded = try ProResPreparedFrameSession(outputURL:url,width:64,height:32,frameRateNumerator:30000,frameRateDenominator:1001,codec:codec,color:sdr,capacity:2,device:device)
            let frame = try encoded.makePixelBuffer(); fill(frame)
            try await appendFrames(encoded,buffer:frame,count:64)
            _ = try inspect(url,frames:64,pq:false,width:64)
            try require(encoded.statistics.peakRetainedFrames <= 2 && encoded.statistics.retainedFrames == 0,"bounded codec delay and release \(codec.rawValue)")
        }
        let unknownBlack = ProResPreparedColorDescriptor(primaries:.p3D65,transfer:.pq,referenceWhiteNits:203,nominalPeakNits:1000)
        let p3URL = directory.appendingPathComponent("p3-no-mastering.mov")
        let p3 = try ProResPreparedFrameSession(outputURL:p3URL,width:64,height:32,frameRateNumerator:30000,frameRateDenominator:1001,color:unknownBlack,device:device)
        let p3Frame = try p3.makePixelBuffer(); fill(p3Frame,pqInput:true); try await appendFrames(p3,buffer:p3Frame,count:4)
        let p3Data = try run("/opt/homebrew/bin/ffprobe",["-v","error","-show_streams","-of","json",p3URL.path])
        try require(String(decoding:p3Data,as:UTF8.self).contains("smpte432"),"P3 is explicitly D65")
        try require(try Data(contentsOf:p3URL).range(of:Data("mdcv".utf8)) == nil,"unknown mastering minimum is not invented")
        for (name,primaries,transfer,tag) in [("2020-sdr",ProResPreparedPrimaries.rec2020,ProResPreparedTransfer.bt709,"bt2020"),("p3-sdr",.p3D65,.bt709,"smpte432"),("709-pq",.rec709,.pq,"bt709")] {
            let descriptor = ProResPreparedColorDescriptor(primaries:primaries,transfer:transfer,referenceWhiteNits:100,nominalPeakNits:transfer == .pq ? 1000:100)
            let url = directory.appendingPathComponent(name+".mov")
            let encoded = try ProResPreparedFrameSession(outputURL:url,width:64,height:32,frameRateNumerator:30000,frameRateDenominator:1001,color:descriptor,capacity:2,device:device)
            let frame = try encoded.makePixelBuffer(); fill(frame,pqInput:transfer == .pq); try await appendFrames(encoded,buffer:frame,count:4)
            let data = try run("/opt/homebrew/bin/ffprobe",["-v","error","-show_streams","-of","json",url.path])
            let stream = ((try JSONSerialization.jsonObject(with:data) as! [String:Any])["streams"] as! [[String:Any]])[0]
            try require(stream["color_primaries"] as? String == tag && stream["color_transfer"] as? String == (transfer == .pq ? "smpte2084":"bt709"),"supported descriptor combination \(name)")
        }
        try require(try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.contains("proresencoder-working")}.isEmpty,"owned temporary files cleaned")
        try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("summary.json"))
        print("ALL PREPARED FRAME CONTRACTS PASSED")
    }
    static func benchmark(_ url: URL, count: Int, width: Int, height: Int, matrix: Bool, device: MTLDevice) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let m = matrix ? ProResExternalRGBMatrix(inputColor:sdr,row0:[1,0,0],row1:[0,1,0],row2:[0,0,1]) : nil
        let session = try ProResPreparedFrameSession(outputURL:url,width:width,height:height,frameRateNumerator:30000,frameRateDenominator:1001,color:sdr,matrix:m,capacity:4,device:device)
        let frame = try session.makePixelBuffer(); fill(frame)
        let setup = ProcessInfo.processInfo.systemUptime
        try await appendFrames(session,buffer:frame,count:count)
        let finish = ProcessInfo.processInfo.systemUptime
        let value: [String:Any] = ["mode":matrix ? "matrix":"prepared","frames":count,"width":width,"height":height,"e2e_seconds":finish-start,"encode_seconds":finish-setup,"setup_seconds":setup-start,"peak_retained":session.statistics.peakRetainedFrames,"visible_color_dispatches_per_frame":matrix ? 1:0,"visible_cpu_frame_copies":0,"matrix_gpu_seconds":session.statistics.matrixGPUSeconds,"external_producer_gpu_seconds":session.statistics.externalProducerGPUSeconds,"backpressure_codec_drain":session.usesBackpressureCodecDrain]
        print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self))
    }
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count >= 3, let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain:"Usage/Metal",code:1) }
            if arguments[1] == "contracts" { try await contracts(URL(fileURLWithPath:arguments[2]),device:device) }
            else if arguments[1] == "benchmark" {
                try await benchmark(URL(fileURLWithPath:arguments[2]),count:Int(arguments[3])!,width:Int(arguments[4])!,height:Int(arguments[5])!,matrix:arguments[6] == "matrix",device:device)
            } else { throw NSError(domain:"Usage",code:1) }
        } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
    }
}
