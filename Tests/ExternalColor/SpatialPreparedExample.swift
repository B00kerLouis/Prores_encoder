// B00kerLouis. Minimal four-frame Matrix+spatial public API example.
import Foundation
import CoreVideo
import CoreMedia
import Metal
import ProResEncoderFramework
@main struct SpatialPreparedExample {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 2, let device = MTLCreateSystemDefaultDevice() else {
                throw NSError(domain:"Usage: example output.mov [source]",code:1)
            }
            let target: ProResSpatialTarget = CommandLine.arguments.last == "source" ? .source : .dci2KFlat
            let plan = try ProResSpatialPlan(source:.init(width:320,height:180),target:target,mode:.fit)
            let color = ProResPreparedColorDescriptor(primaries:.rec709,transfer:.bt709,referenceWhiteNits:100,nominalPeakNits:100)
            let encoder = try ProResPreparedFrameSession(outputURL:URL(fileURLWithPath:CommandLine.arguments[1]),
                width:plan.canvas.width,height:plan.canvas.height,frameRateNumerator:30000,frameRateDenominator:1001,
                codec:.proRes4444XQ,color:color,capacity:4,device:device)
            // Select once at setup. Source mode never constructs the spatial
            // processor, its pool/cache/PSO, a queue or any spatial commands.
            let spatial = try plan.isPassthrough ? nil : ProResSpatialProcessor(plan:plan,encodingSession:encoder)
            let queue = plan.isPassthrough ? nil : device.makeCommandQueue()
            var source:CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault,320,180,kCVPixelFormatType_64RGBAHalf,
                [kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&source)
            guard status == 0, let source else { throw NSError(domain:"CVPixelBuffer",code:Int(status)) }
            CVPixelBufferLockBaseAddress(source,[])
            let pixels=CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to:Float16.self),stride=CVPixelBufferGetBytesPerRow(source)/2
            for y in 0..<180 { for x in 0..<320 { for c in 0..<3 { pixels[y*stride+x*4+c]=Float16(Double(x)/319) };pixels[y*stride+x*4+3]=1 } }
            CVPixelBufferUnlockBaseAddress(source,[])
            var receipts:[ProResPreparedFrameSubmission]=[]
            for i in 0..<4 {
                let pts=CMTime(value:Int64(i)*1001,timescale:30000)
                let receipt:ProResPreparedFrameSubmission?
                if let spatial,let queue {
                    let command=queue.makeCommandBuffer()!
                    guard let frame=try spatial.encode(source,into:command,readiness:.completed) else { throw NSError(domain:"Unexpected spatial backpressure for four frames/capacity4",code:1) }
                    let producer=try ProResPreparedMetalProducer(commandBuffer:command)
                    command.commit() // register completion before commit
                    receipt=try encoder.tryAppend(frame.pixelBuffer,presentationTime:pts,readiness:.metal(producer))
                } else { receipt=try encoder.tryAppend(source,presentationTime:pts,readiness:.completed) }
                guard let receipt else { throw NSError(domain:"Unexpected encoder backpressure for four frames/capacity4",code:1) }
                receipts.append(receipt)
            }
            try await encoder.finish()
            for receipt in receipts { try await receipt.waitUntilReleased() }
            print("Encoded 4 frames: \(plan.canvas.width)x\(plan.canvas.height); spatial dispatches=\(spatial?.statistics.encodedDispatches ?? 0)")
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1) }
    }
}
