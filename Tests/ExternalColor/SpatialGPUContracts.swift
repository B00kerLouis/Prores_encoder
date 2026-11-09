// B00kerLouis. Opt-in real GPU/public ProRes spatial contracts.
import Foundation
import CoreMedia
import CoreVideo
import Metal
import ProResEncoderFramework

private final class TestTexture: @unchecked Sendable { let value: CVMetalTexture; init(_ value: CVMetalTexture) { self.value = value } }
private final class LifetimeMarker: NSObject {}
private final class MarkerObserver { weak var value: LifetimeMarker?; init(_ value: LifetimeMarker?) { self.value = value } }
@MainActor @main struct SpatialGPUContracts {
    static var checks = 0
    static let sdr = ProResPreparedColorDescriptor(primaries:.rec709,transfer:.bt709,referenceWhiteNits:100,nominalPeakNits:100)
    static let hdr = ProResPreparedColorDescriptor(primaries:.rec2020,transfer:.pq,referenceWhiteNits:203,nominalPeakNits:1000,masteringMinimumNits:0.005)
    static func check(_ yes: @autoclosure () throws -> Bool,_ text: String) throws {
        guard try yes() else { throw NSError(domain:"SpatialGPU",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
        checks += 1; print("PASS \(text)")
    }
    static func reject(_ text:String,_ fn:()throws->Void) throws {
        do { try fn() } catch { checks += 1; print("PASS reject \(text): \(error.localizedDescription)");return }
        throw NSError(domain:"SpatialGPU",code:2,userInfo:[NSLocalizedDescriptionKey:"Accepted "+text])
    }
    static func picture(_ w:Int,_ h:Int) throws -> CVPixelBuffer {
        var p: CVPixelBuffer?;let s=CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_64RGBAHalf,[kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&p)
        guard s==0,let p else { throw NSError(domain:"CV",code:Int(s)) };return p
    }
    static func fill(_ p:CVPixelBuffer,_ value:(Int,Int)->[Float16]) {
        CVPixelBufferLockBaseAddress(p,[]);defer { CVPixelBufferUnlockBaseAddress(p,[]) }
        let b=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:Float16.self),stride=CVPixelBufferGetBytesPerRow(p)/2
        for y in 0..<CVPixelBufferGetHeight(p) { for x in 0..<CVPixelBufferGetWidth(p) { let v=value(x,y);for c in 0..<4 { b[y*stride+x*4+c]=v[c] } } }
    }
    static func pixel(_ p:CVPixelBuffer,_ x:Int,_ y:Int)->[Float16] {
        CVPixelBufferLockBaseAddress(p,.readOnly);defer { CVPixelBufferUnlockBaseAddress(p,.readOnly) }
        let b=CVPixelBufferGetBaseAddress(p)!.assumingMemoryBound(to:Float16.self),stride=CVPixelBufferGetBytesPerRow(p)/2
        return (0..<4).map { b[y*stride+x*4+$0] }
    }
    static func pq(_ n:Double)->Double { let p=pow(max(n,0)/10000,2610.0/16384);return pow((3424.0/4096+2413.0/128*p)/(1+2392.0/128*p),2523.0/32) }
    static func pqNits(_ v:Double)->Double { let p=pow(max(v,0),32.0/2523);return 10000*pow(max(p-3424.0/4096,0)/(2413.0/128-2392.0/128*p),16384.0/2610) }
    static func encode709(_ n:Double)->Double { n<0.018 ? n*4.5:1.099*pow(n,0.45)-0.099 }
    static func rendered(_ processor:ProResSpatialProcessor,_ source:CVPixelBuffer,_ queue:MTLCommandQueue) async throws -> ProResSpatialFrame {
        let command=queue.makeCommandBuffer()!
        guard let result=try processor.encode(source,into:command,readiness:.completed) else { throw NSError(domain:"UnexpectedPool",code:1) }
        let token=try ProResPreparedMetalProducer(commandBuffer:command);command.commit()
        try await result.waitForGPUCompletion();_ = token;return result
    }
    static func process(_ exe:String,_ args:[String])throws->Data {
        let p=Process();p.executableURL=URL(fileURLWithPath:exe);p.arguments=args;let o=Pipe(),e=Pipe();p.standardOutput=o;p.standardError=e
        try p.run();let data=o.fileHandleForReading.readDataToEndOfFile(),err=e.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
        guard p.terminationStatus==0 else { throw NSError(domain:"Process",code:Int(p.terminationStatus),userInfo:[NSLocalizedDescriptionKey:String(decoding:err,as:UTF8.self)]) };return data
    }
    static func producer(_ command:MTLCommandBuffer,_ buffer:CVPixelBuffer,_ device:MTLDevice)throws {
        let source="""
        #include <metal_stdlib>
        using namespace metal;
        kernel void spatial_test_producer(texture2d<half,access::write> out [[texture(0)]],uint2 p [[thread_position_in_grid]]) {
          if(p.x<out.get_width()&&p.y<out.get_height()) out.write(half4(0.75h,0.25h,0.125h,1.0h),p);
        }
        """
        let lib=try device.makeLibrary(source:source,options:nil),ps=try device.makeComputePipelineState(function:lib.makeFunction(name:"spatial_test_producer")!)
        var cache:CVMetalTextureCache?,texture:CVMetalTexture?;guard CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,device,nil,&cache)==0,CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache!,buffer,nil,.rgba16Float,CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer),0,&texture)==0,let texture else { throw NSError(domain:"TestTexture",code:1) }
        let retained=TestTexture(texture),e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(ps);e.setTexture(CVMetalTextureGetTexture(texture),index:0);e.dispatchThreads(.init(width:CVPixelBufferGetWidth(buffer),height:CVPixelBufferGetHeight(buffer),depth:1),threadsPerThreadgroup:.init(width:8,height:8,depth:1));e.endEncoding();command.addCompletedHandler { [retained] _ in _ = retained }
    }
    static func run(_ dir:URL,_ device:MTLDevice)async throws {
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let queue=device.makeCommandQueue()!,src=try picture(8,4)
        fill(src) { x,y in [Float16(Double(x)/8),Float16(Double(y)/4),0.375,Float16(0.5+Double(x)/32)] }
        let identity=try ProResSpatialProcessor(plan:ProResSpatialPlan(source:.init(width:8,height:4)),color:sdr,device:device,capacity:2)
        let untouched=try identity.encode(src,readiness:.completed)!
        try check(untouched.pixelBuffer === src,"source default returns identical CVPixelBuffer")
        try check(identity.statistics.encodedDispatches==0 && identity.statistics.workingSetBoundBytes==0,"source default has no PSO/pool/dispatch/copy working set")
        let modes:[(ProResSpatialMode,Int,Int,Int,Int)]=[(.fit,8,8,0,2),(.fill,4,4,-2,0),(.crop,4,2,-2,-1),(.pad,12,8,2,2)]
        for (mode,w,h,ox,oy) in modes {
            let plan=try ProResSpatialPlan(source:.init(width:8,height:4),target:.custom(width:w,height:h),mode:mode)
            let p=try ProResSpatialProcessor(plan:plan,color:sdr,device:device,capacity:2)
            let frame=try await rendered(p,src,queue)
            for y in 0..<h { for x in 0..<w {
                let sx=x-ox,sy=y-oy,v=pixel(frame.pixelBuffer,x,y)
                if sx>=0 && sx<8 && sy>=0 && sy<4 { try check(v.map(\.bitPattern)==pixel(src,sx,sy).map(\.bitPattern),"\(mode.rawValue) preserves unit-scale half bits \(x),\(y)") }
                else { try check(v==[0,0,0,1],"\(mode.rawValue) opaque black padding") }
            } }
            let d=CVBufferCopyAttachment(frame.pixelBuffer,kCVImageBufferCleanApertureKey,nil) as! [String:Any]
            try check((d[kCVImageBufferCleanApertureWidthKey as String] as! NSNumber).intValue==w && (d[kCVImageBufferCleanApertureHeightKey as String] as! NSNumber).intValue==h,"real full canvas aperture \(mode.rawValue)")
        }
        let tiny=try picture(2,2);let upscale=try ProResSpatialPlan(source:.init(width:2,height:2),target:.custom(width:4,height:4))
        for color in [sdr,hdr] {
            let white=Float16(color.transfer == .pq ? pq(1000):1)
            fill(tiny) { x,_ in let v:Float16=x==0 ? 0:white;return[v,v,v,1] }
            for domain in [ProResSpatialInterpolationDomain.linearLight,.encoded] {
                let p=try ProResSpatialProcessor(plan:upscale,color:color,device:device,capacity:2,interpolationDomain:domain)
                let f=try await rendered(p,tiny,queue),actual=Double(pixel(f.pixelBuffer,1,1)[0])
                let expected=domain == .encoded ? Double(white)*0.25 : color.transfer == .pq ? pq(pqNits(Double(white))*0.25):encode709(0.25)
                try check(abs(actual-expected)<0.001,"independent \(color.transfer.rawValue)/\(domain.rawValue) bilinear domain \(actual) vs \(expected)")
            }
        }
        fill(tiny) { x,_ in x==0 ? [1,0,0,1]:[0,0,1,0] }
        let alpha=try ProResSpatialProcessor(plan:upscale,color:sdr,device:device,capacity:2)
        let af=try await rendered(alpha,tiny,queue),av=pixel(af.pixelBuffer,1,1)
        try check(av[0]==1 && av[2]==0 && abs(Double(av[3])-0.75)<0.001,"alpha-correct resample excludes hidden transparent blue")
        let padded=try ProResSpatialProcessor(plan:ProResSpatialPlan(source:.init(width:2,height:2),target:.custom(width:4,height:4),mode:.pad),color:sdr,device:device,capacity:2,padding:.transparentBlack)
        let transparent=try await rendered(padded,tiny,queue)
        try check(pixel(transparent.pixelBuffer,0,0)==[0,0,0,0],"explicit transparent black pad")
        try reject("huge public stride") { _ = try ProResSpatialProcessor(plan:upscale,color:sdr,device:device,maximumSourceBytesPerRow:1<<60) }
        try reject("resize nil command") { _ = try alpha.encode(tiny,readiness:.completed) }
        try reject("same-command readiness without command") { _ = try identity.encode(src,readiness:.sameCommandBuffer) }
        let committed=queue.makeCommandBuffer()!;committed.commit()
        try reject("late spatial encode") { _ = try alpha.encode(tiny,into:committed,readiness:.completed) }
        CVBufferSetAttachment(src,kCVImageBufferPixelAspectRatioKey,[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String:4,kCVImageBufferPixelAspectRatioVerticalSpacingKey as String:3] as CFDictionary,.shouldPropagate)
        try reject("actual non-square PAR") { _ = try identity.encode(src,readiness:.completed) };CVBufferRemoveAttachment(src,kCVImageBufferPixelAspectRatioKey)
        CVBufferSetAttachment(src,kCVImageBufferCleanApertureKey,[kCVImageBufferCleanApertureWidthKey as String:6,kCVImageBufferCleanApertureHeightKey as String:4,kCVImageBufferCleanApertureHorizontalOffsetKey as String:0,kCVImageBufferCleanApertureVerticalOffsetKey as String:0] as CFDictionary,.shouldPropagate)
        try reject("actual non-full aperture") { _ = try identity.encode(src,readiness:.completed) };CVBufferRemoveAttachment(src,kCVImageBufferCleanApertureKey)
        CVBufferSetAttachment(src,kCVImageBufferContentLightLevelInfoKey,Data([3,232,0,100]) as CFData,.shouldPropagate)
        let resized=try ProResSpatialProcessor(plan:ProResSpatialPlan(source:.init(width:8,height:4),target:.custom(width:12,height:8)),color:sdr,device:device,capacity:2)
        let withoutCLL=try await rendered(resized,src,queue)
        try check(CVBufferCopyAttachment(withoutCLL.pixelBuffer,kCVImageBufferContentLightLevelInfoKey,nil)==nil,"geometry does not inherit measured CLL/FALL")
        // Actual producer writes earlier in the same command are observed.
        let c=queue.makeCommandBuffer()!;try producer(c,tiny,device)
        let produced=try alpha.encode(tiny,into:c,readiness:.sameCommandBuffer)!,token=try ProResPreparedMetalProducer(commandBuffer:c);c.commit();try await produced.waitForGPUCompletion();_ = token
        try check(pixel(produced.pixelBuffer,1,1)==[0.75,0.25,0.125,1],"same-command producer pixels reach spatial shader")
        // Dropped uncommitted work resolves failure without a command cycle.
        let discarded=try autoreleasepool { let c=queue.makeCommandBuffer()!;return try resized.encode(src,into:c,readiness:.completed)! }
        var discardedFailed=false
        do { try await discarded.waitForGPUCompletion() } catch is ProResSpatialError { discardedFailed=true }
        try check(discardedFailed,"discarded command resolves a typed failure")
        try check(resized.statistics.pendingGPUFrames==0,"discarded command releases pending resources")
        let fullCommand=queue.makeCommandBuffer()!
        try check(try resized.encode(src,into:fullCommand,readiness:.completed)==nil,"completed output leases enforce bounded pool backpressure")
        // Cancel while the command is genuinely blocked on a GPU event.
        var cancellable:ProResSpatialProcessor?=try ProResSpatialProcessor(plan:upscale,color:sdr,device:device,capacity:2)
        var pending:CVPixelBuffer?=try picture(2,2);var marker:LifetimeMarker?=LifetimeMarker();let observed=MarkerObserver(marker)
        CVBufferSetAttachment(pending!,"SpatialTestLifetime" as CFString,marker!,.shouldNotPropagate);marker=nil
        let event=device.makeSharedEvent()!,blocked=queue.makeCommandBuffer()!;blocked.encodeWaitForEvent(event,value:1)
        let waiting=try cancellable!.encode(pending!,into:blocked,readiness:.completed)!;blocked.commit();pending=nil;cancellable!.cancel()
        try check(observed.value != nil && cancellable!.statistics.pendingGPUFrames==1,"cancel retains unfinished GPU source")
        cancellable=nil;event.signaledValue=1
        do { try await waiting.waitForGPUCompletion();throw NSError(domain:"Cancel",code:1) } catch ProResSpatialError.cancelled {}
        try check(observed.value==nil,"cancel releases source after GPU completion")
        // Encoder composition uses matching capacity and actual output rasters.
        var summary:[[String:Any]]=[]
        let targets:[(String,ProResSpatialTarget)]=[("2k-full",.dci2KFull),("2k-flat",.dci2KFlat),("2k-scope",.dci2KScope),("4k-full",.dci4KFull),("4k-flat",.dci4KFlat),("4k-scope",.dci4KScope),("uhd",.uhd),("fhd",.fullHD)]
        let master=try picture(64,32);fill(master) { _,_ in [0.75,0.75,0.75,1] }
        for (name,target) in targets {
            let plan=try ProResSpatialPlan(source:.init(width:64,height:32),target:target),url=dir.appendingPathComponent(name+".mov")
            let encoder=try ProResPreparedFrameSession(outputURL:url,width:plan.canvas.width,height:plan.canvas.height,frameRateNumerator:30000,frameRateDenominator:1001,color:sdr,capacity:2,device:device)
            let spatial=try ProResSpatialProcessor(plan:plan,encodingSession:encoder)
            try check(spatial.capacity==encoder.capacity && spatial.color==encoder.inputColor,"encoder capacity/inputColor coordination \(name)")
            var receipts:[ProResPreparedFrameSubmission]=[]
            for i in 0..<2 {
                let command=queue.makeCommandBuffer()!
                guard let frame=try spatial.encode(master,into:command,readiness:.completed) else { throw NSError(domain:"UnexpectedPool",code:2) }
                let token=try ProResPreparedMetalProducer(commandBuffer:command);command.commit()
                try check(CVPixelBufferGetWidth(frame.pixelBuffer)==plan.canvas.width && CVPixelBufferGetHeight(frame.pixelBuffer)==plan.canvas.height,"actual RGBAHalf output dimensions \(name)")
                guard let receipt=try encoder.tryAppend(frame.pixelBuffer,presentationTime:CMTime(value:Int64(i)*1001,timescale:30000),readiness:.metal(token)) else { throw NSError(domain:"UnexpectedBackpressure",code:1) };receipts.append(receipt)
            }
            try await encoder.finish();for receipt in receipts { try await receipt.waitUntilReleased() }
            let data=try process("/opt/homebrew/bin/ffprobe",["-v","error","-show_streams","-show_packets","-select_streams","v:0","-of","json",url.path]);let root=try JSONSerialization.jsonObject(with:data) as! [String:Any],stream=(root["streams"] as! [[String:Any]])[0],packets=root["packets"] as! [[String:Any]]
            try check(stream["width"] as? Int==plan.canvas.width && stream["height"] as? Int==plan.canvas.height && packets.count==2,"actual encoded ProRes dimensions/coverage \(name)")
            try check(packets[0]["pts"] as? Int==0 && packets[1]["pts"] as? Int==1001,"exact output PTS \(name)")
            try check(encoder.statistics.retainedFrames==0 && encoder.statistics.peakRetainedFrames<=2,"bounded encode release \(name)")
            if name=="2k-full" || name=="uhd" {
                for (x,y,expected) in [(plan.canvas.width/2,plan.canvas.height/2,0.75),(0,0,0.0)] {
                    let raw=try process("/opt/homebrew/bin/ffmpeg",["-v","error","-i",url.path,"-frames:v","1","-vf","crop=2:2:\(x):\(y)","-pix_fmt","rgb48le","-f","rawvideo","pipe:1"])
                    let code=raw.withUnsafeBytes { $0.loadUnaligned(as:UInt16.self) };try check(abs(Double(code)/65535-expected)<0.02,"independent decoded active/pad pixel \(name)")
                }
            }
            summary.append(["preset":name,"width":plan.canvas.width,"height":plan.canvas.height,"frames":packets.count,"peak_retained":encoder.statistics.peakRetainedFrames,"spatial_gpu_dispatches":spatial.statistics.encodedDispatches,"working_set_bound":spatial.workingSetBoundBytes,"probe":root])
        }
        let plan=try ProResSpatialPlan(source:.init(width:2,height:2),target:.custom(width:4,height:4)),badEncoder=try ProResPreparedFrameSession(outputURL:dir.appendingPathComponent("capacity.mov"),width:4,height:4,frameRateNumerator:24,frameRateDenominator:1,color:sdr,capacity:4,device:device)
        let tooSmall=try ProResSpatialProcessor(plan:plan,color:sdr,device:device,capacity:2)
        try reject("spatial2/encoder4 backpressure cycle") { try tooSmall.validate(encodingSession:badEncoder) };badEncoder.cancel()
        try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("summary.json"))
        print("ALL SPATIAL GPU CONTRACTS PASSED: \(checks) assertions")
    }
    static func main()async {
        do { guard let device=MTLCreateSystemDefaultDevice(),CommandLine.arguments.count==2 else { throw NSError(domain:"Usage/Metal",code:1) };try await run(URL(fileURLWithPath:CommandLine.arguments[1]),device) }
        catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8));exit(1) }
    }
}
