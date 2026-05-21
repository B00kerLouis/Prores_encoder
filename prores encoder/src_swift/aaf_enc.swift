// aaf_enc.swift — Native Swift AAF file writer
// Implements CFB (Compound File Binary) + AAF Object Model for generating
// AAF sequences that link to external MXF files.
//

import Foundation

// MARK: - AUID (AAF Unique Identifier / UUID, 16 bytes, MS GUID wire format)

struct AUID: Equatable, Hashable {
    let data1: UInt32   // LE
    let data2: UInt16   // LE
    let data3: UInt16   // LE
    let data4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) // BE

    /// 16 bytes in Microsoft GUID bytes_le layout (Data1 LE, Data2 LE, Data3 LE, Data4 raw)
    var bytesLE: [UInt8] {
        var b = [UInt8](repeating: 0, count: 16)
        b[0] = UInt8(data1 & 0xFF); b[1] = UInt8((data1 >> 8) & 0xFF)
        b[2] = UInt8((data1 >> 16) & 0xFF); b[3] = UInt8((data1 >> 24) & 0xFF)
        b[4] = UInt8(data2 & 0xFF); b[5] = UInt8((data2 >> 8) & 0xFF)
        b[6] = UInt8(data3 & 0xFF); b[7] = UInt8((data3 >> 8) & 0xFF)
        b[8] = data4.0; b[9] = data4.1; b[10] = data4.2; b[11] = data4.3
        b[12] = data4.4; b[13] = data4.5; b[14] = data4.6; b[15] = data4.7
        return b
    }

    static func == (lhs: AUID, rhs: AUID) -> Bool {
        lhs.data1 == rhs.data1 && lhs.data2 == rhs.data2 &&
        lhs.data3 == rhs.data3 &&
        lhs.data4.0 == rhs.data4.0 && lhs.data4.1 == rhs.data4.1 &&
        lhs.data4.2 == rhs.data4.2 && lhs.data4.3 == rhs.data4.3 &&
        lhs.data4.4 == rhs.data4.4 && lhs.data4.5 == rhs.data4.5 &&
        lhs.data4.6 == rhs.data4.6 && lhs.data4.7 == rhs.data4.7
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(data1); hasher.combine(data2); hasher.combine(data3)
        hasher.combine(data4.0); hasher.combine(data4.1)
        hasher.combine(data4.2); hasher.combine(data4.3)
        hasher.combine(data4.4); hasher.combine(data4.5)
        hasher.combine(data4.6); hasher.combine(data4.7)
    }

    /// Create from standard UUID string "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    init(_ str: String) {
        let hex = str.replacingOccurrences(of: "-", with: "")
        precondition(hex.count == 32, "Invalid AUID string: \(str)")
        func byte(_ i: Int) -> UInt8 {
            let s = hex.index(hex.startIndex, offsetBy: i * 2)
            let e = hex.index(s, offsetBy: 2)
            return UInt8(hex[s..<e], radix: 16)!
        }
        // Parse as big-endian UUID, store in GUID layout
        data1 = UInt32(byte(0)) << 24 | UInt32(byte(1)) << 16 | UInt32(byte(2)) << 8 | UInt32(byte(3))
        data2 = UInt16(byte(4)) << 8 | UInt16(byte(5))
        data3 = UInt16(byte(6)) << 8 | UInt16(byte(7))
        data4 = (byte(8), byte(9), byte(10), byte(11), byte(12), byte(13), byte(14), byte(15))
    }

    /// Generate a random AUID (UUID v4)
    static func random() -> AUID {
        let uuid = UUID()
        return uuid.withUnsafeBytes { buf in
            // UUID bytes are big-endian
            AUID(
                data1: UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3]),
                data2: UInt16(buf[4]) << 8 | UInt16(buf[5]),
                data3: UInt16(buf[6]) << 8 | UInt16(buf[7]),
                data4: (buf[8], buf[9], buf[10], buf[11], buf[12], buf[13], buf[14], buf[15])
            )
        }
    }

    private init(data1: UInt32, data2: UInt16, data3: UInt16,
                 data4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) {
        self.data1 = data1; self.data2 = data2; self.data3 = data3; self.data4 = data4
    }
}

private extension UUID {
    func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        var uuid = self.uuid
        return Swift.withUnsafeBytes(of: &uuid) { raw in
            body(raw.bindMemory(to: UInt8.self))
        }
    }
}

// MARK: - MobID (32 bytes UMID)

struct AAFMobID: Equatable, Hashable {
    var bytes: [UInt8]  // 32 bytes

    init() {
        bytes = [UInt8](repeating: 0, count: 32)
    }

    /// Generate a new MobID with SMPTE 330M UMID structure + UUID material
    static func generate() -> AAFMobID {
        var m = AAFMobID()
        // SMPTE 330M UMID prefix — matches mxf_enc.cpp make_umid() pfx[12]
        let prefix: [UInt8] = [0x06, 0x0a, 0x2b, 0x34, 0x01, 0x01, 0x01, 0x05,
                                0x01, 0x01, 0x0d, 0x12, 0x13, 0x00, 0x00, 0x00]
        for i in 0..<16 { m.bytes[i] = prefix[i] }
        // Material number (UUID v4 in bytes_le layout)
        let uuid = UUID()
        uuid.withUnsafeBytes { buf in
            // Store as AUID bytes_le: Data1 LE, Data2 LE, Data3 LE, Data4 raw
            m.bytes[16] = buf[3]; m.bytes[17] = buf[2]; m.bytes[18] = buf[1]; m.bytes[19] = buf[0]
            m.bytes[20] = buf[5]; m.bytes[21] = buf[4]
            m.bytes[22] = buf[7]; m.bytes[23] = buf[6]
            for i in 0..<8 { m.bytes[24 + i] = buf[8 + i] }
        }
        return m
    }

    /// Zero MobID (end of reference chain)
    static let zero = AAFMobID()
}

// MARK: - AAF Rational

struct AAFRational {
    let numerator: Int32
    let denominator: Int32
}

// MARK: - AAF Class AUIDs

private enum AAFClass {
    static let root             = AUID("b3b398a5-1c90-11d4-8053-080036210804")
    static let metaDictionary   = AUID("0d010101-0225-0000-060e-2b3402060101")
    static let header           = AUID("0d010101-0101-2f00-060e-2b3402060101")
    static let contentStorage   = AUID("0d010101-0101-1800-060e-2b3402060101")
    static let dictionary       = AUID("0d010101-0101-2200-060e-2b3402060101")
    static let identification   = AUID("0d010101-0101-3000-060e-2b3402060101")
    static let compositionMob   = AUID("0d010101-0101-3500-060e-2b3402060101")
    static let masterMob        = AUID("0d010101-0101-3600-060e-2b3402060101")
    static let sourceMob        = AUID("0d010101-0101-3700-060e-2b3402060101")
    static let timelineMobSlot  = AUID("0d010101-0101-3b00-060e-2b3402060101")
    static let sequence         = AUID("0d010101-0101-0f00-060e-2b3402060101")
    static let sourceClip       = AUID("0d010101-0101-1100-060e-2b3402060101")
    static let timecode         = AUID("0d010101-0101-1400-060e-2b3402060101")
    static let filler           = AUID("0d010101-0101-0900-060e-2b3402060101")
    static let cdciDescriptor   = AUID("0d010101-0101-2800-060e-2b3402060101")
    static let pcmDescriptor    = AUID("0d010101-0101-4800-060e-2b3402060101")
    static let networkLocator   = AUID("0d010101-0101-3200-060e-2b3402060101")
    static let dataDefinition   = AUID("0d010101-0101-1b00-060e-2b3402060101")
    static let containerDef     = AUID("0d010101-0101-2000-060e-2b3402060101")
    static let essenceData      = AUID("0d010101-0101-2300-060e-2b3402060101")
}

// MARK: - AAF Property IDs

private enum PID {
    // Root
    static let rootMetaDict:     UInt16 = 0x0001
    static let rootHeader:       UInt16 = 0x0002
    // MetaDictionary
    static let classDefs:        UInt16 = 0x0003
    static let typeDefs:         UInt16 = 0x0004
    // Header (Preface)
    static let byteOrder:        UInt16 = 0x3B01
    static let lastModified:     UInt16 = 0x3B02
    static let content:          UInt16 = 0x3B03
    static let hdrDictionary:    UInt16 = 0x3B04
    static let version:          UInt16 = 0x3B05
    static let identList:        UInt16 = 0x3B06
    static let objModelVer:      UInt16 = 0x3B07
    static let opPattern:        UInt16 = 0x3B09
    static let essContainers:    UInt16 = 0x3B0A
    // ContentStorage
    static let mobs:             UInt16 = 0x1901
    static let essData:          UInt16 = 0x1902
    // Dictionary
    static let opDefs:           UInt16 = 0x2603
    static let dataDefs:         UInt16 = 0x2605
    static let codecDefs:        UInt16 = 0x2607
    static let containerDefs:    UInt16 = 0x2608
    // DefinitionObject
    static let defIdent:         UInt16 = 0x1B01
    static let defName:          UInt16 = 0x1B02
    static let defDesc:          UInt16 = 0x1B03
    // ContainerDef
    static let essIsIdentified:  UInt16 = 0x2401
    // Mob
    static let mobID:            UInt16 = 0x4401
    static let mobName:          UInt16 = 0x4402
    static let mobSlots:         UInt16 = 0x4403
    static let mobLastMod:       UInt16 = 0x4404
    static let mobCreation:      UInt16 = 0x4405
    static let mobUsage:         UInt16 = 0x4408
    // SourceMob
    static let essDesc:          UInt16 = 0x4701
    // MobSlot
    static let slotID:           UInt16 = 0x4801
    static let slotName:         UInt16 = 0x4802
    static let segment:          UInt16 = 0x4803
    // TimelineMobSlot
    static let editRate:         UInt16 = 0x4B01
    static let origin:           UInt16 = 0x4B02
    // Component
    static let dataDefinition:   UInt16 = 0x0201
    static let length:           UInt16 = 0x0202
    // Sequence
    static let components:       UInt16 = 0x1001
    // SourceReference
    static let sourceID:         UInt16 = 0x1101
    static let srcMobSlotID:     UInt16 = 0x1102
    // SourceClip
    static let startTime:        UInt16 = 0x1201
    // Timecode
    static let tcStart:          UInt16 = 0x1501
    static let tcFPS:            UInt16 = 0x1502
    static let tcDrop:           UInt16 = 0x1503
    // EssenceDescriptor
    static let locators:         UInt16 = 0x2F01
    // FileDescriptor
    static let sampleRate:       UInt16 = 0x3001
    static let fdLength:         UInt16 = 0x3002
    static let containerFmt:     UInt16 = 0x3004
    // DigitalImageDescriptor
    static let compression:      UInt16 = 0x3201
    static let storedHeight:     UInt16 = 0x3202
    static let storedWidth:      UInt16 = 0x3203
    static let frameLayout:      UInt16 = 0x320C
    static let videoLineMap:     UInt16 = 0x320D
    static let imageAspectRatio: UInt16 = 0x320E
    // CDCIDescriptor
    static let componentWidth:   UInt16 = 0x3301
    static let hSubsampling:     UInt16 = 0x3302
    static let vSubsampling:     UInt16 = 0x3308
    // SoundDescriptor
    static let quantBits:        UInt16 = 0x3D01
    static let audioSampleRate:  UInt16 = 0x3D03
    static let channels:         UInt16 = 0x3D07
    // PCMDescriptor
    static let blockAlign:       UInt16 = 0x3D0A
    static let averageBPS:       UInt16 = 0x3D09
    // NetworkLocator
    static let urlString:        UInt16 = 0x4001
    // Identification
    static let companyName:      UInt16 = 0x3C01
    static let productName:      UInt16 = 0x3C02
    static let productVersion:   UInt16 = 0x3C03
    static let prodVerString:    UInt16 = 0x3C04
    static let productID:        UInt16 = 0x3C05
    static let identDate:        UInt16 = 0x3C06
    static let toolkitVersion:   UInt16 = 0x3C07
    static let platform:         UInt16 = 0x3C08
    static let generationAUID:   UInt16 = 0x3C09
}

// MARK: - Storage Format Codes

private enum SF: UInt16 {
    case data              = 0x0082
    case dataStream        = 0x0042
    case strongRef         = 0x0022
    case strongRefVector   = 0x0032
    case strongRefSet      = 0x003A
    case weakRef           = 0x0002
}

// MARK: - Well-Known DataDef & ContainerDef AUIDs

private enum DataDef {
    static let picture  = AUID("01030202-0100-0000-060e-2b3404010101")
    static let sound    = AUID("01030202-0200-0000-060e-2b3404010101")
    static let timecode = AUID("01030201-0100-0000-060e-2b3404010101")
}

private enum ContainerDef {
    static let aafklv   = AUID("4b464141-000d-4d4f-060e-2b34010101ff")
    static let external = AUID("4313b572-d8ba-11d2-809b-006008143e6f")
    static let aaf      = AUID("4313b571-d8ba-11d2-809b-006008143e6f")
    static let aafmss   = AUID("42464141-000d-4d4f-060e-2b34010101ff")
}

// MARK: - ProRes Compression AUIDs (SMPTE RDD 36 registered ULs)
private enum ProResCompressionAUID {
    static let proxy = AUID("0d010301-027c-0112-060e-2b3404010101")
    static let lt    = AUID("0d010301-027c-0113-060e-2b3404010101")
    static let std   = AUID("0d010301-027c-0114-060e-2b3404010101")
    static let hq    = AUID("0d010301-027c-0115-060e-2b3404010101")
    static let k4444 = AUID("0d010301-027c-0116-060e-2b3404010101")

    static func from(_ variant: String) -> AUID? {
        switch normalizedProResQuality(variant) {
        case "proxy":  return proxy
        case "422lt":  return lt
        case "422":    return std
        case "422hq":  return hq
        case "4444":   return k4444
        case "4444xq":
            // External AAF relink uses the MXF descriptor as the authoritative codec source.
            // Keep the 4444-family AUID here until a dedicated XQ AUID is introduced locally.
            return k4444
        default:       return nil
        }
    }
}

// MARK: - CFB Constants

private enum CFB {
    static let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let sectorSize: Int = 512
    static let sectorPow: UInt16 = 9
    static let miniSectorSize: Int = 64
    static let miniSectorPow: UInt16 = 6
    static let miniStreamCutoff: UInt32 = 4096
    static let dirEntrySize: Int = 128
    static let entriesPerSector: Int = 512 / 128  // 4
    static let freeSecT: UInt32 = 0xFFFFFFFF
    static let endOfChain: UInt32 = 0xFFFFFFFE
    static let fatSecT: UInt32 = 0xFFFFFFFD
    static let difSecT: UInt32 = 0xFFFFFFFC
    static let noStream: UInt32 = 0xFFFFFFFF
    // Directory entry types
    static let typeEmpty: UInt8 = 0
    static let typeStorage: UInt8 = 1
    static let typeStream: UInt8 = 2
    static let typeRoot: UInt8 = 5
}

// MARK: - CFB Directory Entry

private class DirEntry {
    var name: String = ""
    var type: UInt8 = CFB.typeEmpty
    var color: UInt8 = 1  // black
    var leftID: UInt32 = CFB.noStream
    var rightID: UInt32 = CFB.noStream
    var childID: UInt32 = CFB.noStream
    var classID: [UInt8] = [UInt8](repeating: 0, count: 16)
    var flags: UInt32 = 0
    var createTime: UInt64 = 0
    var modifyTime: UInt64 = 0
    var startSector: UInt32 = CFB.endOfChain
    var byteSize: UInt64 = 0
    var streamData: Data?  // for streams only

    let dirID: Int

    init(id: Int) { self.dirID = id }

    /// Encode to 128-byte directory entry
    func encode() -> Data {
        var d = Data(count: 128)
        // Name in UTF-16LE (max 32 chars including null)
        let utf16 = Array(name.utf16)
        let nameLen = min(utf16.count, 31)
        for i in 0..<nameLen {
            d[i * 2] = UInt8(utf16[i] & 0xFF)
            d[i * 2 + 1] = UInt8(utf16[i] >> 8)
        }
        // Null terminator
        d[nameLen * 2] = 0; d[nameLen * 2 + 1] = 0
        // Name byte size (includes null terminator)
        let nameByteSize = UInt16((nameLen + 1) * 2)
        d[64] = UInt8(nameByteSize & 0xFF); d[65] = UInt8(nameByteSize >> 8)
        // Type
        d[66] = type
        // Color
        d[67] = color
        // Left sibling
        writeU32LE(&d, offset: 68, value: leftID)
        // Right sibling
        writeU32LE(&d, offset: 72, value: rightID)
        // Child
        writeU32LE(&d, offset: 76, value: childID)
        // Class ID
        for i in 0..<16 { d[80 + i] = classID[i] }
        // Flags
        writeU32LE(&d, offset: 96, value: flags)
        // Create time
        writeU64LE(&d, offset: 100, value: createTime)
        // Modify time
        writeU64LE(&d, offset: 108, value: modifyTime)
        // Start sector
        writeU32LE(&d, offset: 116, value: startSector)
        // Byte size
        writeU64LE(&d, offset: 120, value: byteSize)
        return d
    }
}

// MARK: - CFB Writer

private class CFBWriter {
    private var entries: [DirEntry] = []
    private var sectors: [[UInt8]] = []  // each sector is 4096 bytes
    private var fat: [UInt32] = []

    init() {
        // Create root entry
        let root = DirEntry(id: 0)
        root.name = "Root Entry"
        root.type = CFB.typeRoot
        root.classID = AUID("b3b398a5-1c90-11d4-8053-080036210804").bytesLE
        entries.append(root)
    }

    /// Allocate a new sector, returns sector ID
    private func allocSector() -> Int {
        let sid = sectors.count
        sectors.append([UInt8](repeating: 0, count: CFB.sectorSize))
        fat.append(CFB.endOfChain)
        return sid
    }

    /// Write data to a chain of sectors, returns starting sector ID
    private func writeChain(_ data: Data) -> UInt32 {
        if data.isEmpty { return CFB.endOfChain }
        let totalSectors = (data.count + CFB.sectorSize - 1) / CFB.sectorSize
        var sectorIDs: [Int] = []
        for _ in 0..<totalSectors {
            sectorIDs.append(allocSector())
        }
        // Chain them
        for i in 0..<sectorIDs.count - 1 {
            fat[sectorIDs[i]] = UInt32(sectorIDs[i + 1])
        }
        fat[sectorIDs.last!] = CFB.endOfChain
        // Write data
        var offset = 0
        for sid in sectorIDs {
            let remaining = data.count - offset
            let count = min(remaining, CFB.sectorSize)
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                for i in 0..<count {
                    sectors[sid][i] = buf[offset + i]
                }
            }
            offset += count
        }
        return UInt32(sectorIDs[0])
    }

    /// Create a new directory entry
    func newEntry(name: String, type: UInt8, parentID: Int, classID: AUID? = nil) -> Int {
        let entry = DirEntry(id: entries.count)
        entry.name = name
        entry.type = type
        if let c = classID { entry.classID = c.bytesLE }
        entries.append(entry)

        // Add to parent's child tree
        let parent = entries[parentID]
        if parent.childID == CFB.noStream {
            parent.childID = UInt32(entry.dirID)
        } else {
            insertSibling(parent: parentID, newID: entry.dirID)
        }
        return entry.dirID
    }

    /// Create a storage (directory) entry
    func createStorage(name: String, parentID: Int, classID: AUID? = nil) -> Int {
        return newEntry(name: name, type: CFB.typeStorage, parentID: parentID, classID: classID)
    }

    /// Create a stream entry and set its data
    func createStream(name: String, parentID: Int, data: Data) {
        let id = newEntry(name: name, type: CFB.typeStream, parentID: parentID)
        entries[id].streamData = data
    }

    /// Insert a new sibling into the directory tree (simplified sorted insertion)
    private func insertSibling(parent parentID: Int, newID: Int) {
        let parent = entries[parentID]
        // Simple approach: build sorted list, then create balanced tree
        var ids = collectSiblings(Int(parent.childID))
        ids.append(newID)
        ids.sort { compareDirNames(entries[$0].name, entries[$1].name) < 0 }
        parent.childID = UInt32(buildBalancedTree(ids))
    }

    /// Collect all sibling IDs from a subtree
    private func collectSiblings(_ rootID: Int) -> [Int] {
        if rootID < 0 || rootID >= entries.count { return [] }
        let e = entries[rootID]
        var result: [Int] = []
        if e.leftID != CFB.noStream { result += collectSiblings(Int(e.leftID)) }
        result.append(rootID)
        if e.rightID != CFB.noStream { result += collectSiblings(Int(e.rightID)) }
        return result
    }

    /// Build a balanced binary tree from sorted IDs, returns root ID
    private func buildBalancedTree(_ ids: [Int]) -> Int {
        if ids.isEmpty { return Int(CFB.noStream) }
        if ids.count == 1 {
            entries[ids[0]].leftID = CFB.noStream
            entries[ids[0]].rightID = CFB.noStream
            entries[ids[0]].color = 1 // black
            return ids[0]
        }
        let mid = ids.count / 2
        let rootID = ids[mid]
        let leftIDs = Array(ids[0..<mid])
        let rightIDs = Array(ids[(mid + 1)...])
        entries[rootID].leftID = leftIDs.isEmpty ? CFB.noStream : UInt32(buildBalancedTree(leftIDs))
        entries[rootID].rightID = rightIDs.isEmpty ? CFB.noStream : UInt32(buildBalancedTree(rightIDs))
        entries[rootID].color = 1 // black
        return rootID
    }

    /// CFB name comparison: shorter name first, then case-insensitive Unicode compare
    private func compareDirNames(_ a: String, _ b: String) -> Int {
        if a.utf16.count != b.utf16.count {
            return a.utf16.count < b.utf16.count ? -1 : 1
        }
        let aUp = a.uppercased()
        let bUp = b.uppercased()
        if aUp < bUp { return -1 }
        if aUp > bUp { return 1 }
        return 0
    }

    /// Finalize and produce the CFB file data
    func finalize() -> Data {
        // 1. Write all stream data to sectors (or mini-stream for small streams)
        // For simplicity, we use full sectors for all streams (mini-stream only for < 4096 bytes)
        var miniStreamData = Data()
        var miniFat: [UInt32] = []

        for entry in entries {
            guard entry.type == CFB.typeStream, let data = entry.streamData else { continue }
            if data.count < Int(CFB.miniStreamCutoff) {
                // Store in mini-stream
                let miniSectorStart = miniStreamData.count / CFB.miniSectorSize
                let numMiniSectors = (data.count + CFB.miniSectorSize - 1) / CFB.miniSectorSize
                // Pad data to mini-sector boundary
                var padded = data
                let remainder = data.count % CFB.miniSectorSize
                if remainder != 0 { padded.append(Data(count: CFB.miniSectorSize - remainder)) }
                miniStreamData.append(padded)
                // Build mini-FAT chain
                while miniFat.count < miniSectorStart { miniFat.append(CFB.freeSecT) }
                for i in 0..<numMiniSectors {
                    if i < numMiniSectors - 1 {
                        miniFat.append(UInt32(miniSectorStart + i + 1))
                    } else {
                        miniFat.append(CFB.endOfChain)
                    }
                }
                entry.startSector = UInt32(miniSectorStart)
                entry.byteSize = UInt64(data.count)
            } else {
                // Store in full sectors
                entry.startSector = writeChain(data)
                entry.byteSize = UInt64(data.count)
            }
        }

        // 2. Write mini-stream to root entry's sector chain
        if !miniStreamData.isEmpty {
            entries[0].startSector = writeChain(miniStreamData)
            entries[0].byteSize = UInt64(miniStreamData.count)
        }

        // 3. Write MiniFAT
        let miniFatStart: UInt32
        let miniFatCount: UInt32
        if !miniFat.isEmpty {
            var miniFatData = Data(count: miniFat.count * 4)
            for (i, val) in miniFat.enumerated() {
                writeU32LE_data(&miniFatData, offset: i * 4, value: val)
            }
            // Pad to sector boundary
            let rem = miniFatData.count % CFB.sectorSize
            if rem != 0 { miniFatData.append(Data(count: CFB.sectorSize - rem)) }
            miniFatStart = writeChain(miniFatData)
            miniFatCount = UInt32((miniFatData.count + CFB.sectorSize - 1) / CFB.sectorSize)
        } else {
            miniFatStart = CFB.endOfChain
            miniFatCount = 0
        }

        // 4. Write directory entries to sectors
        let dirData = serializeDirectoryEntries()
        let dirStart = writeChain(dirData)

        // 5. Write FAT sectors
        // FAT needs to include itself (FAT sectors marked as FATSECT)
        // Calculate how many FAT sectors we need
        let totalSectorsBeforeFAT = sectors.count
        // Each FAT sector holds 128 entries (512/4)
        let entriesPerFATSector = CFB.sectorSize / 4
        var fatSectorCount = (totalSectorsBeforeFAT + entriesPerFATSector - 1) / entriesPerFATSector
        // Account for FAT sectors themselves
        var totalWithFAT = totalSectorsBeforeFAT + fatSectorCount
        fatSectorCount = (totalWithFAT + entriesPerFATSector - 1) / entriesPerFATSector
        totalWithFAT = totalSectorsBeforeFAT + fatSectorCount
        fatSectorCount = (totalWithFAT + entriesPerFATSector - 1) / entriesPerFATSector

        // Allocate FAT sectors
        var fatSectorIDs: [Int] = []
        for _ in 0..<fatSectorCount {
            let sid = sectors.count
            sectors.append([UInt8](repeating: 0, count: CFB.sectorSize))
            fat.append(CFB.fatSecT)
            fatSectorIDs.append(sid)
        }

        // Build final FAT data and write to FAT sectors
        // Ensure FAT covers all sectors
        while fat.count < sectors.count {
            fat.append(CFB.freeSecT)
        }
        for (i, sid) in fatSectorIDs.enumerated() {
            let startIdx = i * entriesPerFATSector
            for j in 0..<entriesPerFATSector {
                let idx = startIdx + j
                let val = idx < fat.count ? fat[idx] : CFB.freeSecT
                let offset = j * 4
                sectors[sid][offset] = UInt8(val & 0xFF)
                sectors[sid][offset + 1] = UInt8((val >> 8) & 0xFF)
                sectors[sid][offset + 2] = UInt8((val >> 16) & 0xFF)
                sectors[sid][offset + 3] = UInt8((val >> 24) & 0xFF)
            }
        }

        // 6. Build header (512 bytes, CFB v3)
        var header = Data(count: 512)
        // Magic
        for i in 0..<8 { header[i] = CFB.magic[i] }
        // Class ID for AAF 512-sector (v3): 0d010201-0100-0000-060e-2b3403020101
        let hdrClassID = AUID("0d010201-0100-0000-060e-2b3403020101").bytesLE
        for i in 0..<16 { header[8 + i] = hdrClassID[i] }
        // Minor version = 62
        writeU16LE_data(&header, offset: 24, value: 62)
        // Major version = 3 (512-byte sectors for broad compatibility)
        writeU16LE_data(&header, offset: 26, value: 3)
        // Byte order = 0xFFFE (little-endian)
        writeU16LE_data(&header, offset: 28, value: 0xFFFE)
        // Sector size power = 9 (2^9 = 512)
        writeU16LE_data(&header, offset: 30, value: CFB.sectorPow)
        // Mini sector size power = 6
        writeU16LE_data(&header, offset: 32, value: CFB.miniSectorPow)
        // Reserved 6 bytes (already zero)
        // Directory sector count: MUST be 0 for CFB v3
        writeU32LE_data(&header, offset: 40, value: 0)
        // FAT sector count
        writeU32LE_data(&header, offset: 44, value: UInt32(fatSectorIDs.count))
        // Directory sector start
        writeU32LE_data(&header, offset: 48, value: UInt32(dirStart))
        // Transaction signature (0)
        writeU32LE_data(&header, offset: 52, value: 0)
        // Mini-stream max size cutoff
        writeU32LE_data(&header, offset: 56, value: CFB.miniStreamCutoff)
        // MiniFAT sector start
        writeU32LE_data(&header, offset: 60, value: miniFatStart)
        // MiniFAT sector count
        writeU32LE_data(&header, offset: 64, value: miniFatCount)
        // DIFAT sector start (none needed for <= 109 FAT sectors)
        writeU32LE_data(&header, offset: 68, value: CFB.endOfChain)
        // DIFAT sector count
        writeU32LE_data(&header, offset: 72, value: 0)
        // DIFAT array (first 109 FAT sector locations)
        for i in 0..<109 {
            let val: UInt32 = i < fatSectorIDs.count ? UInt32(fatSectorIDs[i]) : CFB.freeSecT
            writeU32LE_data(&header, offset: 76 + i * 4, value: val)
        }

        // 7. Assemble final file
        var result = Data()
        result.append(header)
        for sector in sectors {
            result.append(contentsOf: sector)
        }
        return result
    }

    /// Serialize all directory entries into sector-aligned data
    private func serializeDirectoryEntries() -> Data {
        let sectorCount = (entries.count + CFB.entriesPerSector - 1) / CFB.entriesPerSector
        var data = Data(count: sectorCount * CFB.sectorSize)
        for (i, entry) in entries.enumerated() {
            let encoded = entry.encode()
            let offset = i * CFB.dirEntrySize
            for j in 0..<CFB.dirEntrySize {
                data[offset + j] = encoded[j]
            }
        }
        return data
    }
}

// MARK: - Binary helpers

private func writeU16LE(_ data: inout Data, offset: Int, value: UInt16) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8(value >> 8)
}

private func writeU16LE_data(_ data: inout Data, offset: Int, value: UInt16) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8(value >> 8)
}

private func writeU32LE(_ data: inout Data, offset: Int, value: UInt32) {
    data[offset]     = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
    data[offset + 2] = UInt8((value >> 16) & 0xFF)
    data[offset + 3] = UInt8((value >> 24) & 0xFF)
}

private func writeU32LE_data(_ data: inout Data, offset: Int, value: UInt32) {
    writeU32LE(&data, offset: offset, value: value)
}

private func writeU64LE(_ data: inout Data, offset: Int, value: UInt64) {
    for i in 0..<8 {
        data[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
    }
}

// MARK: - AAF Property Builder

/// A single property entry for the properties stream
private struct PropEntry {
    let pid: UInt16
    let format: UInt16  // SF code
    let data: Data
}

/// Encode a list of property entries into the AAF "properties" stream binary format
private func encodePropertiesStream(_ entries: [PropEntry]) -> Data {
    // Header: byte_order(1) + version(1) + entry_count(2) = 4 bytes
    // Index: 6 bytes per entry (pid:2 + format:2 + size:2)
    // Data: concatenated

    let indexSize = entries.count * 6
    let dataBlob = entries.reduce(Data()) { $0 + $1.data }
    let totalSize = 4 + indexSize + dataBlob.count

    var result = Data(count: totalSize)
    result[0] = 0x4C  // byte order = LE
    result[1] = 0x20  // version = 32
    writeU16LE(&result, offset: 2, value: UInt16(entries.count))

    var offset = 4
    for entry in entries {
        writeU16LE(&result, offset: offset, value: entry.pid)
        writeU16LE(&result, offset: offset + 2, value: entry.format)
        writeU16LE(&result, offset: offset + 4, value: UInt16(entry.data.count))
        offset += 6
    }

    // Copy data
    var dataOffset = 4 + indexSize
    for entry in entries {
        entry.data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for i in 0..<entry.data.count {
                result[dataOffset + i] = buf[i]
            }
        }
        dataOffset += entry.data.count
    }
    return result
}

// MARK: - Data encoding helpers

private func encodeInt16LE(_ v: Int16) -> Data {
    var d = Data(count: 2)
    d[0] = UInt8(UInt16(bitPattern: v) & 0xFF)
    d[1] = UInt8(UInt16(bitPattern: v) >> 8)
    return d
}

private func encodeUInt16LE(_ v: UInt16) -> Data {
    var d = Data(count: 2)
    d[0] = UInt8(v & 0xFF); d[1] = UInt8(v >> 8)
    return d
}

private func encodeInt32LE(_ v: Int32) -> Data {
    var d = Data(count: 4)
    writeU32LE(&d, offset: 0, value: UInt32(bitPattern: v))
    return d
}

private func encodeUInt32LE(_ v: UInt32) -> Data {
    var d = Data(count: 4)
    writeU32LE(&d, offset: 0, value: v)
    return d
}

private func encodeInt64LE(_ v: Int64) -> Data {
    var d = Data(count: 8)
    writeU64LE(&d, offset: 0, value: UInt64(bitPattern: v))
    return d
}

private func encodeRational(_ r: AAFRational) -> Data {
    return encodeInt32LE(r.numerator) + encodeInt32LE(r.denominator)
}

private func encodeAUID(_ a: AUID) -> Data {
    return Data(a.bytesLE)
}

private func encodeMobID(_ m: AAFMobID) -> Data {
    return Data(m.bytes)
}

private func encodeUTF16LE(_ s: String) -> Data {
    var d = Data()
    for unit in s.utf16 {
        d.append(UInt8(unit & 0xFF))
        d.append(UInt8(unit >> 8))
    }
    // Null terminator
    d.append(0); d.append(0)
    return d
}

private func encodeBool(_ b: Bool) -> Data {
    return Data([b ? 0x01 : 0x00])
}

/// Encode strong reference name (UTF-16LE of the sub-storage name)
private func encodeStrongRefName(_ name: String, pid: UInt16) -> Data {
    return encodeUTF16LE(String(format: "%@-%04x", name, pid))
}

/// Encode timestamp {year:u16, month:u8, day:u8, hour:u8, minute:u8, second:u8, pad:u8}
private func encodeTimestamp(_ date: Date = Date()) -> Data {
    let cal = Calendar(identifier: .gregorian)
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    var d = Data(count: 8)
    writeU16LE(&d, offset: 0, value: UInt16(c.year ?? 2025))
    d[2] = UInt8(c.month ?? 1); d[3] = UInt8(c.day ?? 1)
    d[4] = UInt8(c.hour ?? 0); d[5] = UInt8(c.minute ?? 0)
    d[6] = UInt8(c.second ?? 0); d[7] = 0
    return d
}

/// Encode AAF VersionType record {major: u8, minor: u8}
private func encodeVersion(major: UInt8, minor: UInt8) -> Data {
    return Data([major, minor])
}

/// Encode ProductVersion: {major:u16, minor:u16, tertiary:u16, patchLevel:u16, type:u16}
private func encodeProductVersion() -> Data {
    var d = Data(count: 10)
    writeU16LE(&d, offset: 0, value: 1)  // major
    writeU16LE(&d, offset: 2, value: 0)  // minor
    writeU16LE(&d, offset: 4, value: 0)  // tertiary
    writeU16LE(&d, offset: 6, value: 0)  // patchLevel
    writeU16LE(&d, offset: 8, value: 1)  // type: kAAFVersionReleased
    return d
}

/// Encode an array of AUIDs (raw AUID bytes, no count prefix — count derived from data size)
private func encodeAUIDArray(_ auids: [AUID]) -> Data {
    var d = Data()
    for a in auids { d.append(contentsOf: a.bytesLE) }
    return d
}

/// Encode VideoLineMap (raw Int32 bytes, no count prefix — count derived from data size)
private func encodeVideoLineMap(_ lines: [Int32]) -> Data {
    var d = Data()
    for l in lines { d.append(encodeInt32LE(l)) }
    return d
}

/// Encode weak reference data
private func encodeWeakRef(weakrefIndex: UInt16, keyPID: UInt16, key: AUID) -> Data {
    var d = Data()
    d.append(encodeUInt16LE(weakrefIndex))
    d.append(encodeUInt16LE(keyPID))
    d.append(UInt8(16))  // key_size for AUID
    d.append(contentsOf: key.bytesLE)
    return d
}

// MARK: - StrongRefVector/Set index encoders

/// Encode index stream for SF_STRONG_OBJECT_REFERENCE_VECTOR
/// Format: count(u32) + next_free_key(u32) + last_free_key(u32=0xFFFFFFFF) + local_keys[](u32 each)
private func encodeStrongRefVectorIndex(count: Int) -> Data {
    var d = Data()
    d.append(encodeUInt32LE(UInt32(count)))
    d.append(encodeUInt32LE(UInt32(count)))  // next_free_key = count
    d.append(encodeUInt32LE(0xFFFFFFFF))     // last_free_key
    for i in 0..<count {
        d.append(encodeUInt32LE(UInt32(i)))
    }
    return d
}

/// Encode index stream for SF_STRONG_OBJECT_REFERENCE_SET with AUID keys
/// Format: count(u32) + next_free_key(u32) + last_free_key(u32) + key_pid(u16) + key_size(u8)
///         + entries[](local_key:u32 + ref_count:u32 + unique_key:bytes)
private func encodeStrongRefSetIndex_AUID(entries: [(localKey: UInt32, key: AUID)],
                                           keyPID: UInt16) -> Data {
    var d = Data()
    d.append(encodeUInt32LE(UInt32(entries.count)))
    d.append(encodeUInt32LE(UInt32(entries.count)))  // next_free_key
    d.append(encodeUInt32LE(0xFFFFFFFF))             // last_free_key
    d.append(encodeUInt16LE(keyPID))
    d.append(UInt8(16))  // key_size = 16 for AUID
    for e in entries {
        d.append(encodeUInt32LE(e.localKey))
        d.append(encodeUInt32LE(1))  // ref_count
        d.append(contentsOf: e.key.bytesLE)
    }
    return d
}

/// Encode index stream for SF_STRONG_OBJECT_REFERENCE_SET with MobID keys
private func encodeStrongRefSetIndex_MobID(entries: [(localKey: UInt32, key: AAFMobID)],
                                            keyPID: UInt16) -> Data {
    var d = Data()
    d.append(encodeUInt32LE(UInt32(entries.count)))
    d.append(encodeUInt32LE(UInt32(entries.count)))  // next_free_key
    d.append(encodeUInt32LE(0xFFFFFFFF))             // last_free_key
    d.append(encodeUInt16LE(keyPID))
    d.append(UInt8(32))  // key_size = 32 for MobID
    for e in entries {
        d.append(encodeUInt32LE(e.localKey))
        d.append(encodeUInt32LE(1))  // ref_count
        d.append(contentsOf: e.key.bytes)
    }
    return d
}

// MARK: - Referenced Properties Stream

/// Build the /referenced properties stream.
/// Each path is a list of PIDs from Root to a StrongRefSet that weak refs target.
private func encodeReferencedProperties(paths: [[UInt16]]) -> Data {
    var d = Data()
    d.append(0x4C)  // byte_order LE
    // path_count
    d.append(encodeUInt16LE(UInt16(paths.count)))
    // pid_count (total PIDs including null terminators)
    let pidCount = paths.reduce(0) { $0 + $1.count + 1 }  // +1 for each null terminator
    d.append(encodeUInt32LE(UInt32(pidCount)))
    // PIDs
    for path in paths {
        for pid in path { d.append(encodeUInt16LE(pid)) }
        d.append(encodeUInt16LE(0x0000))  // null terminator
    }
    return d
}

// MARK: - AAF File Builder

/// Info about a media clip for AAF generation
struct AAFClipInfo {
    let videoMXFPath: String
    let audioMXFPaths: [String]     // OP-Atom: separate audio files; OP-1a: empty (audio in video MXF)
    let width: Int
    let height: Int
    let duration: Int64          // frame count
    let fpsNumerator: Int32
    let fpsDenominator: Int32
    let isDropFrame: Bool
    let timecode: String         // "HH:MM:SS:FF"
    let audioBits: Int
    let audioSampleRate: Int
    let audioChannels: Int       // channels per audio track/file
    let audioChannelCounts: [Int] // channel count for each audio track/file
    let audioTrackCount: Int     // total number of audio tracks
    let isOPAtom: Bool
    let codecVariant: String     // e.g. "proxy", "422lt", "422", "422hq", "4444", "4444xq", "pass"
    let videoMXFUMID: Data       // 32 bytes Source Package UMID from video MXF
    let audioMXFUMIDs: [Data]    // 32 bytes each, per audio MXF (OP-Atom only)
    let totalAudioSamples: Int64 // total audio samples (for audio length in AAF)
}

/// Generate a single AAF containing all clips in sequence (-ea mode)
func generateAAFSequence(clips: [AAFClipInfo], outputPath: String) -> Bool {
    guard !clips.isEmpty else {
        print("[AAF] No clips to sequence."); return false
    }

    let cfb = CFBWriter()
    let now = Date()

    // Weak reference table paths:
    // Index 0: DataDefinitions path: Root→Header(0x0002)→Dictionary(0x3B04)→DataDefinitions(0x2605)
    // Index 1: ContainerDefinitions path: Root→Header(0x0002)→Dictionary(0x3B04)→ContainerDefinitions(0x2608)
    let weakRefPaths: [[UInt16]] = [
        [PID.rootHeader, PID.hdrDictionary, PID.dataDefs],
        [PID.rootHeader, PID.hdrDictionary, PID.containerDefs],
    ]

    // ── MetaDictionary (empty baseline — no extensions) ──
    let metaDictID = cfb.createStorage(name: "MetaDictionary-1", parentID: 0, classID: AAFClass.metaDictionary)
    let metaDictProps = encodePropertiesStream([
        PropEntry(pid: PID.classDefs, format: SF.strongRefSet.rawValue,
                  data: encodeUTF16LE("ClassDefinitions")),
        PropEntry(pid: PID.typeDefs, format: SF.strongRefSet.rawValue,
                  data: encodeUTF16LE("TypeDefinitions")),
    ])
    cfb.createStream(name: "properties", parentID: metaDictID, data: metaDictProps)

    // Empty ClassDefinitions set
    let classDefsID = cfb.createStorage(name: "ClassDefinitions", parentID: metaDictID)
    cfb.createStream(name: "ClassDefinitions index", parentID: classDefsID,
                     data: encodeStrongRefSetIndex_AUID(entries: [], keyPID: 0x0005))

    // Empty TypeDefinitions set
    let typeDefsID = cfb.createStorage(name: "TypeDefinitions", parentID: metaDictID)
    cfb.createStream(name: "TypeDefinitions index", parentID: typeDefsID,
                     data: encodeStrongRefSetIndex_AUID(entries: [], keyPID: 0x0005))

    // ── Header (Preface) ──
    let headerID = cfb.createStorage(name: "Header-2", parentID: 0, classID: AAFClass.header)

    // ── Dictionary (with DataDefs + ContainerDefs) ──
    let dictID = cfb.createStorage(name: String(format: "Dictionary-%04x", PID.hdrDictionary),
                                   parentID: headerID, classID: AAFClass.dictionary)

    // DataDefinitions set
    let dataDefsID = cfb.createStorage(name: "DataDefinitions", parentID: dictID)
    createDefinitionObject(cfb: cfb, parentID: dataDefsID, localKey: 0,
                           classAUID: AAFClass.dataDefinition,
                           ident: DataDef.picture, name: "Picture")
    createDefinitionObject(cfb: cfb, parentID: dataDefsID, localKey: 1,
                           classAUID: AAFClass.dataDefinition,
                           ident: DataDef.sound, name: "Sound")
    createDefinitionObject(cfb: cfb, parentID: dataDefsID, localKey: 2,
                           classAUID: AAFClass.dataDefinition,
                           ident: DataDef.timecode, name: "Timecode")
    cfb.createStream(name: "DataDefinitions index", parentID: dataDefsID,
                     data: encodeStrongRefSetIndex_AUID(
                        entries: [(0, DataDef.picture), (1, DataDef.sound), (2, DataDef.timecode)],
                        keyPID: PID.defIdent))

    // ContainerDefinitions set
    let containerDefsID = cfb.createStorage(name: "ContainerDefinitions", parentID: dictID)
    createDefinitionObject(cfb: cfb, parentID: containerDefsID, localKey: 0,
                           classAUID: AAFClass.containerDef,
                           ident: ContainerDef.aafklv, name: "AAF KLV (MXF)")
    createDefinitionObject(cfb: cfb, parentID: containerDefsID, localKey: 1,
                           classAUID: AAFClass.containerDef,
                           ident: ContainerDef.external, name: "External")
    createDefinitionObject(cfb: cfb, parentID: containerDefsID, localKey: 2,
                           classAUID: AAFClass.containerDef,
                           ident: ContainerDef.aaf, name: "AAF")
    cfb.createStream(name: "ContainerDefinitions index", parentID: containerDefsID,
                     data: encodeStrongRefSetIndex_AUID(
                        entries: [(0, ContainerDef.aafklv), (1, ContainerDef.external), (2, ContainerDef.aaf)],
                        keyPID: PID.defIdent))

    // Empty OperationDefinitions set
    let opDefsID = cfb.createStorage(name: "OperationDefinitions", parentID: dictID)
    cfb.createStream(name: "OperationDefinitions index", parentID: opDefsID,
                     data: encodeStrongRefSetIndex_AUID(entries: [], keyPID: PID.defIdent))

    // Empty CodecDefinitions set
    let codecDefsID = cfb.createStorage(name: "CodecDefinitions", parentID: dictID)
    cfb.createStream(name: "CodecDefinitions index", parentID: codecDefsID,
                     data: encodeStrongRefSetIndex_AUID(entries: [], keyPID: PID.defIdent))

    let dictProps = encodePropertiesStream([
        PropEntry(pid: PID.opDefs, format: SF.strongRefSet.rawValue,
                  data: encodeUTF16LE("OperationDefinitions")),
        PropEntry(pid: PID.dataDefs, format: SF.strongRefSet.rawValue,
                  data: encodeUTF16LE("DataDefinitions")),
        PropEntry(pid: PID.codecDefs, format: SF.strongRefSet.rawValue,
                  data: encodeUTF16LE("CodecDefinitions")),
        PropEntry(pid: PID.containerDefs, format: SF.strongRefSet.rawValue,
                  data: encodeUTF16LE("ContainerDefinitions")),
    ])
    cfb.createStream(name: "properties", parentID: dictID, data: dictProps)

    // ── ContentStorage ──
    let contentID = cfb.createStorage(name: String(format: "Content-%04x", PID.content),
                                      parentID: headerID, classID: AAFClass.contentStorage)

    // ── Build mobs ──
    var allMobEntries: [(localKey: UInt32, key: AAFMobID)] = []
    var mobLocalKey: UInt32 = 0

    // For the composition mob
    let compMobID = AAFMobID.generate()

    var compVideoClips: [CompSlotClip] = []
    var compAudioClips: [[CompSlotClip]] = []  // grouped by audio track index

    // For each clip, create SourceMob(s) + ONE unified MasterMob
    let mobsID = cfb.createStorage(name: "Mobs", parentID: contentID)

    for clip in clips {
        let editRate = AAFRational(numerator: clip.fpsNumerator, denominator: clip.fpsDenominator)
        let fpsInt = Int(round(Double(clip.fpsNumerator) / Double(clip.fpsDenominator)))
        let clipName = URL(fileURLWithPath: clip.videoMXFPath).deletingPathExtension().lastPathComponent
        let audioTrackCount = clip.audioTrackCount

        // Source Mob(s) + MasterMob slot definitions
        var vSrcMobID: AAFMobID!
        var aSrcMobIDs: [AAFMobID] = []

        // ── MasterMob slot mapping: (dataDef, srcMobID, srcSlotID) ──
        struct MSlot {
            let dataDef: AUID; let srcMobID: AAFMobID; let srcSlotID: UInt32
        }
        var masterSlots: [MSlot] = []

        if clip.isOPAtom {
            // === OP-Atom: separate SourceMobs per file ===

            // Video SourceMob (video + TC slots) — use MXF Source Package UMID
            vSrcMobID = AAFMobID()
            vSrcMobID.bytes = Array(clip.videoMXFUMID)
            let compressionAUID = ProResCompressionAUID.from(clip.codecVariant)
            createMobStorage(
                cfb: cfb, parentID: mobsID, localKey: mobLocalKey,
                classAUID: AAFClass.sourceMob, mobID: vSrcMobID,
                name: clipName + ".PHYS", now: now, weakRefPaths: weakRefPaths
            ) { cfb, storageID in
                createSourceMobSlots(
                    cfb: cfb, parentID: storageID,
                    videoLength: clip.duration, editRate: editRate,
                    weakRefPaths: weakRefPaths,
                    timecode: clip.timecode, fps: fpsInt, isDropFrame: clip.isDropFrame)
                createCDCIDescriptor(
                    cfb: cfb, parentID: storageID,
                    width: clip.width, height: clip.height,
                    editRate: editRate, length: clip.duration,
                    mxfPath: clip.videoMXFPath, weakRefPaths: weakRefPaths,
                    compressionAUID: compressionAUID)
            }
            allMobEntries.append((mobLocalKey, vSrcMobID)); mobLocalKey += 1
            masterSlots.append(MSlot(dataDef: DataDef.picture, srcMobID: vSrcMobID, srcSlotID: 1))

            // Audio SourceMobs (one per audio MXF file) — use MXF Source Package UMIDs
            for (i, audioPath) in clip.audioMXFPaths.enumerated() {
                var aSrcMobID = AAFMobID()
                if i < clip.audioMXFUMIDs.count {
                    aSrcMobID.bytes = Array(clip.audioMXFUMIDs[i])
                }
                let audioBaseName = URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
                let audioEditRate = AAFRational(numerator: Int32(clip.audioSampleRate), denominator: 1)
                createAudioSourceMob(
                    cfb: cfb, parentID: mobsID, localKey: mobLocalKey,
                    mobID: aSrcMobID,
                    name: audioBaseName + ".PHYS",
                    editRate: audioEditRate, length: clip.totalAudioSamples,
                    audioBits: clip.audioBits, sampleRate: clip.audioSampleRate,
                    channels: clip.audioChannels,
                    mxfPath: audioPath, now: now, weakRefPaths: weakRefPaths)
                allMobEntries.append((mobLocalKey, aSrcMobID)); mobLocalKey += 1
                aSrcMobIDs.append(aSrcMobID)
                masterSlots.append(MSlot(dataDef: DataDef.sound, srcMobID: aSrcMobID, srcSlotID: 1))
            }

        } else {
            // === OP-1a: ONE SourceMob with video + audio + TC slots ===

            // Use MXF Source Package UMID as SourceMob MobID
            vSrcMobID = AAFMobID()
            vSrcMobID.bytes = Array(clip.videoMXFUMID)
            let compressionAUID = ProResCompressionAUID.from(clip.codecVariant)
            createMobStorage(
                cfb: cfb, parentID: mobsID, localKey: mobLocalKey,
                classAUID: AAFClass.sourceMob, mobID: vSrcMobID,
                name: clipName + ".PHYS", now: now, weakRefPaths: weakRefPaths
            ) { cfb, storageID in
                // Build all slots: video + audio(s) + TC
                let slotsID = cfb.createStorage(name: "Slots", parentID: storageID)
                var slotIdx = 0

                // Video slot (slotID=1)
                let vs = cfb.createStorage(name: "Slots{0}", parentID: slotsID,
                                           classID: AAFClass.timelineMobSlot)
                let vseg = cfb.createStorage(
                    name: String(format: "Segment-%04x", PID.segment), parentID: vs,
                    classID: AAFClass.sourceClip)
                cfb.createStream(name: "properties", parentID: vseg, data: encodePropertiesStream([
                    PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                              data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: DataDef.picture)),
                    PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(clip.duration)),
                    PropEntry(pid: PID.sourceID, format: SF.data.rawValue, data: encodeMobID(.zero)),
                    PropEntry(pid: PID.srcMobSlotID, format: SF.data.rawValue, data: encodeUInt32LE(0)),
                    PropEntry(pid: PID.startTime, format: SF.data.rawValue, data: encodeInt64LE(0)),
                ]))
                cfb.createStream(name: "properties", parentID: vs, data: encodePropertiesStream([
                    PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(1)),
                    PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                              data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
                    PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
                    PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
                ]))
                slotIdx = 1

                // Audio slots (slotID=2, 3, ...)
                for i in 0..<audioTrackCount {
                    let aSlot = cfb.createStorage(
                        name: String(format: "Slots{%x}", slotIdx), parentID: slotsID,
                        classID: AAFClass.timelineMobSlot)
                    let aSeg = cfb.createStorage(
                        name: String(format: "Segment-%04x", PID.segment), parentID: aSlot,
                        classID: AAFClass.sourceClip)
                    cfb.createStream(name: "properties", parentID: aSeg, data: encodePropertiesStream([
                        PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                                  data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: DataDef.sound)),
                        PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(clip.duration)),
                        PropEntry(pid: PID.sourceID, format: SF.data.rawValue, data: encodeMobID(.zero)),
                        PropEntry(pid: PID.srcMobSlotID, format: SF.data.rawValue, data: encodeUInt32LE(0)),
                        PropEntry(pid: PID.startTime, format: SF.data.rawValue, data: encodeInt64LE(0)),
                    ]))
                    cfb.createStream(name: "properties", parentID: aSlot, data: encodePropertiesStream([
                        PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(UInt32(2 + i))),
                        PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                                  data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
                        PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
                        PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
                    ]))
                    slotIdx += 1
                }

                // TC slot
                let tcSlot = cfb.createStorage(
                    name: String(format: "Slots{%x}", slotIdx), parentID: slotsID,
                    classID: AAFClass.timelineMobSlot)
                let tcLength = Int64(fpsInt) * 60 * 60 * 12
                let startFrame = tcToFrames(clip.timecode, fps: fpsInt, drop: clip.isDropFrame)
                let tcSeg = cfb.createStorage(
                    name: String(format: "Segment-%04x", PID.segment), parentID: tcSlot,
                    classID: AAFClass.timecode)
                cfb.createStream(name: "properties", parentID: tcSeg, data: encodePropertiesStream([
                    PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                              data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: DataDef.timecode)),
                    PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(tcLength)),
                    PropEntry(pid: PID.tcStart, format: SF.data.rawValue, data: encodeInt64LE(Int64(startFrame))),
                    PropEntry(pid: PID.tcFPS, format: SF.data.rawValue, data: encodeUInt16LE(UInt16(fpsInt))),
                    PropEntry(pid: PID.tcDrop, format: SF.data.rawValue, data: encodeBool(clip.isDropFrame)),
                ]))
                cfb.createStream(name: "properties", parentID: tcSlot, data: encodePropertiesStream([
                    PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(UInt32(2 + audioTrackCount))),
                    PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                              data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
                    PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
                    PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
                ]))
                slotIdx += 1

                cfb.createStream(name: "Slots index", parentID: slotsID,
                                 data: encodeStrongRefVectorIndex(count: slotIdx))

                // CDCI Descriptor (covers the whole OP-1a file)
                createCDCIDescriptor(
                    cfb: cfb, parentID: storageID,
                    width: clip.width, height: clip.height,
                    editRate: editRate, length: clip.duration,
                    mxfPath: clip.videoMXFPath, weakRefPaths: weakRefPaths,
                    compressionAUID: compressionAUID)
            }
            allMobEntries.append((mobLocalKey, vSrcMobID)); mobLocalKey += 1

            // MasterMob slot mapping: video → slot 1, audio → slots 2, 3, ...
            masterSlots.append(MSlot(dataDef: DataDef.picture, srcMobID: vSrcMobID, srcSlotID: 1))
            for i in 0..<audioTrackCount {
                masterSlots.append(MSlot(dataDef: DataDef.sound, srcMobID: vSrcMobID,
                                         srcSlotID: UInt32(2 + i)))
            }
        }

        // ── ONE unified MasterMob per clip ──
        let masterMobID = AAFMobID.generate()
        let masterStorageID = cfb.createStorage(
            name: String(format: "Mobs{%x}", mobLocalKey), parentID: mobsID,
            classID: AAFClass.masterMob)

        let mSlotsID = cfb.createStorage(name: "Slots", parentID: masterStorageID)
        for (i, ms) in masterSlots.enumerated() {
            let isAudioSlot = (ms.dataDef == DataDef.sound)
            let slotEditRate: AAFRational
            let slotLength: Int64
            if isAudioSlot {
                slotEditRate = AAFRational(numerator: Int32(clip.audioSampleRate), denominator: 1)
                slotLength = clip.totalAudioSamples
            } else {
                slotEditRate = editRate
                slotLength = clip.duration
            }
            let mSlot = cfb.createStorage(
                name: String(format: "Slots{%x}", i), parentID: mSlotsID,
                classID: AAFClass.timelineMobSlot)
            let mSeg = cfb.createStorage(
                name: String(format: "Segment-%04x", PID.segment), parentID: mSlot,
                classID: AAFClass.sourceClip)
            cfb.createStream(name: "properties", parentID: mSeg, data: encodePropertiesStream([
                PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                          data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: ms.dataDef)),
                PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(slotLength)),
                PropEntry(pid: PID.sourceID, format: SF.data.rawValue, data: encodeMobID(ms.srcMobID)),
                PropEntry(pid: PID.srcMobSlotID, format: SF.data.rawValue, data: encodeUInt32LE(ms.srcSlotID)),
                PropEntry(pid: PID.startTime, format: SF.data.rawValue, data: encodeInt64LE(0)),
            ]))
            cfb.createStream(name: "properties", parentID: mSlot, data: encodePropertiesStream([
                PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(UInt32(i + 1))),
                PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                          data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
                PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(slotEditRate)),
                PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
            ]))
        }
        cfb.createStream(name: "Slots index", parentID: mSlotsID,
                         data: encodeStrongRefVectorIndex(count: masterSlots.count))

        let masterProps = encodePropertiesStream([
            PropEntry(pid: PID.mobID, format: SF.data.rawValue, data: encodeMobID(masterMobID)),
            PropEntry(pid: PID.mobName, format: SF.data.rawValue, data: encodeUTF16LE(clipName)),
            PropEntry(pid: PID.mobSlots, format: SF.strongRefVector.rawValue,
                      data: encodeUTF16LE("Slots")),
            PropEntry(pid: PID.mobLastMod, format: SF.data.rawValue, data: encodeTimestamp(now)),
            PropEntry(pid: PID.mobCreation, format: SF.data.rawValue, data: encodeTimestamp(now)),
        ])
        cfb.createStream(name: "properties", parentID: masterStorageID, data: masterProps)
        allMobEntries.append((mobLocalKey, masterMobID)); mobLocalKey += 1

        // Accumulate composition clips (all reference the unified MasterMob)
        compVideoClips.append(CompSlotClip(
            masterMobID: masterMobID, slotID: 1, length: clip.duration,
            editRate: editRate, isAudio: false, audioTrackIdx: 0))

        for i in 0..<audioTrackCount {
            let audioEditRateForComp = AAFRational(numerator: Int32(clip.audioSampleRate), denominator: 1)
            let clipInfo = CompSlotClip(
                masterMobID: masterMobID, slotID: UInt32(2 + i), length: clip.totalAudioSamples,
                editRate: audioEditRateForComp, isAudio: true, audioTrackIdx: i)
            if i >= compAudioClips.count {
                compAudioClips.append([clipInfo])
            } else {
                compAudioClips[i].append(clipInfo)
            }
        }
    }

    // ── CompositionMob ──
    let compStorageID = cfb.createStorage(
        name: String(format: "Mobs{%x}", mobLocalKey), parentID: mobsID,
        classID: AAFClass.compositionMob)
    allMobEntries.append((mobLocalKey, compMobID))

    let firstClip = clips[0]
    let compEditRate = AAFRational(numerator: firstClip.fpsNumerator,
                                   denominator: firstClip.fpsDenominator)
    let fpsInt = Int(round(Double(firstClip.fpsNumerator) / Double(firstClip.fpsDenominator)))
    let totalDuration = compVideoClips.reduce(Int64(0)) { $0 + $1.length }

    // Create Slots container first, then add slot children inside it
    let compSlotsID = cfb.createStorage(name: "Slots", parentID: compStorageID)
    var compSlotIdx: UInt32 = 0
    var compSlotIDCounter: UInt32 = 1

    // TC slot
    createCompositionSlot_Timecode(
        cfb: cfb, parentID: compSlotsID, slotLocalKey: compSlotIdx,
        slotID: compSlotIDCounter, editRate: compEditRate,
        timecode: firstClip.timecode, fps: fpsInt,
        isDropFrame: firstClip.isDropFrame,
        length: totalDuration, weakRefPaths: weakRefPaths
    )
    compSlotIdx += 1
    compSlotIDCounter += 1

    // V1 slot (video sequence)
    createCompositionSlot_Sequence(
        cfb: cfb, parentID: compSlotsID, slotLocalKey: compSlotIdx,
        slotID: compSlotIDCounter, slotName: "V1", editRate: compEditRate,
        dataDef: DataDef.picture, clips: compVideoClips,
        weakRefPaths: weakRefPaths
    )
    compSlotIdx += 1
    compSlotIDCounter += 1

    // Audio slots
    for (trackIdx, audioClips) in compAudioClips.enumerated() {
        let audioSlotEditRate = audioClips.first?.editRate
            ?? AAFRational(numerator: Int32(firstClip.audioSampleRate), denominator: 1)
        createCompositionSlot_Sequence(
            cfb: cfb, parentID: compSlotsID, slotLocalKey: compSlotIdx,
            slotID: compSlotIDCounter, slotName: "A\(trackIdx + 1)",
            editRate: audioSlotEditRate,
            dataDef: DataDef.sound, clips: audioClips,
            weakRefPaths: weakRefPaths
        )
        compSlotIdx += 1
        compSlotIDCounter += 1
    }

    // Slots index
    cfb.createStream(name: "Slots index", parentID: compSlotsID,
                     data: encodeStrongRefVectorIndex(count: Int(compSlotIdx)))

    // Composition mob properties
    let compMobProps = encodePropertiesStream([
        PropEntry(pid: PID.mobID, format: SF.data.rawValue, data: encodeMobID(compMobID)),
        PropEntry(pid: PID.mobName, format: SF.data.rawValue, data: encodeUTF16LE("ProRes Sequence")),
        PropEntry(pid: PID.mobSlots, format: SF.strongRefVector.rawValue,
                  data: encodeUTF16LE("Slots")),
        PropEntry(pid: PID.mobLastMod, format: SF.data.rawValue, data: encodeTimestamp(now)),
        PropEntry(pid: PID.mobCreation, format: SF.data.rawValue, data: encodeTimestamp(now)),
        PropEntry(pid: PID.mobUsage, format: SF.data.rawValue,
                  data: encodeAUID(AUID("0d010101-0101-0e00-060e-2b3404010105"))),
    ])
    cfb.createStream(name: "properties", parentID: compStorageID, data: compMobProps)

    // Mobs index
    cfb.createStream(name: "Mobs index", parentID: mobsID,
                     data: encodeStrongRefSetIndex_MobID(entries: allMobEntries, keyPID: PID.mobID))

    // ContentStorage properties
    let contentProps = encodePropertiesStream([
        PropEntry(pid: PID.mobs, format: SF.strongRefSet.rawValue,
                  data: encodeUTF16LE("Mobs")),
    ])
    cfb.createStream(name: "properties", parentID: contentID, data: contentProps)

    // ── IdentificationList ──
    let identListID = cfb.createStorage(name: "IdentificationList", parentID: headerID)
    cfb.createStream(name: "IdentificationList index", parentID: identListID,
                     data: encodeStrongRefVectorIndex(count: 1))
    let ident0ID = cfb.createStorage(
        name: "IdentificationList{0}", parentID: identListID,
        classID: AAFClass.identification)
    let identProps = encodePropertiesStream([
        PropEntry(pid: PID.companyName, format: SF.data.rawValue,
                  data: encodeUTF16LE("ProRes Encoder")),
        PropEntry(pid: PID.productName, format: SF.data.rawValue,
                  data: encodeUTF16LE("ProRes Encoder")),
        PropEntry(pid: PID.productVersion, format: SF.data.rawValue,
                  data: encodeProductVersion()),
        PropEntry(pid: PID.prodVerString, format: SF.data.rawValue,
                  data: encodeUTF16LE("1.0.0")),
        PropEntry(pid: PID.productID, format: SF.data.rawValue,
                  data: encodeAUID(AUID("97e04c67-dbe6-4d11-bcd7-3a3a4253a2ef"))),
        PropEntry(pid: PID.identDate, format: SF.data.rawValue,
                  data: encodeTimestamp(now)),
        PropEntry(pid: PID.platform, format: SF.data.rawValue,
                  data: encodeUTF16LE("macOS")),
        PropEntry(pid: PID.generationAUID, format: SF.data.rawValue,
                  data: encodeAUID(.random())),
    ])
    cfb.createStream(name: "properties", parentID: ident0ID, data: identProps)

    // ── Header properties ──
    let headerProps = encodePropertiesStream([
        PropEntry(pid: PID.byteOrder, format: SF.data.rawValue, data: encodeInt16LE(0x4949)),
        PropEntry(pid: PID.lastModified, format: SF.data.rawValue, data: encodeTimestamp(now)),
        PropEntry(pid: PID.content, format: SF.strongRef.rawValue,
                  data: encodeUTF16LE(String(format: "Content-%04x", PID.content))),
        PropEntry(pid: PID.hdrDictionary, format: SF.strongRef.rawValue,
                  data: encodeUTF16LE(String(format: "Dictionary-%04x", PID.hdrDictionary))),
        PropEntry(pid: PID.version, format: SF.data.rawValue, data: encodeVersion(major: 1, minor: 2)),
        PropEntry(pid: PID.identList, format: SF.strongRefVector.rawValue,
                  data: encodeUTF16LE("IdentificationList")),
        PropEntry(pid: PID.objModelVer, format: SF.data.rawValue, data: encodeUInt32LE(1)),
        PropEntry(pid: PID.opPattern, format: SF.data.rawValue,
                  data: encodeAUID(AUID("0d011201-0100-0000-060e-2b3404010105"))),
        PropEntry(pid: PID.essContainers, format: SF.data.rawValue,
                  data: encodeAUIDArray([ContainerDef.aafklv])),
    ])
    cfb.createStream(name: "properties", parentID: headerID, data: headerProps)

    // ── Root properties ──
    let rootProps = encodePropertiesStream([
        PropEntry(pid: PID.rootMetaDict, format: SF.strongRef.rawValue,
                  data: encodeUTF16LE("MetaDictionary-1")),
        PropEntry(pid: PID.rootHeader, format: SF.strongRef.rawValue,
                  data: encodeUTF16LE("Header-2")),
    ])
    cfb.createStream(name: "properties", parentID: 0, data: rootProps)

    // ── Referenced properties stream ──
    cfb.createStream(name: "referenced properties", parentID: 0,
                     data: encodeReferencedProperties(paths: weakRefPaths))

    // ── Finalize and write ──
    let fileData = cfb.finalize()
    do {
        try fileData.write(to: URL(fileURLWithPath: outputPath))
        print("[AAF] Sequence written: \(outputPath)")
        return true
    } catch {
        print("[AAF] Write failed: \(error.localizedDescription)")
        return false
    }
}

/// Generate one AAF per clip (-ea-all mode)
func generateAAFPerClip(clips: [AAFClipInfo], outputDir: String, basename: String) -> Bool {
    var allOK = true
    for (idx, clip) in clips.enumerated() {
        let suffix = clips.count > 1 ? "_\(idx + 1)" : ""
        let outputPath = (outputDir as NSString).appendingPathComponent("\(basename)\(suffix).aaf")
        if !generateAAFSequence(clips: [clip], outputPath: outputPath) {
            allOK = false
        }
    }
    return allOK
}

// MARK: - Helper: Create mob-level structures

/// Create a SourceMob storage with properties, calling the body to add slots + descriptor
@discardableResult
private func createMobStorage(
    cfb: CFBWriter, parentID: Int, localKey: UInt32,
    classAUID: AUID, mobID: AAFMobID, name: String, now: Date,
    weakRefPaths: [[UInt16]],
    body: (CFBWriter, Int) -> Void
) -> Int {
    let storageID = cfb.createStorage(
        name: String(format: "Mobs{%x}", localKey), parentID: parentID,
        classID: classAUID)
    body(cfb, storageID)

    // Build properties list — varies by mob type
    var props: [PropEntry] = [
        PropEntry(pid: PID.mobID, format: SF.data.rawValue, data: encodeMobID(mobID)),
        PropEntry(pid: PID.mobName, format: SF.data.rawValue, data: encodeUTF16LE(name)),
        PropEntry(pid: PID.mobSlots, format: SF.strongRefVector.rawValue,
                  data: encodeUTF16LE("Slots")),
        PropEntry(pid: PID.mobLastMod, format: SF.data.rawValue, data: encodeTimestamp(now)),
        PropEntry(pid: PID.mobCreation, format: SF.data.rawValue, data: encodeTimestamp(now)),
    ]
    if classAUID == AAFClass.sourceMob {
        props.append(PropEntry(pid: PID.essDesc, format: SF.strongRef.rawValue,
                               data: encodeUTF16LE(String(format: "EssenceDescription-%04x", PID.essDesc))))
    }
    cfb.createStream(name: "properties", parentID: storageID, data: encodePropertiesStream(props))
    return storageID
}

/// Create video SourceMob slots: 1 video slot with empty SourceClip + 1 TC slot
private func createSourceMobSlots(
    cfb: CFBWriter, parentID: Int,
    videoLength: Int64, editRate: AAFRational,
    weakRefPaths: [[UInt16]],
    timecode: String, fps: Int, isDropFrame: Bool
) {
    let slotsID = cfb.createStorage(name: "Slots", parentID: parentID)

    // Slot 0: Video
    let slot0ID = cfb.createStorage(name: "Slots{0}", parentID: slotsID,
                                    classID: AAFClass.timelineMobSlot)
    let seg0ID = cfb.createStorage(
        name: String(format: "Segment-%04x", PID.segment), parentID: slot0ID,
        classID: AAFClass.sourceClip)
    // SourceClip with zero MobID = end of chain
    let seg0Props = encodePropertiesStream([
        PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                  data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: DataDef.picture)),
        PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(videoLength)),
        PropEntry(pid: PID.sourceID, format: SF.data.rawValue, data: encodeMobID(.zero)),
        PropEntry(pid: PID.srcMobSlotID, format: SF.data.rawValue, data: encodeUInt32LE(0)),
        PropEntry(pid: PID.startTime, format: SF.data.rawValue, data: encodeInt64LE(0)),
    ])
    cfb.createStream(name: "properties", parentID: seg0ID, data: seg0Props)
    let slot0Props = encodePropertiesStream([
        PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(1)),
        PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                  data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
        PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
        PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
    ])
    cfb.createStream(name: "properties", parentID: slot0ID, data: slot0Props)

    // Slot 1: Timecode
    let slot1ID = cfb.createStorage(name: "Slots{1}", parentID: slotsID,
                                    classID: AAFClass.timelineMobSlot)
    let tcLength = Int64(fps) * 60 * 60 * 12  // 12 hours
    let startFrame = tcToFrames(timecode, fps: fps, drop: isDropFrame)
    let seg1ID = cfb.createStorage(
        name: String(format: "Segment-%04x", PID.segment), parentID: slot1ID,
        classID: AAFClass.timecode)
    let seg1Props = encodePropertiesStream([
        PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                  data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: DataDef.timecode)),
        PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(tcLength)),
        PropEntry(pid: PID.tcStart, format: SF.data.rawValue, data: encodeInt64LE(Int64(startFrame))),
        PropEntry(pid: PID.tcFPS, format: SF.data.rawValue, data: encodeUInt16LE(UInt16(fps))),
        PropEntry(pid: PID.tcDrop, format: SF.data.rawValue, data: encodeBool(isDropFrame)),
    ])
    cfb.createStream(name: "properties", parentID: seg1ID, data: seg1Props)
    let slot1Props = encodePropertiesStream([
        PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(2)),
        PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                  data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
        PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
        PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
    ])
    cfb.createStream(name: "properties", parentID: slot1ID, data: slot1Props)

    cfb.createStream(name: "Slots index", parentID: slotsID,
                     data: encodeStrongRefVectorIndex(count: 2))
}

/// Greatest common divisor helper
private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

/// Create CDCI (video) descriptor with NetworkLocator
private func createCDCIDescriptor(
    cfb: CFBWriter, parentID: Int,
    width: Int, height: Int,
    editRate: AAFRational, length: Int64,
    mxfPath: String, weakRefPaths: [[UInt16]],
    compressionAUID: AUID? = nil
) {
    let descID = cfb.createStorage(
        name: String(format: "EssenceDescription-%04x", PID.essDesc), parentID: parentID,
        classID: AAFClass.cdciDescriptor)

    // NetworkLocator
    let locatorsID = cfb.createStorage(name: "Locator", parentID: descID)
    let loc0ID = cfb.createStorage(name: "Locator{0}", parentID: locatorsID,
                                   classID: AAFClass.networkLocator)
    let urlStr = mxfPath.hasPrefix("/") ? "file://localhost" + mxfPath : mxfPath
    cfb.createStream(name: "properties", parentID: loc0ID, data: encodePropertiesStream([
        PropEntry(pid: PID.urlString, format: SF.data.rawValue, data: encodeUTF16LE(urlStr)),
    ]))
    cfb.createStream(name: "Locator index", parentID: locatorsID,
                     data: encodeStrongRefVectorIndex(count: 1))

    // Reduce aspect ratio to lowest terms
    let g = gcd(width, height)
    let arNum = g > 0 ? Int32(width / g) : Int32(width)
    let arDen = g > 0 ? Int32(height / g) : Int32(height)

    var descEntries: [PropEntry] = [
        PropEntry(pid: PID.locators, format: SF.strongRefVector.rawValue,
                  data: encodeUTF16LE("Locator")),
        PropEntry(pid: PID.sampleRate, format: SF.data.rawValue, data: encodeRational(editRate)),
        PropEntry(pid: PID.fdLength, format: SF.data.rawValue, data: encodeInt64LE(length)),
        PropEntry(pid: PID.containerFmt, format: SF.weakRef.rawValue,
                  data: encodeWeakRef(weakrefIndex: 1, keyPID: PID.defIdent, key: ContainerDef.aafklv)),
        PropEntry(pid: PID.storedHeight, format: SF.data.rawValue, data: encodeUInt32LE(UInt32(height))),
        PropEntry(pid: PID.storedWidth, format: SF.data.rawValue, data: encodeUInt32LE(UInt32(width))),
        PropEntry(pid: PID.frameLayout, format: SF.data.rawValue, data: encodeUInt8(0)), // FullFrame
        PropEntry(pid: PID.videoLineMap, format: SF.data.rawValue,
                  data: encodeVideoLineMap([42, 0])),
        PropEntry(pid: PID.imageAspectRatio, format: SF.data.rawValue,
                  data: encodeRational(AAFRational(numerator: arNum, denominator: arDen))),
        PropEntry(pid: PID.componentWidth, format: SF.data.rawValue, data: encodeUInt32LE(10)),
        PropEntry(pid: PID.hSubsampling, format: SF.data.rawValue, data: encodeUInt32LE(2)),
        PropEntry(pid: PID.vSubsampling, format: SF.data.rawValue, data: encodeUInt32LE(1)),
    ]
    if let auid = compressionAUID {
        descEntries.append(PropEntry(pid: PID.compression, format: SF.data.rawValue,
                                     data: encodeAUID(auid)))
    }
    cfb.createStream(name: "properties", parentID: descID, data: encodePropertiesStream(descEntries))
}

/// Create an audio SourceMob with PCMDescriptor + NetworkLocator
private func createAudioSourceMob(
    cfb: CFBWriter, parentID: Int, localKey: UInt32,
    mobID: AAFMobID, name: String,
    editRate: AAFRational, length: Int64,
    audioBits: Int, sampleRate: Int, channels: Int,
    mxfPath: String, now: Date, weakRefPaths: [[UInt16]]
) {
    createMobStorage(
        cfb: cfb, parentID: parentID, localKey: localKey,
        classAUID: AAFClass.sourceMob, mobID: mobID,
        name: name, now: now, weakRefPaths: weakRefPaths
    ) { cfb, storageID in
        // 1 audio slot
        let slotsID = cfb.createStorage(name: "Slots", parentID: storageID)
        let slot0ID = cfb.createStorage(name: "Slots{0}", parentID: slotsID,
                                        classID: AAFClass.timelineMobSlot)
        let segID = cfb.createStorage(
            name: String(format: "Segment-%04x", PID.segment), parentID: slot0ID,
            classID: AAFClass.sourceClip)
        let segProps = encodePropertiesStream([
            PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                      data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: DataDef.sound)),
            PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(length)),
            PropEntry(pid: PID.sourceID, format: SF.data.rawValue, data: encodeMobID(.zero)),
            PropEntry(pid: PID.srcMobSlotID, format: SF.data.rawValue, data: encodeUInt32LE(0)),
            PropEntry(pid: PID.startTime, format: SF.data.rawValue, data: encodeInt64LE(0)),
        ])
        cfb.createStream(name: "properties", parentID: segID, data: segProps)
        let slot0Props = encodePropertiesStream([
            PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(1)),
            PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                      data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
            PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
            PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
        ])
        cfb.createStream(name: "properties", parentID: slot0ID, data: slot0Props)
        cfb.createStream(name: "Slots index", parentID: slotsID,
                         data: encodeStrongRefVectorIndex(count: 1))

        // PCMDescriptor
        let descID = cfb.createStorage(
            name: String(format: "EssenceDescription-%04x", PID.essDesc), parentID: storageID,
            classID: AAFClass.pcmDescriptor)

        let locatorsID = cfb.createStorage(name: "Locator", parentID: descID)
        let loc0ID = cfb.createStorage(name: "Locator{0}", parentID: locatorsID,
                                       classID: AAFClass.networkLocator)
        let urlStr = mxfPath.hasPrefix("/") ? "file://localhost" + mxfPath : mxfPath
        cfb.createStream(name: "properties", parentID: loc0ID,
                         data: encodePropertiesStream([
                            PropEntry(pid: PID.urlString, format: SF.data.rawValue,
                                      data: encodeUTF16LE(urlStr))
                         ]))
        cfb.createStream(name: "Locator index", parentID: locatorsID,
                         data: encodeStrongRefVectorIndex(count: 1))

        let descProps = encodePropertiesStream([
            PropEntry(pid: PID.locators, format: SF.strongRefVector.rawValue,
                      data: encodeUTF16LE("Locator")),
            PropEntry(pid: PID.sampleRate, format: SF.data.rawValue,
                      data: encodeRational(AAFRational(numerator: Int32(sampleRate), denominator: 1))),
            PropEntry(pid: PID.fdLength, format: SF.data.rawValue, data: encodeInt64LE(length)),
            PropEntry(pid: PID.containerFmt, format: SF.weakRef.rawValue,
                      data: encodeWeakRef(weakrefIndex: 1, keyPID: PID.defIdent,
                                          key: ContainerDef.aafklv)),
            PropEntry(pid: PID.quantBits, format: SF.data.rawValue, data: encodeUInt32LE(UInt32(audioBits))),
            PropEntry(pid: PID.audioSampleRate, format: SF.data.rawValue,
                      data: encodeRational(AAFRational(numerator: Int32(sampleRate), denominator: 1))),
            PropEntry(pid: PID.channels, format: SF.data.rawValue, data: encodeUInt32LE(UInt32(channels))),
            PropEntry(pid: PID.blockAlign, format: SF.data.rawValue,
                      data: encodeUInt16LE(UInt16(audioBits / 8 * channels))),
            PropEntry(pid: PID.averageBPS, format: SF.data.rawValue,
                      data: encodeUInt32LE(UInt32(sampleRate * channels * audioBits / 8))),
        ])
        cfb.createStream(name: "properties", parentID: descID, data: descProps)
    }
}

/// Create a MasterMob referencing a SourceMob
private func createMasterMobForSource(
    cfb: CFBWriter, parentID: Int, localKey: UInt32,
    masterMobID: AAFMobID, sourceMobID: AAFMobID,
    name: String, slotCount: Int, editRate: AAFRational, length: Int64,
    dataDef: AUID, now: Date, weakRefPaths: [[UInt16]]
) {
    createMobStorage(
        cfb: cfb, parentID: parentID, localKey: localKey,
        classAUID: AAFClass.masterMob, mobID: masterMobID,
        name: name, now: now, weakRefPaths: weakRefPaths
    ) { cfb, storageID in
        let slotsID = cfb.createStorage(name: "Slots", parentID: storageID)
        let slot0ID = cfb.createStorage(name: "Slots{0}", parentID: slotsID,
                                        classID: AAFClass.timelineMobSlot)

        // Segment: Sequence with one SourceClip pointing to SourceMob
        let seqID = cfb.createStorage(
            name: String(format: "Segment-%04x", PID.segment), parentID: slot0ID,
            classID: AAFClass.sequence)
        let comp0ID = cfb.createStorage(name: "Components{0}", parentID: seqID,
                                        classID: AAFClass.sourceClip)
        let scProps = encodePropertiesStream([
            PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                      data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: dataDef)),
            PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(length)),
            PropEntry(pid: PID.sourceID, format: SF.data.rawValue, data: encodeMobID(sourceMobID)),
            PropEntry(pid: PID.srcMobSlotID, format: SF.data.rawValue, data: encodeUInt32LE(1)),
            PropEntry(pid: PID.startTime, format: SF.data.rawValue, data: encodeInt64LE(0)),
        ])
        cfb.createStream(name: "properties", parentID: comp0ID, data: scProps)

        // Components vector inside Sequence
        let compsID = cfb.createStorage(name: "Components", parentID: seqID)
        cfb.createStream(name: "Components index", parentID: compsID,
                         data: encodeStrongRefVectorIndex(count: 1))

        let seqProps = encodePropertiesStream([
            PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                      data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: dataDef)),
            PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(length)),
            PropEntry(pid: PID.components, format: SF.strongRefVector.rawValue,
                      data: encodeUTF16LE("Components")),
        ])
        cfb.createStream(name: "properties", parentID: seqID, data: seqProps)

        let slot0Props = encodePropertiesStream([
            PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(1)),
            PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                      data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
            PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
            PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
        ])
        cfb.createStream(name: "properties", parentID: slot0ID, data: slot0Props)

        cfb.createStream(name: "Slots index", parentID: slotsID,
                         data: encodeStrongRefVectorIndex(count: 1))
    }
}

/// Create a DefinitionObject (DataDef or ContainerDef)
@discardableResult
private func createDefinitionObject(
    cfb: CFBWriter, parentID: Int, localKey: UInt32,
    classAUID: AUID, ident: AUID, name: String
) -> Int {
    let storageID = cfb.createStorage(
        name: String(format: "%@{%x}",
                     parentID == 0 ? "Entry" :
                        (classAUID == AAFClass.dataDefinition ? "DataDefinitions" : "ContainerDefinitions"),
                     localKey),
        parentID: parentID, classID: classAUID)
    let props = encodePropertiesStream([
        PropEntry(pid: PID.defIdent, format: SF.data.rawValue, data: encodeAUID(ident)),
        PropEntry(pid: PID.defName, format: SF.data.rawValue, data: encodeUTF16LE(name)),
    ])
    cfb.createStream(name: "properties", parentID: storageID, data: props)
    return storageID
}

/// Create a composition timecode slot
@discardableResult
private func createCompositionSlot_Timecode(
    cfb: CFBWriter, parentID: Int, slotLocalKey: UInt32,
    slotID: UInt32, editRate: AAFRational,
    timecode: String, fps: Int, isDropFrame: Bool,
    length: Int64, weakRefPaths: [[UInt16]]
) -> Int {
    let slotStorageID = cfb.createStorage(
        name: String(format: "Slots{%x}", slotLocalKey), parentID: parentID,
        classID: AAFClass.timelineMobSlot)

    let tcLength = Int64(fps) * 60 * 60 * 12
    let startFrame = tcToFrames(timecode, fps: fps, drop: isDropFrame)

    let segID = cfb.createStorage(
        name: String(format: "Segment-%04x", PID.segment), parentID: slotStorageID,
        classID: AAFClass.timecode)
    let segProps = encodePropertiesStream([
        PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                  data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: DataDef.timecode)),
        PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(tcLength)),
        PropEntry(pid: PID.tcStart, format: SF.data.rawValue, data: encodeInt64LE(Int64(startFrame))),
        PropEntry(pid: PID.tcFPS, format: SF.data.rawValue, data: encodeUInt16LE(UInt16(fps))),
        PropEntry(pid: PID.tcDrop, format: SF.data.rawValue, data: encodeBool(isDropFrame)),
    ])
    cfb.createStream(name: "properties", parentID: segID, data: segProps)

    let slotProps = encodePropertiesStream([
        PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(slotID)),
        PropEntry(pid: PID.slotName, format: SF.data.rawValue, data: encodeUTF16LE("TC")),
        PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                  data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
        PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
        PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
    ])
    cfb.createStream(name: "properties", parentID: slotStorageID, data: slotProps)
    return slotStorageID
}

/// Create a composition sequence slot (video or audio)
@discardableResult
private func createCompositionSlot_Sequence(
    cfb: CFBWriter, parentID: Int, slotLocalKey: UInt32,
    slotID: UInt32, slotName: String, editRate: AAFRational,
    dataDef: AUID, clips: [CompSlotClip],
    weakRefPaths: [[UInt16]]
) -> Int {
    let slotStorageID = cfb.createStorage(
        name: String(format: "Slots{%x}", slotLocalKey), parentID: parentID,
        classID: AAFClass.timelineMobSlot)

    // Sequence
    let seqID = cfb.createStorage(
        name: String(format: "Segment-%04x", PID.segment), parentID: slotStorageID,
        classID: AAFClass.sequence)

    let totalLength = clips.reduce(Int64(0)) { $0 + $1.length }

    // Components vector
    let compsID = cfb.createStorage(name: "Components", parentID: seqID)
    for (i, clip) in clips.enumerated() {
        let compID = cfb.createStorage(
            name: String(format: "Components{%x}", i), parentID: compsID,
            classID: AAFClass.sourceClip)
        let compProps = encodePropertiesStream([
            PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                      data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: dataDef)),
            PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(clip.length)),
            PropEntry(pid: PID.sourceID, format: SF.data.rawValue,
                      data: encodeMobID(clip.masterMobID)),
            PropEntry(pid: PID.srcMobSlotID, format: SF.data.rawValue,
                      data: encodeUInt32LE(clip.slotID)),
            PropEntry(pid: PID.startTime, format: SF.data.rawValue, data: encodeInt64LE(0)),
        ])
        cfb.createStream(name: "properties", parentID: compID, data: compProps)
    }
    cfb.createStream(name: "Components index", parentID: compsID,
                     data: encodeStrongRefVectorIndex(count: clips.count))

    let seqProps = encodePropertiesStream([
        PropEntry(pid: PID.dataDefinition, format: SF.weakRef.rawValue,
                  data: encodeWeakRef(weakrefIndex: 0, keyPID: PID.defIdent, key: dataDef)),
        PropEntry(pid: PID.length, format: SF.data.rawValue, data: encodeInt64LE(totalLength)),
        PropEntry(pid: PID.components, format: SF.strongRefVector.rawValue,
                  data: encodeUTF16LE("Components")),
    ])
    cfb.createStream(name: "properties", parentID: seqID, data: seqProps)

    let slotProps = encodePropertiesStream([
        PropEntry(pid: PID.slotID, format: SF.data.rawValue, data: encodeUInt32LE(slotID)),
        PropEntry(pid: PID.slotName, format: SF.data.rawValue, data: encodeUTF16LE(slotName)),
        PropEntry(pid: PID.segment, format: SF.strongRef.rawValue,
                  data: encodeUTF16LE(String(format: "Segment-%04x", PID.segment))),
        PropEntry(pid: PID.editRate, format: SF.data.rawValue, data: encodeRational(editRate)),
        PropEntry(pid: PID.origin, format: SF.data.rawValue, data: encodeInt64LE(0)),
    ])
    cfb.createStream(name: "properties", parentID: slotStorageID, data: slotProps)
    return slotStorageID
}

// MARK: - Private Helpers

private func encodeUInt8(_ v: UInt8) -> Data { Data([v]) }

/// Convert timecode string to frame count
private func tcToFrames(_ tc: String, fps: Int, drop: Bool) -> Int {
    let parts = tc.replacingOccurrences(of: ";", with: ":").split(separator: ":").map { Int($0) ?? 0 }
    guard parts.count == 4 else { return 0 }
    let (hh, mm, ss, ff) = (parts[0], parts[1], parts[2], parts[3])
    if drop {
        let d = fps == 30 ? 2 : 4
        let totalMinutes = 60 * hh + mm
        let dropFrames = d * (totalMinutes - totalMinutes / 10)
        return fps * 3600 * hh + fps * 60 * mm + fps * ss + ff - dropFrames
    }
    return fps * 3600 * hh + fps * 60 * mm + fps * ss + ff
}

// MARK: - Nested type for composition clips

private struct CompSlotClip {
    let masterMobID: AAFMobID
    let slotID: UInt32
    let length: Int64
    let editRate: AAFRational
    let isAudio: Bool
    let audioTrackIdx: Int
}
