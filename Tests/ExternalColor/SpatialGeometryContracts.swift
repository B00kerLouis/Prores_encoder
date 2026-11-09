// B00kerLouis. Pure CPU spatial geometry contracts; no Metal execution.
import Foundation
#if !SPATIAL_STANDALONE
import ProResEncoderFramework
#endif
@MainActor @main struct SpatialGeometryContracts {
    static var assertions = 0
    static func check(_ yes: @autoclosure () throws -> Bool, _ text: String) throws {
        guard try yes() else { throw NSError(domain: "SpatialGeometry",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
        assertions += 1
    }
    static func close(_ a: Double,_ b: Double) -> Bool { abs(a-b)<1e-7 }
    static func reject(_ text: String,_ operation: () throws -> Void) throws {
        do { try operation() } catch { assertions += 1; return }
        throw NSError(domain:"SpatialGeometry",code:2,userInfo:[NSLocalizedDescriptionKey:"Accepted "+text])
    }
    static func main() throws {
        let input = ProResSpatialSourceGeometry(width:3840,height:2160)
        let presets: [(ProResSpatialTarget,Int,Int)] = [(.source,3840,2160),(.dci2KFull,2048,1080),(.dci2KFlat,1998,1080),(.dci2KScope,2048,858),(.dci4KFull,4096,2160),(.dci4KFlat,3996,2160),(.dci4KScope,4096,1716),(.uhd,3840,2160),(.fullHD,1920,1080),(.custom(width:640,height:480),640,480)]
        for (target,w,h) in presets {
            for mode in [ProResSpatialMode.fit,.fill] {
                let p = try ProResSpatialPlan(source:input,target:target,mode:mode)
                try check(p.canvas == .init(width:w,height:h),"exact preset raster")
                try check(close(p.contentRect.width/p.contentRect.height,16.0/9),"aspect is uniform")
                try check(p.activeContentRect.x>=0 && p.activeContentRect.y>=0,"active origin in canvas")
                try check(p.activeContentRect.x+p.activeContentRect.width <= Double(w)+1e-7 && p.activeContentRect.y+p.activeContentRect.height <= Double(h)+1e-7,"active inside canvas")
                try check(p.sourceVisibleRect.x>=0 && p.sourceVisibleRect.y>=0 && p.sourceVisibleRect.x+p.sourceVisibleRect.width<=3840.0000001 && p.sourceVisibleRect.y+p.sourceVisibleRect.height<=2160.0000001,"visible source inside raster")
                if mode == .fit { try check(close(p.sourceVisibleRect.width,3840) && close(p.sourceVisibleRect.height,2160),"fit preserves whole source") }
                else { try check(close(p.activeContentRect.width,Double(w)) && close(p.activeContentRect.height,Double(h)),"fill covers canvas") }
            }
        }
        let same = try ProResSpatialPlan(source:input)
        try check(same.isPassthrough && same.isPixelAlignedUnitScale && same.scale==1,"source is true pass-through")
        let dci = try ProResSpatialPlan(source:input,target:.dci4KFull)
        try check(dci.activeContentRect == .init(x:128,y:0,width:3840,height:2160) && dci.isPixelAlignedUnitScale,"UHD->DCI4K fit is 1:1 plus 128px side bars")
        let flat = try ProResSpatialPlan(source:input,target:.dci4KFlat,mode:.pad)
        try check(flat.activeContentRect == .init(x:78,y:0,width:3840,height:2160),"4K flat differs from UHD and full")
        let crop = try ProResSpatialPlan(source:input,target:.custom(width:2048,height:858),mode:.crop)
        try check(crop.sourceVisibleRect == .init(x:896,y:651,width:2048,height:858) && crop.isPixelAlignedUnitScale,"crop exact centered integer source rectangle")
        let fill = try ProResSpatialPlan(source:input,target:.dci4KFull,mode:.fill)
        try check(close(fill.scale,16.0/15) && close(fill.sourceVisibleRect.y,67.5) && close(fill.sourceVisibleRect.height,2025),"fill keeps correct fractional source crop")
        for (w,h) in [(0,1080),(-2,1080),(1921,1080),(1920,1079),(16386,2)] {
            try reject("invalid input geometry") { _ = try ProResSpatialPlan(source:.init(width:w,height:h)) }
            try reject("invalid output geometry") { _ = try ProResSpatialPlan(source:input,target:.custom(width:w,height:h)) }
        }
        try reject("non-square PAR") { _ = try ProResSpatialPlan(source:.init(width:1920,height:1080,pixelAspect:.init(horizontalSpacing:4,verticalSpacing:3))) }
        try reject("zero PAR") { _ = try ProResSpatialPlan(source:.init(width:1920,height:1080,pixelAspect:.init(horizontalSpacing:0,verticalSpacing:0))) }
        try reject("cropped aperture") { _ = try ProResSpatialPlan(source:.init(width:1920,height:1080,cleanAperture:.init(width:1888,height:1080))) }
        try reject("offset aperture") { _ = try ProResSpatialPlan(source:.init(width:1920,height:1080,cleanAperture:.init(x:1,width:1920,height:1080))) }
        try reject("nonfinite aperture") { _ = try ProResSpatialPlan(source:.init(width:1920,height:1080,cleanAperture:.init(x:.nan,width:1920,height:1080))) }
        try reject("crop cannot enlarge") { _ = try ProResSpatialPlan(source:input,target:.dci4KFull,mode:.crop) }
        try reject("pad cannot shrink") { _ = try ProResSpatialPlan(source:input,target:.fullHD,mode:.pad) }
        _ = try ProResSpatialPlan(source:.init(width:1920,height:1080,pixelAspect:.init(horizontalSpacing:2,verticalSpacing:2),cleanAperture:.init(width:1920,height:1080)))
        #if SPATIAL_STANDALONE
        try reject("hostile huge row bound") { _ = try SpatialWorkingSetBudget.planeBytes(row:1<<60,height:2) }
        try reject("row product overflow") { _ = try SpatialWorkingSetBudget.planeBytes(row:Int.max-7,height:2) }
        try reject("sum overflow") { _ = try SpatialWorkingSetBudget.total(source:Int64.max,output:Int64.max,capacity:4) }
        try reject("capacity multiplication overflow") { _ = try SpatialWorkingSetBudget.total(source:Int64.max/2,output:0,capacity:4) }
        try reject("budget exceeds 1GiB") { _ = try SpatialWorkingSetBudget.total(source:500_000_000,output:500_000_000,capacity:4) }
        try check(try SpatialWorkingSetBudget.total(source:100_000_000,output:100_000_000,capacity:4)==800_000_000,"valid checked working set")
        #endif
        print("PASS \(assertions) pure CPU geometry assertions; no Metal device or GPU execution")
    }
}
