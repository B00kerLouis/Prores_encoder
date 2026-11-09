// B00kerLouis. Framework-only spatial planning; pure CPU geometry.
import Foundation

public enum ProResSpatialError: LocalizedError {
    case invalidGeometry(String), unsupportedInput(String), invalidCommand(String), metal(String)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry(let s), .unsupportedInput(let s), .invalidCommand(let s), .metal(let s): return s
        case .cancelled: return "The spatial processor is cancelled."
        }
    }
}

public struct ProResSpatialSize: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// Pixel-edge coordinates, top-left origin. Fractional rectangles describe
/// ideal geometry; the raster kernel samples destination pixel centers.
public struct ProResSpatialRect: Sendable, Equatable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double = 0, y: Double = 0, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct ProResSpatialPixelAspect: Sendable, Equatable {
    public let horizontalSpacing: Int
    public let verticalSpacing: Int
    public init(horizontalSpacing: Int = 1, verticalSpacing: Int = 1) {
        self.horizontalSpacing = horizontalSpacing; self.verticalSpacing = verticalSpacing
    }
}

/// A declaration of actual raster geometry. Only square-pixel, full-aperture,
/// top-left raster input is supported. An omitted aperture declares full raster;
/// actual CVPixelBuffer attachments are checked again before GPU encoding.
public struct ProResSpatialSourceGeometry: Sendable, Equatable {
    public let raster: ProResSpatialSize
    public let pixelAspect: ProResSpatialPixelAspect
    public let cleanAperture: ProResSpatialRect?
    public init(width: Int, height: Int, pixelAspect: ProResSpatialPixelAspect = .init(),
                cleanAperture: ProResSpatialRect? = nil) {
        raster = .init(width: width, height: height); self.pixelAspect = pixelAspect
        self.cleanAperture = cleanAperture
    }
}

public enum ProResSpatialTarget: Sendable, Equatable {
    case source
    case dci2KFull, dci2KFlat, dci2KScope
    case dci4KFull, dci4KFlat, dci4KScope
    case uhd, fullHD
    case custom(width: Int, height: Int)

    public func size(source: ProResSpatialSize) -> ProResSpatialSize {
        switch self {
        case .source: return source
        case .dci2KFull: return .init(width: 2048, height: 1080)
        case .dci2KFlat: return .init(width: 1998, height: 1080)
        case .dci2KScope: return .init(width: 2048, height: 858)
        case .dci4KFull: return .init(width: 4096, height: 2160)
        case .dci4KFlat: return .init(width: 3996, height: 2160)
        case .dci4KScope: return .init(width: 4096, height: 1716)
        case .uhd: return .init(width: 3840, height: 2160)
        case .fullHD: return .init(width: 1920, height: 1080)
        case .custom(let width, let height): return .init(width: width, height: height)
        }
    }
}

public enum ProResSpatialMode: String, Sendable, CaseIterable {
    /// Uniform scale, centered black/transparent padding where needed.
    case fit
    /// Uniform scale, centered crop where needed.
    case fill
    /// Pixel-aligned 1:1 centered crop; target cannot exceed source on either axis.
    case crop
    /// Pixel-aligned 1:1 centered padding; target cannot be smaller on either axis.
    case pad
}

public enum ProResSpatialInterpolationDomain: String, Sendable { case linearLight, encoded }
public enum ProResSpatialInputReadiness: String, Sendable { case completed, sameCommandBuffer }
/// Straight RGB/alpha is resampled using premultiplied accumulation and
/// unpremultiplied output. Premultiplied input must be normalized by its producer.
public enum ProResSpatialAlpha: String, Sendable { case straight, opaque }
public enum ProResSpatialPadding: String, Sendable { case opaqueBlack, transparentBlack }

/// Checked before any GPU/pool allocation. Kept in the CPU geometry module so
/// hostile public stride/capacity values can be tested without a Metal device.
enum SpatialWorkingSetBudget {
    static let limit: Int64 = 1_073_741_824
    static func planeBytes(row: Int, height: Int) throws -> Int64 {
        guard row > 0, height > 0 else { throw ProResSpatialError.invalidGeometry("Invalid spatial plane bound.") }
        let (product, overflow) = Int64(row).multipliedReportingOverflow(by: Int64(height))
        let (padded, paddingOverflow) = product.addingReportingOverflow(4096)
        guard !overflow, !paddingOverflow, padded > 0, padded <= limit else { throw ProResSpatialError.invalidGeometry("Spatial stride/data bound exceeds 1 GiB or overflows.") }
        return padded
    }
    static func total(source: Int64, output: Int64, capacity: Int) throws -> Int64 {
        guard source >= 0, output >= 0, (2...16).contains(capacity) else { throw ProResSpatialError.invalidGeometry("Invalid spatial capacity/buffer bound.") }
        let (sum, sumOverflow) = source.addingReportingOverflow(output)
        let (bytes, multiplyOverflow) = sum.multipliedReportingOverflow(by: Int64(capacity))
        guard !sumOverflow, !multiplyOverflow, bytes >= 0, bytes <= limit else { throw ProResSpatialError.invalidGeometry("Spatial retained source/output working set exceeds 1 GiB or overflows.") }
        return bytes
    }
}

public struct ProResSpatialPlan: Sendable, Equatable {
    public let source: ProResSpatialSourceGeometry
    public let canvas: ProResSpatialSize
    public let target: ProResSpatialTarget
    public let mode: ProResSpatialMode
    public let scale: Double
    /// The complete scaled source rectangle; fill/crop may extend beyond canvas.
    public let contentRect: ProResSpatialRect
    /// Intersection of content with canvas, suitable for caller/UI active picture.
    public let activeContentRect: ProResSpatialRect
    /// Visible subset of the original source raster.
    public let sourceVisibleRect: ProResSpatialRect
    public let isPassthrough: Bool
    public let isPixelAlignedUnitScale: Bool

    public init(source: ProResSpatialSourceGeometry, target: ProResSpatialTarget = .source,
                mode: ProResSpatialMode = .fit) throws {
        let input = source.raster, output = target.size(source: input)
        for size in [input, output] {
            guard size.width > 0, size.height > 0, size.width <= 16384, size.height <= 16384,
                  size.width.isMultiple(of: 2), size.height.isMultiple(of: 2) else {
                throw ProResSpatialError.invalidGeometry("Spatial geometry requires positive even dimensions <= 16384.")
            }
        }
        guard source.pixelAspect.horizontalSpacing > 0,
              source.pixelAspect.verticalSpacing > 0,
              source.pixelAspect.horizontalSpacing == source.pixelAspect.verticalSpacing else {
            throw ProResSpatialError.unsupportedInput("Spatial processing supports square pixels only; non-square PAR must be normalized explicitly by the producer.")
        }
        let full = ProResSpatialRect(width: Double(input.width), height: Double(input.height))
        if let aperture = source.cleanAperture, aperture != full {
            throw ProResSpatialError.unsupportedInput("Spatial processing supports full clean aperture only; cropped/offset aperture must be normalized explicitly by the producer.")
        }
        let sx = Double(output.width) / Double(input.width)
        let sy = Double(output.height) / Double(input.height)
        let factor: Double
        switch mode {
        case .fit: factor = min(sx, sy)
        case .fill: factor = max(sx, sy)
        case .crop:
            guard output.width <= input.width, output.height <= input.height else { throw ProResSpatialError.invalidGeometry("Crop is 1:1 and cannot enlarge either source axis.") }
            factor = 1
        case .pad:
            guard output.width >= input.width, output.height >= input.height else { throw ProResSpatialError.invalidGeometry("Pad is 1:1 and cannot reduce either source axis.") }
            factor = 1
        }
        let cw = Double(input.width) * factor, ch = Double(input.height) * factor
        let cx = (Double(output.width) - cw) / 2, cy = (Double(output.height) - ch) / 2
        let ax = max(0, cx), ay = max(0, cy)
        let aw = max(0, min(Double(output.width), cx + cw) - ax)
        let ah = max(0, min(Double(output.height), cy + ch) - ay)
        self.source = source; self.canvas = output; self.target = target; self.mode = mode
        scale = factor
        contentRect = .init(x: cx, y: cy, width: cw, height: ch)
        activeContentRect = .init(x: ax, y: ay, width: aw, height: ah)
        let vx = max(0, (ax - cx) / factor), vy = max(0, (ay - cy) / factor)
        sourceVisibleRect = .init(x: vx, y: vy, width: min(Double(input.width) - vx, aw / factor), height: min(Double(input.height) - vy, ah / factor))
        isPassthrough = input == output && factor == 1 && cx == 0 && cy == 0
        isPixelAlignedUnitScale = factor == 1 && cx.rounded() == cx && cy.rounded() == cy
    }
}
