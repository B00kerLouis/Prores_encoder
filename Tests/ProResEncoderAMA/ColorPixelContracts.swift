import Foundation
import CoreVideo
import CoreMedia
@testable import ProResEncoderFramework

// B00kerLouis. Opt-in local GPU transport contracts; no Avid SDK is required.
// Compare mixed subsampling geometry and half RGB with independent video-range
// YCbCr equations. These vectors are separate from real-host acceptance.
@main struct ColorPixelContracts {
    static func picture(_ format: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary, &value)
        guard result == 0, let value else { throw NSError(domain: "ColorContracts", code: Int(result)) }
        return value
    }
    static func fill(_ frame: CVPixelBuffer, vertical: Int) {
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        for plane in 0..<2 {
            let rows = plane == 0 ? height : height / vertical
            let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, plane) / 2
            let data = CVPixelBufferGetBaseAddressOfPlane(frame, plane)!.assumingMemoryBound(to: UInt16.self)
            for y in 0..<rows { for x in 0..<width {
                data[y * stride + x] = UInt16(plane == 0 ? 450 : (x % 2 == 0 ? 440 + y * 16 : 512)) << 6
            } }
        }
    }
    static func pipeline(_ sourceFormat: OSType, _ outputFormat: OSType) throws -> MetalColorPipeline {
        let source = SourceColorProfile(gamut: .rec709, oetf: .gamma24, yCbCrMatrixID: 0, peakNits: 100)
        let request = try ColorTransformRequest(gamut: "rec709", oetf: "gamma2.4", nits: "100")
        return try MetalColorPipeline(transform: ResolvedColorTransform(input: source, request: request),
            width: 8, height: 8, pixelFormat: sourceFormat, outputPixelFormat: outputFormat)
    }
    static func pqNits(_ value: Double) -> Double {
        let p = pow(max(value, 0), 32.0 / 2523)
        return 10000 * pow(max(p - 3424.0 / 4096, 0) / (2413.0 / 128 - 2392.0 / 128 * p), 16384.0 / 2610)
    }
    static func pqSignal(_ nits: Double) -> Double {
        let p = pow(max(nits, 0) / 10000, 2610.0 / 16384)
        return pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)
    }
    static func main() throws {
        var failures = 0
        for (format, vertical) in [(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 2),
                                  (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, 1)] {
            let source = try picture(format, width: 8, height: 8); fill(source, vertical: vertical)
            let out = try pipeline(format, kCVPixelFormatType_64RGBAHalf).process(source, pts: .zero)
            CVPixelBufferLockBaseAddress(out, .readOnly)
            let data = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: Float16.self)
            let stride = CVPixelBufferGetBytesPerRow(out) / 2
            for y in 0..<8 {
                let Y = (450.0 - 64) / 876
                let cb = (Double(440 + y / vertical * 16) - 512) / 896
                let expected = Y + 1.8556 * cb
                let actual = Double(data[y * stride + 2])
                if abs(actual - expected) > 0.001 { failures += 1 }
                print("RGB row source vertical=\(vertical) y=\(y) expected B=\(expected) actual=\(actual)")
            }
            CVPixelBufferUnlockBaseAddress(out, .readOnly)
        }
        let source = try picture(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, width: 8, height: 8)
        fill(source, vertical: 1)
        let out = try pipeline(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange).process(source, pts: .zero)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        let uv = CVPixelBufferGetBaseAddressOfPlane(out, 1)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(out, 1) / 2
        for y in 0..<4 {
            let expected = 440 + y * 32 + 8
            let actual = Int(uv[y * stride] >> 6)
            if abs(actual - expected) > 1 || uv[y * stride] & 63 != 0 { failures += 1 }
            print("422->420 row \(y): Cb=\(actual), expected=\(expected)")
        }
        CVPixelBufferUnlockBaseAddress(out, .readOnly)
        // Rec.2020/PQ RGB can be transported using 709 YCbCr equations.
        // Quantize independent known RGB triples, then check the shared GPU
        // recovers those triples without substituting 709 RGB primaries.
        let wire = try picture(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, width: 8, height: 8)
        let triples = [[0.45,0.30,0.20], [0.80,0.20,0.20], [0.20,0.75,0.20], [0.20,0.20,0.70]]
        var expectedWire = [[Double]]()
        CVPixelBufferLockBaseAddress(wire, [])
        let wireY = CVPixelBufferGetBaseAddressOfPlane(wire, 0)!.assumingMemoryBound(to: UInt16.self)
        let wireUV = CVPixelBufferGetBaseAddressOfPlane(wire, 1)!.assumingMemoryBound(to: UInt16.self)
        let wireYS = CVPixelBufferGetBytesPerRowOfPlane(wire, 0) / 2
        let wireUVS = CVPixelBufferGetBytesPerRowOfPlane(wire, 1) / 2
        for rgb in triples {
            let y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
            let yCode = (64 + 876 * y).rounded()
            let cbCode = (512 + 896 * (rgb[2] - y) / 1.8556).rounded()
            let crCode = (512 + 896 * (rgb[0] - y) / 1.5748).rounded()
            let Y = (yCode - 64) / 876, cb = (cbCode - 512) / 896, cr = (crCode - 512) / 896
            expectedWire.append([Y + 1.5748 * cr,
                Y - 0.1873242729306488 * cb - 0.4681242729306488 * cr, Y + 1.8556 * cb])
            let x = (expectedWire.count - 1) * 2
            for row in 0..<8 {
                wireY[row * wireYS + x] = UInt16(yCode) << 6
                wireY[row * wireYS + x + 1] = UInt16(yCode) << 6
                wireUV[row * wireUVS + x] = UInt16(cbCode) << 6
                wireUV[row * wireUVS + x + 1] = UInt16(crCode) << 6
            }
        }
        CVPixelBufferUnlockBaseAddress(wire, [])
        let wireSource = SourceColorProfile(gamut: .rec2020, oetf: .pq, yCbCrMatrixID: 0, peakNits: 10000)
        let wireRequest = try ColorTransformRequest(gamut: "rec2020", oetf: "pq", nits: "10000")
        let wireMapper = try MetalColorPipeline(transform: ResolvedColorTransform(input: wireSource, request: wireRequest),
            width: 8, height: 8, pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            outputPixelFormat: kCVPixelFormatType_64RGBAHalf)
        let wireOut = try wireMapper.process(wire, pts: .zero)
        CVPixelBufferLockBaseAddress(wireOut, .readOnly)
        let wireValues = CVPixelBufferGetBaseAddress(wireOut)!.assumingMemoryBound(to: Float16.self)
        for sample in 0..<4 { for c in 0..<3 {
            let actual = Double(wireValues[sample * 8 + c])
            if abs(actual - expectedWire[sample][c]) > 0.001 { failures += 1 }
            print("Rec2020/PQ over 709 matrix sample=\(sample) channel=\(c) expected=\(expectedWire[sample][c]) actual=\(actual)")
        } }
        CVPixelBufferUnlockBaseAddress(wireOut, .readOnly)
        // Explicit P3-D65 fixture, not identification of an Avid project.
        // Derive this P3-D65->2020 matrix independently from H.273 Table 2
        // primary xy coordinates and D65; retain 709 wire coding separately.
        let p3Matrix = [[0.7538330343617217,0.19859736905261646,0.04756959658566183],
            [0.04574384896535829,0.9417772198116936,0.012478931222948119],
            [-0.0012103403545183202,0.017601717301090006,0.9836086230534281]]
        let p3Source = SourceColorProfile(gamut: .p3D65, oetf: .pq, yCbCrMatrixID: 0, peakNits: 10000)
        let p3Mapper = try MetalColorPipeline(transform: ResolvedColorTransform(input: p3Source, request: wireRequest),
            width: 8, height: 8, pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            outputPixelFormat: kCVPixelFormatType_64RGBAHalf)
        let p3Out = try p3Mapper.process(wire, pts: .zero)
        CVPixelBufferLockBaseAddress(p3Out, .readOnly)
        let p3Values = CVPixelBufferGetBaseAddress(p3Out)!.assumingMemoryBound(to: Float16.self)
        for sample in 0..<4 { for c in 0..<3 {
            let nits = (0..<3).reduce(0.0) { $0 + p3Matrix[c][$1] * pqNits(expectedWire[sample][$1]) }
            let expected = pqSignal(nits), actual = Double(p3Values[sample * 8 + c])
            if abs(actual - expected) > 0.001 { failures += 1 }
            print("P3D65/PQ over 709 matrix ->2020 sample=\(sample) channel=\(c) expected=\(expected) actual=\(actual)")
        } }
        CVPixelBufferUnlockBaseAddress(p3Out, .readOnly)
        // Independent ST2084 decoding and published 709->2020 primary matrix.
        // Equal 100-nit peaks isolate transfer/primaries from SDR expansion.
        let rgb = try picture(kCVPixelFormatType_32BGRA, width: 8, height: 8)
        CVPixelBufferLockBaseAddress(rgb, [])
        let pixels = CVPixelBufferGetBaseAddress(rgb)!.assumingMemoryBound(to: UInt8.self)
        let rgbStride = CVPixelBufferGetBytesPerRow(rgb)
        let samples: [[UInt8]] = [[0,0,0,255], [255,255,255,255], [0,0,255,255], [0,255,0,255], [255,0,0,255]]
        for y in 0..<8 { for x in 0..<8 { for c in 0..<4 { pixels[y * rgbStride + x * 4 + c] = samples[min(x,4)][c] } } }
        CVPixelBufferUnlockBaseAddress(rgb, [])
        for peak in [100.0, 1000.0] {
            let source = SourceColorProfile(gamut: .rec709, oetf: .gamma24, yCbCrMatrixID: 0, peakNits: 100)
            let request = try ColorTransformRequest(gamut: "rec2020", oetf: "pq", nits: String(peak))
            let mapper = try MetalColorPipeline(transform: ResolvedColorTransform(input: source, request: request),
                width: 8, height: 8, pixelFormat: kCVPixelFormatType_32BGRA, outputPixelFormat: kCVPixelFormatType_64RGBAHalf)
            let mapped = try mapper.process(rgb, pts: .zero)
            CVPixelBufferLockBaseAddress(mapped, .readOnly)
            let values = CVPixelBufferGetBaseAddress(mapped)!.assumingMemoryBound(to: Float16.self)
            let white = (0..<3).map { pqNits(Double(values[4 + $0])) }
            if white.contains(where: { abs($0 - peak) > peak * 0.006 }) { failures += 1 }
            if (0..<3).contains(where: { pqNits(Double(values[$0])) > 0.001 }) { failures += 1 }
            if peak == 100 {
                let expected = [[0.627404,0.069097,0.0163916], [0.329283,0.919540,0.0880132], [0.043313,0.0113612,0.895595]]
                for primary in 0..<3 { for c in 0..<3 {
                    let actual = pqNits(Double(values[(primary + 2) * 4 + c])) / 100
                    if abs(actual - expected[primary][c]) > 0.004 { failures += 1 }
                } }
            }
            print("Shared Rec709->Rec2020/PQ white target=\(peak), independently decoded=\(white)")
            CVPixelBufferUnlockBaseAddress(mapped, .readOnly)
        }
        guard failures == 0 else { throw NSError(domain: "ColorContracts", code: failures) }
        print("Color pixel transport contracts passed")
    }
}
