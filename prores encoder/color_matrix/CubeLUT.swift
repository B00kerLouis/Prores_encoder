// Parses 1D, 3D, and combined .cube tables into GPU-uploadable RGB samples.

import Foundation
import simd

/// Structural and data-validation failures reported with source file and line context.
enum CubeLUTError: LocalizedError {
    case unreadable(URL, Error)
    case invalidEncoding(URL)
    case invalidDirective(URL, Int, String)
    case duplicateDirective(URL, Int, String)
    case invalidSize(URL, Int, String)
    case invalidDomain(URL, Int, String)
    case invalidSample(URL, Int)
    case unexpectedSample(URL, Int)
    case incompleteTable(URL, String, Int, Int)
    case missingTable(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url, let error):
            return "Could not read LUT '\(url.path)': \(error.localizedDescription)"
        case .invalidEncoding(let url):
            return "LUT '\(url.path)' must be UTF-8 text."
        case .invalidDirective(let url, let line, let directive):
            return "LUT '\(url.path)' has an invalid \(directive) directive at line \(line)."
        case .duplicateDirective(let url, let line, let directive):
            return "LUT '\(url.path)' repeats \(directive) at line \(line)."
        case .invalidSize(let url, let line, let directive):
            return "LUT '\(url.path)' has an invalid \(directive) at line \(line)."
        case .invalidDomain(let url, let line, let directive):
            return "LUT '\(url.path)' has an invalid \(directive) range at line \(line)."
        case .invalidSample(let url, let line):
            return "LUT '\(url.path)' has an invalid RGB sample at line \(line)."
        case .unexpectedSample(let url, let line):
            return "LUT '\(url.path)' has an unexpected RGB sample at line \(line)."
        case .incompleteTable(let url, let table, let actual, let expected):
            return "LUT '\(url.path)' has \(actual) \(table) samples; expected \(expected)."
        case .missingTable(let url):
            return "LUT '\(url.path)' contains neither LUT_1D_SIZE nor LUT_3D_SIZE."
        }
    }
}

/// One-dimensional RGB shaper table and its input domain.
struct CubeLUT1D: Sendable {
    let size: Int
    let values: [SIMD4<Float>]
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>

    var domainScale: SIMD3<Float> {
        SIMD3<Float>(
            1 / (domainMax.x - domainMin.x),
            1 / (domainMax.y - domainMin.y),
            1 / (domainMax.z - domainMin.z)
        )
    }
}

/// Three-dimensional RGB table in red-fastest storage order.
struct CubeLUT3D: Sendable {
    let size: Int
    // The .cube table stores red as the fastest-varying coordinate,
    // followed by green and blue.
    let values: [SIMD4<Float>]
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>

    var domainScale: SIMD3<Float> {
        SIMD3<Float>(
            1 / (domainMax.x - domainMin.x),
            1 / (domainMax.y - domainMin.y),
            1 / (domainMax.z - domainMin.z)
        )
    }
}

/// Parsed LUT container that may hold either or both table dimensions.
struct CubeLUT: Sendable {
    let sourceURL: URL
    let oneDimensional: CubeLUT1D?
    let threeDimensional: CubeLUT3D?

    /// Reads UTF-8 text, validates directives and sample counts, and builds table data.
    init(url: URL) throws {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadInapplicableStringEncoding {
            throw CubeLUTError.invalidEncoding(url)
        } catch {
            throw CubeLUTError.unreadable(url, error)
        }

        var oneDSize: Int?
        var threeDSize: Int?
        var oneDValues: [SIMD4<Float>] = []
        var threeDValues: [SIMD4<Float>] = []
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var oneDMin = SIMD3<Float>(repeating: 0)
        var oneDMax = SIMD3<Float>(repeating: 1)
        var threeDMin = SIMD3<Float>(repeating: 0)
        var threeDMax = SIMD3<Float>(repeating: 1)
        var hasOneDInputRange = false
        var hasThreeDInputRange = false

        for (offset, rawLine) in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).enumerated() {
            let lineNumber = offset + 1
            var line = String(rawLine)
            if lineNumber == 1 {
                line.removeFirstIfPresent("\u{FEFF}")
            }
            if let commentIndex = line.firstIndex(of: "#") {
                line = String(line[..<commentIndex])
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = fields.first else { continue }
            let directive = first.uppercased()

            switch directive {
            case "TITLE":
                continue
            case "LUT_1D_SIZE":
                guard oneDSize == nil else {
                    throw CubeLUTError.duplicateDirective(url, lineNumber, "LUT_1D_SIZE")
                }
                oneDSize = try Self.parseSize(
                    fields,
                    url: url,
                    line: lineNumber,
                    directive: "LUT_1D_SIZE"
                )
            case "LUT_3D_SIZE":
                guard threeDSize == nil else {
                    throw CubeLUTError.duplicateDirective(url, lineNumber, "LUT_3D_SIZE")
                }
                threeDSize = try Self.parseSize(
                    fields,
                    url: url,
                    line: lineNumber,
                    directive: "LUT_3D_SIZE"
                )
            case "DOMAIN_MIN":
                domainMin = try Self.parseVector(
                    fields,
                    url: url,
                    line: lineNumber,
                    directive: "DOMAIN_MIN"
                )
            case "DOMAIN_MAX":
                domainMax = try Self.parseVector(
                    fields,
                    url: url,
                    line: lineNumber,
                    directive: "DOMAIN_MAX"
                )
            case "LUT_1D_INPUT_RANGE":
                guard !hasOneDInputRange else {
                    throw CubeLUTError.duplicateDirective(url, lineNumber, "LUT_1D_INPUT_RANGE")
                }
                let range = try Self.parseRange(fields, url: url, line: lineNumber)
                oneDMin = SIMD3<Float>(repeating: range.0)
                oneDMax = SIMD3<Float>(repeating: range.1)
                hasOneDInputRange = true
            case "LUT_3D_INPUT_RANGE":
                guard !hasThreeDInputRange else {
                    throw CubeLUTError.duplicateDirective(url, lineNumber, "LUT_3D_INPUT_RANGE")
                }
                let range = try Self.parseRange(fields, url: url, line: lineNumber)
                threeDMin = SIMD3<Float>(repeating: range.0)
                threeDMax = SIMD3<Float>(repeating: range.1)
                hasThreeDInputRange = true
            default:
                guard Self.looksLikeSample(fields) else {
                    // Unrecognized metadata has no bearing on the RGB table
                    // and is intentionally ignored.
                    continue
                }
                guard fields.count == 3,
                      let value = Self.parseSample(fields) else {
                    throw CubeLUTError.invalidSample(url, lineNumber)
                }
                if let oneDSize, oneDValues.count < oneDSize {
                    oneDValues.append(value)
                } else {
                    guard let threeDSize else {
                        throw CubeLUTError.unexpectedSample(url, lineNumber)
                    }
                    let expected = try Self.sampleCount(for: threeDSize, url: url, line: lineNumber)
                    guard threeDValues.count < expected else {
                        throw CubeLUTError.unexpectedSample(url, lineNumber)
                    }
                    threeDValues.append(value)
                }
            }
        }

        guard oneDSize != nil || threeDSize != nil else {
            throw CubeLUTError.missingTable(url)
        }
        try Self.validateDomain(domainMin, max: domainMax, url: url, line: 0, directive: "DOMAIN")
        if hasOneDInputRange {
            try Self.validateDomain(oneDMin, max: oneDMax, url: url, line: 0, directive: "LUT_1D_INPUT_RANGE")
        }
        if hasThreeDInputRange {
            try Self.validateDomain(threeDMin, max: threeDMax, url: url, line: 0, directive: "LUT_3D_INPUT_RANGE")
        }

        if let oneDSize, oneDValues.count != oneDSize {
            throw CubeLUTError.incompleteTable(url, "1D", oneDValues.count, oneDSize)
        }
        if let threeDSize {
            let expected = try Self.sampleCount(for: threeDSize, url: url, line: 0)
            guard threeDValues.count == expected else {
                throw CubeLUTError.incompleteTable(url, "3D", threeDValues.count, expected)
            }
        }

        sourceURL = url
        oneDimensional = oneDSize.map {
            CubeLUT1D(
                size: $0,
                values: oneDValues,
                domainMin: hasOneDInputRange ? oneDMin : domainMin,
                domainMax: hasOneDInputRange ? oneDMax : domainMax
            )
        }
        threeDimensional = threeDSize.map {
            CubeLUT3D(
                size: $0,
                values: threeDValues,
                domainMin: hasThreeDInputRange ? threeDMin : domainMin,
                domainMax: hasThreeDInputRange ? threeDMax : domainMax
            )
        }
    }

    /// Parses a table-size directive and checks 3D sample-count overflow.
    private static func parseSize(
        _ fields: [Substring],
        url: URL,
        line: Int,
        directive: String
    ) throws -> Int {
        guard fields.count == 2,
              let size = Int(fields[1]),
              size >= 2 else {
            throw CubeLUTError.invalidSize(url, line, directive)
        }
        if directive == "LUT_3D_SIZE" {
            _ = try sampleCount(for: size, url: url, line: line)
        }
        return size
    }

    /// Parses a finite three-component domain vector.
    private static func parseVector(
        _ fields: [Substring],
        url: URL,
        line: Int,
        directive: String
    ) throws -> SIMD3<Float> {
        guard fields.count == 4,
              let x = Float(fields[1]), let y = Float(fields[2]), let z = Float(fields[3]),
              x.isFinite, y.isFinite, z.isFinite else {
            throw CubeLUTError.invalidDirective(url, line, directive)
        }
        return SIMD3<Float>(x, y, z)
    }

    /// Parses a finite scalar input range with increasing endpoints.
    private static func parseRange(
        _ fields: [Substring],
        url: URL,
        line: Int
    ) throws -> (Float, Float) {
        guard fields.count == 3,
              let min = Float(fields[1]), let max = Float(fields[2]),
              min.isFinite, max.isFinite, min < max else {
            throw CubeLUTError.invalidDirective(url, line, "LUT input range")
        }
        return (min, max)
    }

    /// Parses one finite RGB table row and supplies an opaque alpha component.
    private static func parseSample(_ fields: [Substring]) -> SIMD4<Float>? {
        guard let red = Float(fields[0]), let green = Float(fields[1]), let blue = Float(fields[2]),
              red.isFinite, green.isFinite, blue.isFinite else {
            return nil
        }
        return SIMD4<Float>(red, green, blue, 1)
    }

    /// Distinguishes numeric table rows from ignorable alphabetic metadata.
    private static func looksLikeSample(_ fields: [Substring]) -> Bool {
        guard let token = fields.first, let first = token.first else { return false }
        if first.isNumber || first == "+" || first == "-" || first == "." {
            return true
        }
        switch token.lowercased() {
        case "nan", "inf", "infinity":
            return true
        default:
            return false
        }
    }

    /// Computes `size` cubed while rejecting integer overflow.
    private static func sampleCount(for size: Int, url: URL, line: Int) throws -> Int {
        let (squared, squareOverflow) = size.multipliedReportingOverflow(by: size)
        let (count, countOverflow) = squared.multipliedReportingOverflow(by: size)
        guard !squareOverflow, !countOverflow else {
            throw CubeLUTError.invalidSize(url, line, "LUT_3D_SIZE")
        }
        return count
    }

    /// Ensures every domain axis has finite, increasing endpoints.
    private static func validateDomain(
        _ min: SIMD3<Float>,
        max: SIMD3<Float>,
        url: URL,
        line: Int,
        directive: String
    ) throws {
        guard min.x.isFinite, min.y.isFinite, min.z.isFinite,
              max.x.isFinite, max.y.isFinite, max.z.isFinite,
              min.x < max.x, min.y < max.y, min.z < max.z else {
            throw CubeLUTError.invalidDomain(url, line, directive)
        }
    }
}

/// Helpers used while normalizing text-file prefixes.
private extension String {
    /// Removes a leading marker only when it is present.
    mutating func removeFirstIfPresent(_ value: Character) {
        if first == value {
            removeFirst()
        }
    }
}
