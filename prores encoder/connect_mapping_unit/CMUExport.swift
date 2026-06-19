import Foundation

private final class CMUXMLBuilder {
    private var lines: [String] = []
    private var indentation = 0

    func declaration() {
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
    }

    func open(_ name: String, attributes: [String: String] = [:]) {
        let attributesText = attributes
            .sorted { $0.key < $1.key }
            .map { #" \#($0.key)="\#(escape($0.value))""# }
            .joined()
        lines.append(indent + "<\(name)\(attributesText)>")
        indentation += 1
    }

    func close(_ name: String) {
        indentation -= 1
        lines.append(indent + "</\(name)>")
    }

    func element(_ name: String, _ value: String, attributes: [String: String] = [:]) {
        let attributesText = attributes
            .sorted { $0.key < $1.key }
            .map { #" \#($0.key)="\#(escape($0.value))""# }
            .joined()
        lines.append(indent + "<\(name)\(attributesText)>\(escape(value))</\(name)>")
    }

    func build() -> String {
        lines.joined(separator: "\n") + "\n"
    }

    private var indent: String {
        String(repeating: "  ", count: indentation)
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum CMUExporter {
    static func write(
        document: CMUAnalysisDocument,
        sidecarBaseURL: URL
    ) throws -> CMUOutputArtifacts {
        let baseURL = sidecarBaseURL.pathExtension.isEmpty
            ? sidecarBaseURL
            : sidecarBaseURL.deletingPathExtension()
        let xmlURL = baseURL.appendingPathExtension("cmu.xml")

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: xmlURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let xml = makeXML(document)
        guard let xmlData = xml.data(using: .utf8) else {
            throw CMUError.exportFailed("XML could not be encoded as UTF-8.")
        }
        try validateXML(xmlData, document: document)
        try xmlData.write(to: xmlURL, options: .atomic)

        return CMUOutputArtifacts(xmlURL: xmlURL)
    }

    private static func makeXML(_ document: CMUAnalysisDocument) -> String {
        let builder = CMUXMLBuilder()
        let primaries = document.media.primaries
        let aspectRatio = document.media.height > 0
            ? Double(document.media.width) / Double(document.media.height)
            : 0

        builder.declaration()
        builder.open(
            "DolbyLabsMDF",
            attributes: ["xmlns": "http://www.dolby.com/schemas/dvmd/5_1_0"]
        )
        builder.element("Version", document.schemaVersion)
        builder.open("RevisionHistory")
        builder.open("Revision")
        builder.element("DateTime", document.generatedAtUTC)
        builder.element("Author", document.author)
        builder.element("Software", document.software)
        builder.element("SoftwareVersion", document.softwareVersion)
        builder.close("Revision")
        builder.close("RevisionHistory")

        builder.open("Outputs")
        builder.open("Output")
        builder.element("CompositionName", document.media.fileName)
        builder.element("UniqueID", document.outputID.uuidString.lowercased())
        builder.element("NumberVideoTracks", "1")
        builder.element("CanvasAspectRatio", cmuFormatNumber(aspectRatio, digits: 5))
        builder.element("ImageAspectRatio", cmuFormatNumber(aspectRatio, digits: 5))
        builder.open("Video")
        builder.open("Track")
        builder.element("TrackName", "V1")
        builder.element("UniqueID", document.trackID.uuidString.lowercased())
        builder.element("EditRate", document.media.editRate.xmlValue)

        builder.open("ColorEncoding")
        writePrimaries(primaries, builder: builder)
        builder.element("WhitePoint", "0.3127 0.329")
        builder.element("PeakBrightness", "10000")
        builder.element("MinimumBrightness", "0")
        builder.element("Encoding", "pq")
        builder.element(
            "ColorSpace",
            document.media.matrix == "rgb" ? "rgb" : "ycbcr_bt2020"
        )
        builder.element("SignalRange", document.media.signalRange.xmlValue)
        builder.close("ColorEncoding")

        builder.open("Level6", attributes: ["level": "6"])
        builder.element("MaxCLL", "\(document.maxCLL)")
        builder.element("MaxFALL", "\(document.maxFALL)")
        builder.close("Level6")

        builder.open("PluginNode")
        builder.open("DVGlobalData", attributes: ["level": "0"])
        writeMasteringDisplay(document, builder: builder)
        writeTargetDisplays(builder)
        builder.close("DVGlobalData")
        builder.open("Level11", attributes: ["level": "11"])
        builder.element("ContentType", "0")
        builder.element("IntendedWhitePoint", "0")
        builder.close("Level11")
        builder.open("Level254", attributes: ["level": "254"])
        builder.element("DMMode", "0")
        builder.element("DMVersion", "2")
        builder.element("CMVersion", "4 1")
        builder.close("Level254")
        builder.close("PluginNode")

        builder.open("Shot")
        builder.element("UniqueID", document.shotID.uuidString.lowercased())
        builder.open("Record")
        // The encoder consumes MDF shots on a media-relative timeline.
        builder.element("In", "0")
        builder.element("Duration", "\(document.durationFrames)")
        builder.close("Record")
        builder.open("PluginNode")
        builder.open("DVDynamicData")
        builder.open("Level1", attributes: ["level": "1"])
        builder.element(
            "ImageCharacter",
            [
                cmuFormatNumber(Double(document.level1Like.min), digits: 8),
                cmuFormatNumber(Double(document.level1Like.mid), digits: 8),
                cmuFormatNumber(Double(document.level1Like.max), digits: 8)
            ].joined(separator: " ")
        )
        builder.close("Level1")
        builder.open("Level3", attributes: ["level": "3"])
        builder.element("L1Offset", "0 0 0")
        builder.close("Level3")
        builder.open("Level9", attributes: ["level": "9"])
        builder.element("SourceColorModel", "255")
        builder.element("SourceColorPrimary", primaries.primaryList)
        builder.close("Level9")
        builder.close("DVDynamicData")
        builder.close("PluginNode")
        builder.close("Shot")

        builder.close("Track")
        builder.close("Video")
        builder.close("Output")
        builder.close("Outputs")
        builder.close("DolbyLabsMDF")
        return builder.build()
    }

    private static func writePrimaries(
        _ primaries: CMUPrimaries,
        builder: CMUXMLBuilder
    ) {
        builder.open("Primaries")
        builder.element("Red", primaries.red)
        builder.element("Green", primaries.green)
        builder.element("Blue", primaries.blue)
        builder.close("Primaries")
    }

    private static func writeMasteringDisplay(
        _ document: CMUAnalysisDocument,
        builder: CMUXMLBuilder
    ) {
        let primaries = document.media.primaries
        let peak = cmuFormatNumber(Double(document.masteringPeakNits), digits: 3)
        builder.open("MasteringDisplay")
        builder.element("ID", "21")
        builder.element(
            "Name",
            "\(peak)-nit, \(primaries.displayName), D65, ST.2084, Full"
        )
        writePrimaries(primaries, builder: builder)
        builder.element("WhitePoint", "0.3127 0.329")
        builder.element("PeakBrightness", peak)
        builder.element("MinimumBrightness", "0.0001")
        builder.element("DiagonalSize", "42")
        builder.element("ApplicationType", "ALL")
        builder.close("MasteringDisplay")
    }

    private static func writeTargetDisplays(_ builder: CMUXMLBuilder) {
        writeTargetDisplay(
            id: 1,
            name: "100-nit, BT.709, BT.1886, Full (HOME)",
            red: "0.64 0.33",
            green: "0.3 0.6",
            blue: "0.15 0.06",
            peak: "100",
            minimum: "0.005",
            eotf: "gamma_bt1886",
            builder: builder
        )
        writeTargetDisplay(
            id: 28,
            name: "600-nit, BT.2020, ST.2084, Full (HOME)",
            red: "0.708 0.292",
            green: "0.17 0.797",
            blue: "0.131 0.046",
            peak: "600",
            minimum: "0",
            eotf: "pq",
            builder: builder
        )
        writeTargetDisplay(
            id: 49,
            name: "1000-nit, BT.2020, ST.2084, Full (HOME)",
            red: "0.708 0.292",
            green: "0.17 0.797",
            blue: "0.131 0.046",
            peak: "1000",
            minimum: "0",
            eotf: "pq",
            builder: builder
        )
    }

    private static func writeTargetDisplay(
        id: Int,
        name: String,
        red: String,
        green: String,
        blue: String,
        peak: String,
        minimum: String,
        eotf: String,
        builder: CMUXMLBuilder
    ) {
        builder.open("TargetDisplay")
        builder.element("ID", "\(id)")
        builder.element("Name", name)
        builder.open("Primaries")
        builder.element("Red", red)
        builder.element("Green", green)
        builder.element("Blue", blue)
        builder.close("Primaries")
        builder.element("WhitePoint", "0.3127 0.329")
        builder.element("PeakBrightness", peak)
        builder.element("MinimumBrightness", minimum)
        builder.element("EOTF", eotf)
        builder.element("DiagonalSize", "42")
        builder.element("ApplicationType", "HOME")
        builder.close("TargetDisplay")
    }

    private static func validateXML(
        _ data: Data,
        document: CMUAnalysisDocument
    ) throws {
        let xml = try XMLDocument(
            data: data,
            options: [.nodeLoadExternalEntitiesNever]
        )
        guard let root = xml.rootElement(),
              root.name == "DolbyLabsMDF",
              root.uri == "http://www.dolby.com/schemas/dvmd/5_1_0" else {
            throw CMUError.exportFailed("XML root or namespace is invalid.")
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("<Author>Dolby Laboratories</Author>") else {
            throw CMUError.exportFailed("XML Author is not the required Connect Mapping  Unit value.")
        }
        guard !text.contains("<Level2 "), !text.contains("<Level8 ") else {
            throw CMUError.exportFailed("XML unexpectedly contains Level 2 or Level 8 metadata.")
        }
        guard document.durationFrames > 0,
              document.recordOut >= document.recordIn,
              document.maxCLL >= document.maxFALL,
              document.level1Like.min.isFinite,
              document.level1Like.mid.isFinite,
              document.level1Like.max.isFinite else {
            throw CMUError.exportFailed("Computed CMU metadata failed validation.")
        }
    }
}

private func cmuFormatNumber(_ value: Double, digits: Int) -> String {
    guard value.isFinite else { return "0" }
    var text = String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    while text.contains("."), text.last == "0" {
        text.removeLast()
    }
    if text.last == "." {
        text.removeLast()
    }
    return text.isEmpty || text == "-0" ? "0" : text
}
