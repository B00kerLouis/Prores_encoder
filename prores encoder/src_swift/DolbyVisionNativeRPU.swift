import Foundation
import AVFoundation
import CoreMedia

private enum NativeDolbyVisionCMVersion {
    case v29
    case v40
}

private struct NativeDolbyVisionTargetDisplay {
    let id: UInt8
    let peakNits: UInt16
    let minNits: Double
    let primaries: [Double]
}

private struct NativeDolbyVisionFrameEdit {
    let editOffset: Int
    let blocks: [NativeDolbyVisionMetadataBlock]
}

private struct NativeDolbyVisionShotDefinition {
    let start: Int
    let duration: Int
    let blocks: [NativeDolbyVisionMetadataBlock]
    let frameEdits: [NativeDolbyVisionFrameEdit]
}

private struct NativeDolbyVisionConfig {
    let cmVersion: NativeDolbyVisionCMVersion
    let sourceMinPQ: UInt16?
    let sourceMaxPQ: UInt16?
    let level6: NativeLevel6Block?
    let defaultMetadataBlocks: [NativeDolbyVisionMetadataBlock]
    let shots: [NativeDolbyVisionShotDefinition]
}

private struct NativeLevel1Block {
    var minPQ: UInt16
    var maxPQ: UInt16
    var avgPQ: UInt16
}

private struct NativeLevel2Block {
    let targetMaxPQ: UInt16
    let trimSlope: UInt16
    let trimOffset: UInt16
    let trimPower: UInt16
    let trimChromaWeight: UInt16
    let trimSaturationGain: UInt16
    let msWeight: Int16
}

private struct NativeLevel3Block {
    let minPQOffset: UInt16
    let avgPQOffset: UInt16
    let maxPQOffset: UInt16
}

private struct NativeLevel4Block {
    let anchorPQ: UInt16
    let anchorPower: UInt16
}

private struct NativeLevel5Block {
    let leftOffset: UInt16
    let rightOffset: UInt16
    let topOffset: UInt16
    let bottomOffset: UInt16
}

private struct NativeLevel6Block {
    let maxDisplayMasteringLuminance: UInt16
    let minDisplayMasteringLuminance: UInt16
    let maxContentLightLevel: UInt16
    let maxFrameAverageLightLevel: UInt16

    func sourceMetaFromLevel6() -> (UInt16, UInt16) {
        let sourceMinPQ: UInt16
        switch minDisplayMasteringLuminance {
        case 0...10:
            sourceMinPQ = 7
        case 50:
            sourceMinPQ = 62
        default:
            sourceMinPQ = 0
        }

        let sourceMaxPQ: UInt16
        switch maxDisplayMasteringLuminance {
        case 1000:
            sourceMaxPQ = 3079
        case 2000:
            sourceMaxPQ = 3388
        case 4000:
            sourceMaxPQ = 3696
        case 10000:
            sourceMaxPQ = 4095
        default:
            sourceMaxPQ = 3079
        }
        return (sourceMinPQ, sourceMaxPQ)
    }
}

private struct NativeLevel8Block {
    let length: UInt64
    let targetDisplayIndex: UInt8
    let trimSlope: UInt16
    let trimOffset: UInt16
    let trimPower: UInt16
    let trimChromaWeight: UInt16
    let trimSaturationGain: UInt16
    let msWeight: UInt16
    let targetMidContrast: UInt16
    let clipTrim: UInt16
    let saturationVectorField: [UInt8]
    let hueVectorField: [UInt8]
}

private struct NativeLevel9Block {
    let length: UInt64
    let sourcePrimaryIndex: UInt8
    let primaries: [UInt16]
}

private struct NativeLevel10Block {
    let length: UInt64
    let targetDisplayIndex: UInt8
    let targetMaxPQ: UInt16
    let targetMinPQ: UInt16
    let targetPrimaryIndex: UInt8
    let primaries: [UInt16]
}

private struct NativeLevel11Block {
    let contentType: UInt8
    let whitePoint: UInt8
    let referenceModeFlag: Bool
}

private struct NativeLevel254Block {
    let dmMode: UInt8
    let dmVersionIndex: UInt8
}

private enum NativeDolbyVisionMetadataBlock {
    case level1(NativeLevel1Block)
    case level2(NativeLevel2Block)
    case level3(NativeLevel3Block)
    case level4(NativeLevel4Block)
    case level5(NativeLevel5Block)
    case level6(NativeLevel6Block)
    case level8(NativeLevel8Block)
    case level9(NativeLevel9Block)
    case level10(NativeLevel10Block)
    case level11(NativeLevel11Block)
    case level254(NativeLevel254Block)

    var level: UInt8 {
        switch self {
        case .level1: return 1
        case .level2: return 2
        case .level3: return 3
        case .level4: return 4
        case .level5: return 5
        case .level6: return 6
        case .level8: return 8
        case .level9: return 9
        case .level10: return 10
        case .level11: return 11
        case .level254: return 254
        }
    }

    var lengthBytes: UInt64 {
        switch self {
        case .level1: return 5
        case .level2: return 11
        case .level3: return 5
        case .level4: return 3
        case .level5: return 7
        case .level6: return 8
        case .level8(let block): return block.length
        case .level9(let block): return block.length
        case .level10(let block): return block.length
        case .level11: return 4
        case .level254: return 2
        }
    }

    var requiredBits: UInt64 {
        switch self {
        case .level1: return 36
        case .level2: return 85
        case .level3: return 36
        case .level4: return 24
        case .level5: return 52
        case .level6: return 64
        case .level8(let block):
            switch block.length {
            case 10: return 80
            case 12: return 92
            case 13: return 104
            case 19: return 152
            default: return 200
            }
        case .level9(let block):
            return block.length == 1 ? 8 : 136
        case .level10(let block):
            return block.length == 5 ? 40 : 168
        case .level11: return 32
        case .level254: return 16
        }
    }

    var sortKey: (UInt8, UInt16) {
        switch self {
        case .level2(let block):
            return (level, block.targetMaxPQ)
        case .level8(let block):
            return (level, UInt16(block.targetDisplayIndex))
        case .level9(let block):
            return (level, UInt16(block.sourcePrimaryIndex))
        case .level10(let block):
            return (level, UInt16(block.targetDisplayIndex))
        default:
            return (level, 0)
        }
    }

    func writeBody(to writer: inout NativeDolbyVisionBitWriter) {
        switch self {
        case .level1(let block):
            writer.write(UInt64(block.minPQ), bits: 12)
            writer.write(UInt64(block.maxPQ), bits: 12)
            writer.write(UInt64(block.avgPQ), bits: 12)
        case .level2(let block):
            writer.write(UInt64(block.targetMaxPQ), bits: 12)
            writer.write(UInt64(block.trimSlope), bits: 12)
            writer.write(UInt64(block.trimOffset), bits: 12)
            writer.write(UInt64(block.trimPower), bits: 12)
            writer.write(UInt64(block.trimChromaWeight), bits: 12)
            writer.write(UInt64(block.trimSaturationGain), bits: 12)
            writer.writeSigned(Int64(block.msWeight), bits: 13)
        case .level3(let block):
            writer.write(UInt64(block.minPQOffset), bits: 12)
            writer.write(UInt64(block.maxPQOffset), bits: 12)
            writer.write(UInt64(block.avgPQOffset), bits: 12)
        case .level4(let block):
            writer.write(UInt64(block.anchorPQ), bits: 12)
            writer.write(UInt64(block.anchorPower), bits: 12)
        case .level5(let block):
            writer.write(UInt64(block.leftOffset), bits: 13)
            writer.write(UInt64(block.rightOffset), bits: 13)
            writer.write(UInt64(block.topOffset), bits: 13)
            writer.write(UInt64(block.bottomOffset), bits: 13)
        case .level6(let block):
            writer.write(UInt64(block.maxDisplayMasteringLuminance), bits: 16)
            writer.write(UInt64(block.minDisplayMasteringLuminance), bits: 16)
            writer.write(UInt64(block.maxContentLightLevel), bits: 16)
            writer.write(UInt64(block.maxFrameAverageLightLevel), bits: 16)
        case .level8(let block):
            writer.write(UInt64(block.targetDisplayIndex), bits: 8)
            writer.write(UInt64(block.trimSlope), bits: 12)
            writer.write(UInt64(block.trimOffset), bits: 12)
            writer.write(UInt64(block.trimPower), bits: 12)
            writer.write(UInt64(block.trimChromaWeight), bits: 12)
            writer.write(UInt64(block.trimSaturationGain), bits: 12)
            writer.write(UInt64(block.msWeight), bits: 12)
            if block.length > 10 {
                writer.write(UInt64(block.targetMidContrast), bits: 12)
            }
            if block.length > 12 {
                writer.write(UInt64(block.clipTrim), bits: 12)
            }
            if block.length > 13 {
                block.saturationVectorField.forEach { writer.write(UInt64($0), bits: 8) }
            }
            if block.length > 19 {
                block.hueVectorField.forEach { writer.write(UInt64($0), bits: 8) }
            }
        case .level9(let block):
            writer.write(UInt64(block.sourcePrimaryIndex), bits: 8)
            if block.length > 1 {
                block.primaries.forEach { writer.write(UInt64($0), bits: 16) }
            }
        case .level10(let block):
            writer.write(UInt64(block.targetDisplayIndex), bits: 8)
            writer.write(UInt64(block.targetMaxPQ), bits: 12)
            writer.write(UInt64(block.targetMinPQ), bits: 12)
            writer.write(UInt64(block.targetPrimaryIndex), bits: 8)
            if block.length > 5 {
                block.primaries.forEach { writer.write(UInt64($0), bits: 16) }
            }
        case .level11(let block):
            writer.write(UInt64(block.contentType), bits: 8)
            let byte1 = (UInt8(block.referenceModeFlag ? 1 : 0) << 4) | (block.whitePoint & 0x0f)
            writer.write(UInt64(byte1), bits: 8)
            writer.write(0, bits: 8)
            writer.write(0, bits: 8)
        case .level254(let block):
            writer.write(UInt64(block.dmMode), bits: 8)
            writer.write(UInt64(block.dmVersionIndex), bits: 8)
        }
    }
}

private struct NativeDolbyVisionDMContainer {
    var blocks: [NativeDolbyVisionMetadataBlock]

    mutating func replace(_ block: NativeDolbyVisionMetadataBlock) {
        switch block {
        case .level2(let newBlock):
            let key = newBlock.targetMaxPQ
            if let index = blocks.firstIndex(where: {
                if case .level2(let existing) = $0 {
                    return existing.targetMaxPQ == key
                }
                return false
            }) {
                blocks[index] = block
            } else {
                blocks.append(block)
            }
        case .level8(let newBlock):
            let key = newBlock.targetDisplayIndex
            if let index = blocks.firstIndex(where: {
                if case .level8(let existing) = $0 {
                    return existing.targetDisplayIndex == key
                }
                return false
            }) {
                blocks[index] = block
            } else {
                blocks.append(block)
            }
        case .level10(let newBlock):
            let key = newBlock.targetDisplayIndex
            if let index = blocks.firstIndex(where: {
                if case .level10(let existing) = $0 {
                    return existing.targetDisplayIndex == key
                }
                return false
            }) {
                blocks[index] = block
            } else {
                blocks.append(block)
            }
        default:
            blocks.removeAll { $0.level == block.level }
            blocks.append(block)
        }
    }

    func sortedBlocks() -> [NativeDolbyVisionMetadataBlock] {
        blocks.sorted { lhs, rhs in
            if lhs.sortKey.0 == rhs.sortKey.0 {
                return lhs.sortKey.1 < rhs.sortKey.1
            }
            return lhs.sortKey.0 < rhs.sortKey.0
        }
    }

    func write(to writer: inout NativeDolbyVisionBitWriter) {
        let sorted = sortedBlocks()
        writer.writeUE(UInt64(sorted.count))
        writer.byteAlignZero()
        for block in sorted {
            writer.writeUE(block.lengthBytes)
            writer.write(UInt64(block.level), bits: 8)
            let startBits = writer.bitCount
            block.writeBody(to: &writer)
            let usedBits = writer.bitCount - startBits
            let padBits = Int((block.lengthBytes * 8) - UInt64(usedBits))
            if padBits > 0 {
                writer.write(0, bits: padBits)
            }
        }
    }
}

private struct NativeDolbyVisionVdrDmData {
    let affectedMetadataID: UInt64 = 0
    let currentMetadataID: UInt64 = 0
    let sceneRefreshFlag: UInt64
    let yccToRgbCoefficients: [Int16] = [9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0]
    let yccToRgbOffsets: [UInt32] = [16777216, 134217728, 134217728]
    let rgbToLmsCoefficients: [Int16] = [7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962]
    let signalEOTF: UInt16 = 65535
    let signalEOTFParam0: UInt16 = 0
    let signalEOTFParam1: UInt16 = 0
    let signalEOTFParam2: UInt32 = 0
    let signalBitDepth: UInt8 = 12
    let signalColorSpace: UInt8 = 0
    let signalChromaFormat: UInt8 = 0
    let signalFullRangeFlag: UInt8 = 1
    let sourceMinPQ: UInt16
    let sourceMaxPQ: UInt16
    let sourceDiagonal: UInt16 = 42
    var cmv29: NativeDolbyVisionDMContainer
    var cmv40: NativeDolbyVisionDMContainer?

    func write(to writer: inout NativeDolbyVisionBitWriter) {
        writer.writeUE(affectedMetadataID)
        writer.writeUE(currentMetadataID)
        writer.writeUE(sceneRefreshFlag)
        yccToRgbCoefficients.forEach { writer.writeSigned(Int64($0), bits: 16) }
        yccToRgbOffsets.forEach { writer.write(UInt64($0), bits: 32) }
        rgbToLmsCoefficients.forEach { writer.writeSigned(Int64($0), bits: 16) }
        writer.write(UInt64(signalEOTF), bits: 16)
        writer.write(UInt64(signalEOTFParam0), bits: 16)
        writer.write(UInt64(signalEOTFParam1), bits: 16)
        writer.write(UInt64(signalEOTFParam2), bits: 32)
        writer.write(UInt64(signalBitDepth), bits: 5)
        writer.write(UInt64(signalColorSpace), bits: 2)
        writer.write(UInt64(signalChromaFormat), bits: 2)
        writer.write(UInt64(signalFullRangeFlag), bits: 2)
        writer.write(UInt64(sourceMinPQ), bits: 12)
        writer.write(UInt64(sourceMaxPQ), bits: 12)
        writer.write(UInt64(sourceDiagonal), bits: 10)
        cmv29.write(to: &writer)
        cmv40?.write(to: &writer)
    }
}

private struct NativeDolbyVisionRPUBuilder {
    private let config: NativeDolbyVisionConfig
    private let profile: DolbyVisionHEVCProfile

    init(config: NativeDolbyVisionConfig, profile: DolbyVisionHEVCProfile) {
        self.config = config
        self.profile = profile
    }

    func generate() throws -> [Data] {
        let sortedShots = config.shots.sorted { $0.start < $1.start }
        let totalFrames = sortedShots.reduce(0) { $0 + $1.duration }
        var rpus: [Data] = []
        rpus.reserveCapacity(totalFrames)

        for shot in sortedShots {
            for frameOffset in 0..<shot.duration {
                let frameBlocks = shot.frameEdits.first(where: { $0.editOffset == frameOffset })?.blocks ?? []
                let rpu = try buildFrameRPU(
                    sceneRefresh: frameOffset == 0,
                    shotBlocks: shot.blocks,
                    frameBlocks: frameBlocks
                )
                rpus.append(rpu)
            }
        }
        return rpus
    }

    private func buildFrameRPU(
        sceneRefresh: Bool,
        shotBlocks: [NativeDolbyVisionMetadataBlock],
        frameBlocks: [NativeDolbyVisionMetadataBlock]
    ) throws -> Data {
        let dmData = makeVdrDmData(
            sceneRefresh: sceneRefresh,
            shotBlocks: shotBlocks,
            frameBlocks: frameBlocks
        )

        var writer = NativeDolbyVisionBitWriter()
        writer.write(0x19, bits: 8)
        writeHeader(to: &writer)
        writeMapping(to: &writer)
        dmData.write(to: &writer)
        writer.byteAlignZero()
        let crc = nativeDolbyVisionCRC32(writer.data.dropFirst())
        writer.write(UInt64(crc), bits: 32)
        writer.write(0x80, bits: 8)

        var payload = writer.data
        nativeAddStartCodeEmulationPrevention(to: &payload)
        payload.insert(0x01, at: payload.startIndex)
        payload.insert(0x7c, at: payload.startIndex)
        return payload
    }

    private func makeVdrDmData(
        sceneRefresh: Bool,
        shotBlocks: [NativeDolbyVisionMetadataBlock],
        frameBlocks: [NativeDolbyVisionMetadataBlock]
    ) -> NativeDolbyVisionVdrDmData {
        var cmv29Blocks: [NativeDolbyVisionMetadataBlock] = []
        var cmv40Blocks: [NativeDolbyVisionMetadataBlock] = []

        let allBlocks = config.defaultMetadataBlocks + shotBlocks + frameBlocks
        let initialLevel6 = config.level6
        allBlocks.forEach {
            switch $0.level {
            case 1, 2, 4, 5, 6:
                var container = NativeDolbyVisionDMContainer(blocks: cmv29Blocks)
                container.replace($0)
                cmv29Blocks = container.blocks
            case 3, 8, 9, 10, 11, 254:
                var container = NativeDolbyVisionDMContainer(blocks: cmv40Blocks)
                container.replace($0)
                cmv40Blocks = container.blocks
            default:
                break
            }
        }

        if let initialLevel6,
           !cmv29Blocks.contains(where: {
               if case .level6 = $0 { return true }
               return false
           }) {
            var container = NativeDolbyVisionDMContainer(blocks: cmv29Blocks)
            container.replace(.level6(initialLevel6))
            cmv29Blocks = container.blocks
        }

        let level6 = cmv29Blocks.first {
            if case .level6 = $0 { return true }
            return false
        }.flatMap {
            if case .level6(let block) = $0 { return block }
            return nil
        } ?? initialLevel6

        // Match dovi_tool generation: Profile 8.4 starts from its HLG defaults,
        // then explicit source levels from the authoring metadata override them.
        var sourceMinPQ: UInt16 = profile.usesProfile84Mapping ? 62 : 0
        var sourceMaxPQ: UInt16 = profile.usesProfile84Mapping ? 3079 : 0
        if let configuredMinPQ = config.sourceMinPQ {
            sourceMinPQ = configuredMinPQ
        }
        if let configuredMaxPQ = config.sourceMaxPQ {
            sourceMaxPQ = configuredMaxPQ
        }
        if let level6 {
            let derived = level6.sourceMetaFromLevel6()
            if sourceMinPQ == 0 { sourceMinPQ = derived.0 }
            if sourceMaxPQ == 0 { sourceMaxPQ = derived.1 }
        }

        return NativeDolbyVisionVdrDmData(
            sceneRefreshFlag: sceneRefresh ? 1 : 0,
            sourceMinPQ: sourceMinPQ,
            sourceMaxPQ: sourceMaxPQ,
            cmv29: NativeDolbyVisionDMContainer(blocks: cmv29Blocks),
            cmv40: config.cmVersion == .v40 ? NativeDolbyVisionDMContainer(blocks: cmv40Blocks) : nil
        )
    }

    private func writeHeader(to writer: inout NativeDolbyVisionBitWriter) {
        writer.write(2, bits: 6)
        writer.write(18, bits: 11)
        writer.write(1, bits: 4)
        writer.write(0, bits: 4)
        writer.writeBit(true)
        writer.writeBit(false)
        writer.write(0, bits: 2)
        writer.writeUE(23)
        writer.write(1, bits: 2)
        writer.writeBit(false)
        writer.writeUE(2)
        writer.writeUE(2)
        writer.writeUE(4)
        writer.writeBit(false)
        writer.write(0, bits: 3)
        writer.writeBit(false)
        writer.writeBit(true)
        writer.writeBit(true)
        writer.writeBit(false)
    }

    private func writeMapping(to writer: inout NativeDolbyVisionBitWriter) {
        if profile.usesProfile84Mapping {
            writeProfile84Mapping(to: &writer)
        } else {
            writeProfile81Mapping(to: &writer)
        }
    }

    private func writeProfile81Mapping(to writer: inout NativeDolbyVisionBitWriter) {
        writer.writeUE(0)
        writer.writeUE(0)
        writer.writeUE(0)
        for _ in 0..<3 {
            writer.writeUE(0)
            writer.write(0, bits: 10)
            writer.write(1023, bits: 10)
        }
        writer.writeUE(0)
        writer.writeUE(0)
        for _ in 0..<3 {
            writer.writeUE(0)
            writer.writeUE(0)
            writer.writeBit(false)
            writer.writeSE(0)
            writer.write(0, bits: 23)
            writer.writeSE(1)
            writer.write(0, bits: 23)
        }
    }

    private func writeProfile84Mapping(to writer: inout NativeDolbyVisionBitWriter) {
        writer.writeUE(0) // vdr_rpu_id
        writer.writeUE(0) // mapping_color_space
        writer.writeUE(0) // mapping_chroma_format_idc

        writer.writeUE(7)
        [63, 69, 230, 256, 256, 37, 16, 8, 7].forEach {
            writer.write(UInt64($0), bits: 10)
        }
        for _ in 0..<2 {
            writer.writeUE(0)
            writer.write(0, bits: 10)
            writer.write(1023, bits: 10)
        }

        writer.writeUE(0) // num_x_partitions_minus1
        writer.writeUE(0) // num_y_partitions_minus1

        let lumaCoefficientIntegers: [[Int64]] = [
            [-1, 1, -3],
            [-1, 1, -2],
            [0, 0, -1],
            [0, 0, 0],
            [0, -2, 1],
            [6, -14, 8],
            [13, -30, 16],
            [28, -62, 34]
        ]
        let lumaCoefficients: [[UInt64]] = [
            [7_978_928, 8_332_855, 4_889_184],
            [8_269_552, 5_186_604, 3_909_327],
            [1_317_527, 5_338_528, 7_440_486],
            [2_119_979, 2_065_496, 2_288_524],
            [7_982_780, 5_409_990, 1_585_336],
            [3_460_436, 3_197_328, 615_464],
            [3_921_968, 6_820_672, 5_546_752],
            [1_947_392, 1_244_640, 6_094_272]
        ]
        for piece in 0..<8 {
            writer.writeUE(0) // Polynomial mapping
            writer.writeUE(1) // poly_order_minus1
            for coefficient in 0..<3 {
                writer.writeSE(lumaCoefficientIntegers[piece][coefficient])
                writer.write(lumaCoefficients[piece][coefficient], bits: 23)
            }
        }

        writeProfile84ChromaMMR(
            constantInteger: 1,
            constant: 1_150_183,
            coefficientIntegers: [
                [-1, -2, -5, 2, 5, 9, -12],
                [-1, -1, 3, -1, -5, -12, 18],
                [-1, 0, -2, 0, 2, 7, -19]
            ],
            coefficients: [
                [87_355, 6_228_986, 642_500, 1_023_296, 6_569_512, 5_128_216, 4_317_296],
                [8_299_905, 5_819_931, 2_324_124, 7_273_546, 1_562_484, 3_679_480, 6_357_360],
                [8_172_981, 3_261_951, 5_970_055, 927_142, 3_525_840, 5_110_348, 6_236_848]
            ],
            to: &writer
        )
        writeProfile84ChromaMMR(
            constantInteger: -2,
            constant: 6_266_112,
            coefficientIntegers: [
                [4, 0, 5, -2, -8, -1, 1],
                [-4, -1, -6, 1, 12, 0, -4],
                [1, 0, 2, -1, -8, -1, 4]
            ],
            coefficients: [
                [193_104, 5_369_128, 2_553_116, 8_009_648, 2_772_020, 3_122_453, 2_961_581],
                [6_769_788, 2_565_605, 7_864_496, 4_777_288, 649_616, 7_036_536, 1_666_406],
                [406_265, 2_901_521, 2_680_224, 146_340, 1_008_052, 4_366_810, 5_080_852]
            ],
            to: &writer
        )
    }

    private func writeProfile84ChromaMMR(
        constantInteger: Int64,
        constant: UInt64,
        coefficientIntegers: [[Int64]],
        coefficients: [[UInt64]],
        to writer: inout NativeDolbyVisionBitWriter
    ) {
        writer.writeUE(1) // MMR mapping
        writer.write(2, bits: 2) // mmr_order_minus1
        writer.writeSE(constantInteger)
        writer.write(constant, bits: 23)
        for order in 0..<3 {
            for coefficient in 0..<7 {
                writer.writeSE(coefficientIntegers[order][coefficient])
                writer.write(coefficients[order][coefficient], bits: 23)
            }
        }
    }
}

final class DolbyVisionRPUProvider: @unchecked Sendable {
    private let task: Task<[Data], Error>
    private let expectedFrameCount: Int64

    init(metadataSource: DolbyVisionMetadataSource, profile: DolbyVisionHEVCProfile, expectedFrameCount: Int64) {
        self.expectedFrameCount = expectedFrameCount
        task = Task.detached(priority: .userInitiated) {
            let config = try NativeDolbyVisionXMLParser(xmlData: metadataSource.rawXMLData, profile: profile).parse()
            return try NativeDolbyVisionRPUBuilder(config: config, profile: profile).generate()
        }
    }

    func rpu(forFrame frameIndex: Int64) async throws -> Data {
        let rpus = try await task.value
        if expectedFrameCount > 0, Int64(rpus.count) != expectedFrameCount {
            throw NSError(
                domain: "DolbyVisionRPU",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Generated RPU count is \(rpus.count), but source video is estimated at \(expectedFrameCount) frames."
                ]
            )
        }
        guard !rpus.isEmpty else {
            throw NSError(
                domain: "DolbyVisionRPU",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Native Dolby Vision RPU builder produced no frames."]
            )
        }
        if frameIndex < Int64(rpus.count) {
            return rpus[Int(frameIndex)]
        }
        return rpus[rpus.count - 1]
    }

    func waitForCompletion() async throws -> Int {
        try await task.value.count
    }
}

private struct NativeDolbyVisionXMLParser {
    private let xmlData: Data
    private let profile: DolbyVisionHEVCProfile

    init(xmlData: Data, profile: DolbyVisionHEVCProfile) {
        self.xmlData = xmlData
        self.profile = profile
    }

    func parse() throws -> NativeDolbyVisionConfig {
        let doc = try XMLDocument(data: xmlData, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(),
              nativeXMLLocalName(root) == "DolbyLabsMDF" else {
            throw nativeRPUError("Dolby Vision XML root must be DolbyLabsMDF.")
        }

        let version = root.attribute(forName: "version")?.stringValue?.trimmedNonEmpty
            ?? nativeText(".//*[local-name()='Version']", in: root)
        guard let version else {
            throw nativeRPUError("Dolby Vision XML has no readable metadata version.")
        }

        let isCMV4 = version.hasPrefix("4.") || version.hasPrefix("5.")
        let separator: Character = isCMV4 ? " " : ","
        guard nativeFirstElement(".//*[local-name()='Outputs']/*[local-name()='Output']", in: root) != nil,
              let video = nativeFirstElement(".//*[local-name()='Outputs']/*[local-name()='Output']/*[local-name()='Video']", in: root)
        else {
            throw nativeRPUError("Dolby Vision XML must contain Outputs/Output/Video.")
        }

        let targets = try parseTargetDisplays(in: video, xmlVersion: version, separator: separator)
        let level6 = parseLevel6(in: video)
        let mastering = parseMasteringDisplay(in: video)
        let sourceMinPQ = mastering.map { nativeNitsToPQ12Bit(Double($0.minLuminance) / 10_000.0) }
        let sourceMaxPQ = mastering.map { nativeNitsToPQ12Bit(Double($0.maxLuminance)) }

        var defaultBlocks: [NativeDolbyVisionMetadataBlock] = [.level4(NativeLevel4Block(anchorPQ: 0, anchorPower: 0))]
        if isCMV4 {
            defaultBlocks.append(.level3(NativeLevel3Block(minPQOffset: 2048, avgPQOffset: 2048, maxPQOffset: 2048)))
            defaultBlocks.append(.level9(NativeLevel9Block(length: 1, sourcePrimaryIndex: 0, primaries: [])))
            defaultBlocks.append(.level11(NativeLevel11Block(contentType: 1, whitePoint: 0, referenceModeFlag: false)))
            defaultBlocks.append(.level254(parseLevel254(in: video) ?? NativeLevel254Block(dmMode: 0, dmVersionIndex: 2)))
            defaultBlocks.append(contentsOf: parseDefaultLevel10Blocks(targets: targets))
        }
        if let level11 = parseLevel11(in: video) {
            defaultBlocks.append(.level11(level11))
        }

        let shots = try parseShots(
            in: video,
            cmVersion: isCMV4 ? .v40 : .v29,
            separator: separator,
            targets: targets
        )

        return NativeDolbyVisionConfig(
            cmVersion: isCMV4 ? .v40 : .v29,
            sourceMinPQ: sourceMinPQ,
            sourceMaxPQ: sourceMaxPQ,
            level6: level6,
            defaultMetadataBlocks: defaultBlocks,
            shots: shots
        )
    }

    private func parseTargetDisplays(
        in video: XMLElement,
        xmlVersion: String,
        separator: Character
    ) throws -> [NativeDolbyVisionTargetDisplay] {
        let nodes = nativeElements(".//*[local-name()='TargetDisplay']", in: video)
        var targets: [NativeDolbyVisionTargetDisplay] = []
        for node in nodes {
            if xmlVersion.hasPrefix("5."),
               let applicationType = nativeText("./*[local-name()='ApplicationType']", in: node),
               applicationType != "HOME" {
                continue
            }
            guard let idText = nativeText("./*[local-name()='ID']", in: node),
                  let id = UInt8(idText),
                  let peakText = nativeText("./*[local-name()='PeakBrightness']", in: node),
                  let peak = UInt16(peakText),
                  let minText = nativeText("./*[local-name()='MinimumBrightness']", in: node),
                  let minNits = Double(minText) else {
                continue
            }
            let red = nativeParseNumbers(nativeText(".//*[local-name()='Red']", in: node), separator: separator)
            let green = nativeParseNumbers(nativeText(".//*[local-name()='Green']", in: node), separator: separator)
            let blue = nativeParseNumbers(nativeText(".//*[local-name()='Blue']", in: node), separator: separator)
            let white = nativeParseNumbers(nativeText("./*[local-name()='WhitePoint']", in: node), separator: separator)
            let primaries = red + green + blue + white
            guard primaries.count == 8 else { continue }
            targets.append(NativeDolbyVisionTargetDisplay(
                id: id,
                peakNits: peak,
                minNits: minNits,
                primaries: primaries
            ))
        }
        return targets
    }

    private func parseLevel6(in video: XMLElement) -> NativeLevel6Block? {
        guard let maxCLLText = nativeText(".//*[local-name()='Level6']/*[local-name()='MaxCLL']", in: video),
              let maxFALLText = nativeText(".//*[local-name()='Level6']/*[local-name()='MaxFALL']", in: video),
              let mastering = parseMasteringDisplay(in: video),
              let maxCLL = Double(maxCLLText),
              let maxFALL = Double(maxFALLText) else {
            return nil
        }
        return NativeLevel6Block(
            maxDisplayMasteringLuminance: mastering.maxLuminance,
            minDisplayMasteringLuminance: mastering.minLuminance,
            maxContentLightLevel: UInt16(maxCLL.rounded()),
            maxFrameAverageLightLevel: UInt16(maxFALL.rounded())
        )
    }

    private func parseMasteringDisplay(in video: XMLElement) -> (minLuminance: UInt16, maxLuminance: UInt16)? {
        guard let display = nativeFirstElement(
            ".//*[local-name()='MasteringDisplay']",
            in: video
        ),
        let peakText = nativeText("./*[local-name()='PeakBrightness']", in: display),
        let peak = UInt16(peakText),
        let minimumText = nativeText("./*[local-name()='MinimumBrightness']", in: display),
        let minimum = Double(minimumText) else {
            return nil
        }
        return (UInt16((minimum * 10_000.0).rounded()), peak)
    }

    private func parseLevel254(in video: XMLElement) -> NativeLevel254Block? {
        guard let node = nativeFirstElement(".//*[local-name()='Level254']", in: video),
              let dmMode = nativeText("./*[local-name()='DMMode']", in: node).flatMap(UInt8.init),
              let dmVersion = nativeText("./*[local-name()='DMVersion']", in: node).flatMap(UInt8.init) else {
            return nil
        }
        return NativeLevel254Block(dmMode: dmMode, dmVersionIndex: dmVersion)
    }

    private func parseLevel11(in video: XMLElement) -> NativeLevel11Block? {
        guard let node = nativeFirstElement(".//*[local-name()='Level11']", in: video),
              let contentType = nativeText("./*[local-name()='ContentType']", in: node).flatMap(UInt8.init),
              let whitePoint = nativeText("./*[local-name()='IntendedWhitePoint']", in: node).flatMap(UInt8.init) else {
            return nil
        }
        return NativeLevel11Block(contentType: contentType, whitePoint: whitePoint, referenceModeFlag: false)
    }

    private func parseDefaultLevel10Blocks(
        targets: [NativeDolbyVisionTargetDisplay]
    ) -> [NativeDolbyVisionMetadataBlock] {
        let presetDisplays: Set<UInt8> = [1, 16, 18, 21, 27, 28, 37, 38, 42, 48, 49]
        return targets.compactMap { target in
            guard !presetDisplays.contains(target.id) else { return nil }
            let primaryIndex = nativeFindPrimaryIndex(target.primaries, allowRealDevice: false)
            let length: UInt64 = primaryIndex == 255 ? 21 : 5
            let primaries = primaryIndex == 255 ? nativeFloatPrimariesToUInt16(target.primaries) : []
            return .level10(NativeLevel10Block(
                length: length,
                targetDisplayIndex: target.id,
                targetMaxPQ: nativeNitsToPQ12Bit(Double(target.peakNits)),
                targetMinPQ: nativeNitsToPQ12Bit(target.minNits),
                targetPrimaryIndex: primaryIndex,
                primaries: primaries
            ))
        }
    }

    private func parseShots(
        in video: XMLElement,
        cmVersion: NativeDolbyVisionCMVersion,
        separator: Character,
        targets: [NativeDolbyVisionTargetDisplay]
    ) throws -> [NativeDolbyVisionShotDefinition] {
        let shots = nativeElements(".//*[local-name()='Shot']", in: video)
        return try shots.map { shot in
            guard let record = nativeFirstElement("./*[local-name()='Record']", in: shot),
                  let start = nativeText("./*[local-name()='In']", in: record).flatMap(Int.init),
                  let duration = nativeText("./*[local-name()='Duration']", in: record).flatMap(Int.init) else {
                throw nativeRPUError("Each Dolby Vision Shot must have Record/In and Record/Duration.")
            }

            let blocks = try parseBlocks(
                in: shot,
                cmVersion: cmVersion,
                separator: separator,
                targets: targets
            )
            let frameEdits = try nativeElements("./*[local-name()='Frame']", in: shot).compactMap { frame -> NativeDolbyVisionFrameEdit? in
                guard let offset = nativeText("./*[local-name()='EditOffset']", in: frame).flatMap(Int.init) else {
                    return nil
                }
                let blocks = try parseBlocks(
                    in: frame,
                    cmVersion: cmVersion,
                    separator: separator,
                    targets: targets
                )
                return NativeDolbyVisionFrameEdit(editOffset: offset, blocks: blocks)
            }
            return NativeDolbyVisionShotDefinition(
                start: start,
                duration: duration,
                blocks: blocks,
                frameEdits: frameEdits
            )
        }
    }

    private func parseBlocks(
        in node: XMLElement,
        cmVersion: NativeDolbyVisionCMVersion,
        separator: Character,
        targets: [NativeDolbyVisionTargetDisplay]
    ) throws -> [NativeDolbyVisionMetadataBlock] {
        let dynamicPath = cmVersion == .v40
            ? ".//*[local-name()='DVDynamicData']/*"
            : ".//*[local-name()='PluginNode']/*[local-name()='DolbyEDR']"
        var blocks: [NativeDolbyVisionMetadataBlock] = []
        for child in nativeElements(dynamicPath, in: node) {
            guard let levelText = child.attribute(forName: "level")?.stringValue,
                  let level = Int(levelText) else { continue }
            switch level {
            case 1:
                if let block = try parseLevel1(in: child, separator: separator, cmVersion: cmVersion) {
                    blocks.append(.level1(block))
                }
            case 2:
                if let block = try parseLevel2(in: child, separator: separator, targets: targets) {
                    blocks.append(.level2(block))
                }
            case 3:
                if let block = try parseLevel3(in: child, separator: separator) {
                    blocks.append(.level3(block))
                }
            case 5:
                if let block = try parseLevel5(in: child, separator: separator) {
                    blocks.append(.level5(block))
                }
            case 8:
                if let block = try parseLevel8(in: child, separator: separator, targets: targets) {
                    blocks.append(.level8(block))
                }
            case 9:
                if let block = try parseLevel9(in: child, separator: separator) {
                    blocks.append(.level9(block))
                }
            default:
                continue
            }
        }
        return blocks
    }

    private func parseLevel1(
        in node: XMLElement,
        separator: Character,
        cmVersion: NativeDolbyVisionCMVersion
    ) throws -> NativeLevel1Block? {
        guard let text = nativeText("./*[local-name()='ImageCharacter']", in: node) else { return nil }
        let values = nativeParseNumbers(text, separator: separator)
        guard values.count == 3 else { return nil }
        let minPQ = UInt16((values[0] * 4095.0).rounded())
        let avgPQ = UInt16((values[1] * 4095.0).rounded())
        let maxPQ = UInt16((values[2] * 4095.0).rounded())
        let avgMin: UInt16 = cmVersion == .v40 ? 1229 : 819
        return NativeLevel1Block(
            minPQ: min(minPQ, 12),
            maxPQ: max(maxPQ, 2081),
            avgPQ: min(max(avgPQ, avgMin), max(maxPQ, 2081) - 1)
        )
    }

    private func parseLevel2(
        in node: XMLElement,
        separator: Character,
        targets: [NativeDolbyVisionTargetDisplay]
    ) throws -> NativeLevel2Block? {
        guard let targetIDText = nativeText("./*[local-name()='TID']", in: node).flatMap(UInt8.init),
              let target = targets.first(where: { $0.id == targetIDText }),
              let trimText = nativeText("./*[local-name()='Trim']", in: node) else {
            return nil
        }
        let trim = nativeParseNumbers(trimText, separator: separator)
        guard trim.count == 9 else { return nil }

        let trimLift = trim[3]
        let trimGain = trim[4]
        let trimGamma = max(-1.0, min(1.0, trim[5]))

        return NativeLevel2Block(
            targetMaxPQ: nativeNitsToPQ12Bit(Double(target.peakNits)),
            trimSlope: nativeClamped12Bit(((((trimGain + 2.0) * (1.0 - trimLift / 2.0) - 2.0) * 2048.0) + 2048.0).rounded()),
            trimOffset: nativeClamped12Bit(((((trimGain + 2.0) * (trimLift / 2.0)) * 2048.0) + 2048.0).rounded()),
            trimPower: nativeClamped12Bit((((2.0 / (1.0 + trimGamma / 2.0) - 2.0) * 2048.0) + 2048.0).rounded()),
            trimChromaWeight: nativeClamped12Bit(((trim[6] * 2048.0) + 2048.0).rounded()),
            trimSaturationGain: nativeClamped12Bit(((trim[7] * 2048.0) + 2048.0).rounded()),
            msWeight: Int16(min(4095.0, ((trim[8] * 2048.0) + 2048.0).rounded()))
        )
    }

    private func parseLevel3(
        in node: XMLElement,
        separator: Character
    ) throws -> NativeLevel3Block? {
        guard let text = nativeText("./*[local-name()='L1Offset']", in: node) else { return nil }
        let values = nativeParseNumbers(text, separator: separator)
        guard values.count == 3 else { return nil }
        return NativeLevel3Block(
            minPQOffset: nativeClamped12Bit(((values[0] * 2048.0) + 2048.0).rounded()),
            avgPQOffset: nativeClamped12Bit(((values[1] * 2048.0) + 2048.0).rounded()),
            maxPQOffset: nativeClamped12Bit(((values[2] * 2048.0) + 2048.0).rounded())
        )
    }

    private func parseLevel5(
        in node: XMLElement,
        separator: Character
    ) throws -> NativeLevel5Block? {
        guard let text = nativeText("./*[local-name()='AspectRatios']", in: node) else { return nil }
        let values = nativeParseNumbers(text, separator: separator)
        guard values.count == 2 else { return nil }
        return NativeLevel5Block(leftOffset: 0, rightOffset: 0, topOffset: 0, bottomOffset: 0)
    }

    private func parseLevel8(
        in node: XMLElement,
        separator: Character,
        targets: [NativeDolbyVisionTargetDisplay]
    ) throws -> NativeLevel8Block? {
        guard let targetIDText = nativeText("./*[local-name()='TID']", in: node).flatMap(UInt8.init),
              let target = targets.first(where: { $0.id == targetIDText }),
              let trimText = nativeText("./*[local-name()='L8Trim']", in: node) else {
            return nil
        }
        let trim = nativeParseNumbers(trimText, separator: separator)
        guard trim.count == 6 else { return nil }

        let trimLift = trim[0]
        let trimGain = trim[1]
        let trimGamma = max(-1.0, min(1.0, trim[2]))
        let trimSlope = nativeClamped12Bit(((((trimGain + 2.0) * (1.0 - trimLift / 2.0) - 2.0) * 2048.0) + 2048.0).rounded())
        let trimOffset = nativeClamped12Bit(((((trimGain + 2.0) * (trimLift / 2.0)) * 2048.0) + 2048.0).rounded())
        let trimPower = nativeClamped12Bit((((2.0 / (1.0 + trimGamma / 2.0) - 2.0) * 2048.0) + 2048.0).rounded())
        let trimChromaWeight = nativeClamped12Bit(((trim[3] * 2048.0) + 2048.0).rounded())
        let trimSaturationGain = nativeClamped12Bit(((trim[4] * 2048.0) + 2048.0).rounded())
        let msWeight = nativeClamped12Bit(((trim[5] * 2048.0) + 2048.0).rounded())

        let targetMidContrast = nativeClamped12Bit((((Double(nativeText("./*[local-name()='MidContrastBias']", in: node) ?? "0") ?? 0) * 2048.0) + 2048.0).rounded())
        let clipTrim = nativeClamped12Bit((((Double(nativeText("./*[local-name()='HighlightClipping']", in: node) ?? "0") ?? 0) * 2048.0) + 2048.0).rounded())
        let saturationVector = nativeParseNumbers(nativeText("./*[local-name()='SaturationVectorField']", in: node), separator: separator)
            .map { UInt8(min(255.0, (($0 * 128.0) + 128.0).rounded())) }
        let hueVector = nativeParseNumbers(nativeText("./*[local-name()='HueVectorField']", in: node), separator: separator)
            .map { UInt8(min(255.0, (($0 * 128.0) + 128.0).rounded())) }

        let length: UInt64
        if hueVector.contains(where: { $0 != 128 }) {
            length = 25
        } else if saturationVector.contains(where: { $0 != 128 }) {
            length = 19
        } else if clipTrim != 2048 {
            length = 13
        } else if targetMidContrast != 2048 {
            length = 12
        } else {
            length = 10
        }

        return NativeLevel8Block(
            length: length,
            targetDisplayIndex: target.id,
            trimSlope: trimSlope,
            trimOffset: trimOffset,
            trimPower: trimPower,
            trimChromaWeight: trimChromaWeight,
            trimSaturationGain: trimSaturationGain,
            msWeight: msWeight,
            targetMidContrast: targetMidContrast,
            clipTrim: clipTrim,
            saturationVectorField: saturationVector.isEmpty ? Array(repeating: 128, count: 6) : saturationVector,
            hueVectorField: hueVector.isEmpty ? Array(repeating: 128, count: 6) : hueVector
        )
    }

    private func parseLevel9(
        in node: XMLElement,
        separator: Character
    ) throws -> NativeLevel9Block? {
        guard let text = nativeText("./*[local-name()='SourceColorPrimary']", in: node) else { return nil }
        let values = nativeParseNumbers(text, separator: separator)
        guard values.count == 8 else { return nil }
        let index = nativeFindPrimaryIndex(values, allowRealDevice: true)
        let length: UInt64 = index == 255 ? 17 : 1
        return NativeLevel9Block(
            length: length,
            sourcePrimaryIndex: index,
            primaries: index == 255 ? nativeFloatPrimariesToUInt16(values) : []
        )
    }
}

private struct NativeDolbyVisionBitWriter {
    private(set) var data = Data()
    private var bitOffset = 0

    var bitCount: Int {
        max(0, (data.count - (bitOffset == 0 ? 0 : 1)) * 8 + bitOffset)
    }

    mutating func writeBit(_ bit: Bool) {
        if bitOffset == 0 {
            data.append(0)
        }
        if bit {
            let index = data.index(before: data.endIndex)
            data[index] |= UInt8(1 << (7 - bitOffset))
        }
        bitOffset = (bitOffset + 1) & 7
    }

    mutating func write(_ value: UInt64, bits: Int) {
        guard bits > 0 else { return }
        for bitIndex in stride(from: bits - 1, through: 0, by: -1) {
            writeBit(((value >> UInt64(bitIndex)) & 1) != 0)
        }
    }

    mutating func writeSigned(_ value: Int64, bits: Int) {
        let masked = UInt64(bitPattern: value) & ((1 << UInt64(bits)) - 1)
        write(masked, bits: bits)
    }

    mutating func writeUE(_ value: UInt64) {
        let codeNum = value + 1
        let length = max(1, 64 - codeNum.leadingZeroBitCount)
        let leadingZeroes = length - 1
        if leadingZeroes > 0 {
            write(0, bits: leadingZeroes)
        }
        write(codeNum, bits: length)
    }

    mutating func writeSE(_ value: Int64) {
        let mapped = value <= 0 ? UInt64(-value * 2) : UInt64(value * 2 - 1)
        writeUE(mapped)
    }

    mutating func byteAlignZero() {
        while bitOffset != 0 {
            writeBit(false)
        }
    }
}

private func nativeDolbyVisionCRC32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var crc: UInt32 = 0xffffffff
    for byte in bytes {
        crc ^= UInt32(byte) << 24
        for _ in 0..<8 {
            if (crc & 0x80000000) != 0 {
                crc = (crc << 1) ^ 0x04C11DB7
            } else {
                crc <<= 1
            }
        }
    }
    return crc
}

private func nativeAddStartCodeEmulationPrevention(to data: inout Data) {
    var output = Data()
    output.reserveCapacity(data.count + 16)
    var zeroCount = 0
    for byte in data {
        if zeroCount >= 2 && byte <= 3 {
            output.append(0x03)
            zeroCount = 0
        }
        output.append(byte)
        if byte == 0 {
            zeroCount += 1
        } else {
            zeroCount = 0
        }
    }
    data = output
}

private func nativeNitsToPQ12Bit(_ nits: Double) -> UInt16 {
    let y = max(nits, 0) / 10_000.0
    let m1 = 2610.0 / 16384.0
    let m2 = (2523.0 / 4096.0) * 128.0
    let c1 = 3424.0 / 4096.0
    let c2 = (2413.0 / 4096.0) * 32.0
    let c3 = (2392.0 / 4096.0) * 32.0
    let pq = pow((c1 + c2 * pow(y, m1)) / (1.0 + c3 * pow(y, m1)), m2)
    return UInt16((pq * 4095.0).rounded())
}

private func nativeClamped12Bit(_ value: Double) -> UInt16 {
    UInt16(max(0, min(4095, Int(value))))
}

private let nativePresetPrimaries: [[Double]] = [
    [0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329],
    [0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.329],
    [0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.329],
    [0.63, 0.34, 0.31, 0.595, 0.155, 0.07, 0.3127, 0.329],
    [0.64, 0.33, 0.29, 0.60, 0.15, 0.06, 0.3127, 0.329],
    [0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.314, 0.351],
    [0.7347, 0.2653, 0.0, 1.0, 0.0001, -0.077, 0.32168, 0.33767],
    [0.73, 0.28, 0.14, 0.855, 0.10, -0.05, 0.3127, 0.329],
    [0.766, 0.275, 0.225, 0.80, 0.089, -0.087, 0.3127, 0.329]
]

private let nativeRealDevicePrimaries: [[Double]] = [
    [0.693, 0.304, 0.208, 0.761, 0.1467, 0.0527, 0.3127, 0.329],
    [0.6867, 0.3085, 0.231, 0.69, 0.1489, 0.0638, 0.3127, 0.329],
    [0.6781, 0.3189, 0.2365, 0.7048, 0.141, 0.0489, 0.3127, 0.329],
    [0.68, 0.32, 0.265, 0.69, 0.15, 0.06, 0.3127, 0.329],
    [0.7042, 0.294, 0.2271, 0.725, 0.1416, 0.0516, 0.3127, 0.329],
    [0.6745, 0.310, 0.2212, 0.7109, 0.152, 0.0619, 0.3127, 0.329],
    [0.6805, 0.3191, 0.2522, 0.6702, 0.1397, 0.0554, 0.3127, 0.329],
    [0.6838, 0.3085, 0.2709, 0.6378, 0.1478, 0.0589, 0.3127, 0.329],
    [0.6753, 0.3193, 0.2636, 0.6835, 0.1521, 0.0627, 0.3127, 0.329],
    [0.6981, 0.2898, 0.1814, 0.7189, 0.1517, 0.0567, 0.3127, 0.329]
]

private func nativeFindPrimaryIndex(_ primaries: [Double], allowRealDevice: Bool) -> UInt8 {
    if allowRealDevice {
        let exactPreset = nativeFindPrimaryIndex(primaries, allowRealDevice: false)
        if exactPreset < 255 {
            return exactPreset
        }
    }
    let presets = allowRealDevice ? nativeRealDevicePrimaries : nativePresetPrimaries
    if let index = presets.firstIndex(where: { $0.elementsEqual(primaries) }) {
        return UInt8(allowRealDevice ? nativePresetPrimaries.count + index : index)
    }
    return 255
}

private func nativeFloatPrimariesToUInt16(_ primaries: [Double]) -> [UInt16] {
    primaries.map { UInt16(($0 / (1.0 / 32767.0)).rounded()) }
}

private func nativeXMLLocalName(_ node: XMLNode) -> String {
    let name = node.name ?? ""
    return name.split(separator: ":").last.map(String.init) ?? name
}

private func nativeFirstElement(_ xPath: String, in node: XMLNode) -> XMLElement? {
    (try? node.nodes(forXPath: xPath))?.first as? XMLElement
}

private func nativeElements(_ xPath: String, in node: XMLNode) -> [XMLElement] {
    (try? node.nodes(forXPath: xPath))?.compactMap { $0 as? XMLElement } ?? []
}

private func nativeText(_ xPath: String, in node: XMLNode) -> String? {
    (try? node.nodes(forXPath: xPath))?.first?.stringValue?.trimmedNonEmpty
}

private func nativeParseNumbers(_ text: String?, separator: Character) -> [Double] {
    guard let text else { return [] }
    return text
        .replacingOccurrences(of: separator == "," ? "," : " ", with: " ")
        .split { $0 == " " || $0 == "\n" || $0 == "\t" }
        .compactMap { Double($0) }
}

private func nativeRPUError(_ message: String) -> NSError {
    NSError(domain: "DolbyVisionRPU", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
