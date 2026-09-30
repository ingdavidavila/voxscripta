import Foundation
import VoxScriptaCore

/// Output formats (§32). Each variant exports independently.
public enum ExportFormat: String, Sendable, Codable, CaseIterable {
    case plainText
    case markdown
    case docx
    case subRip
    case webVTT

    public var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .markdown: "md"
        case .docx: "docx"
        case .subRip: "srt"
        case .webVTT: "vtt"
        }
    }

    /// Looks a format up by its file extension, for command-line selection.
    public init?(extension name: String) {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard let match = ExportFormat.allCases.first(where: { $0.fileExtension == key })
        else { return nil }
        self = match
    }

    /// Whether the format carries timing. Subtitle formats require word or segment
    /// timestamps; document formats can include them optionally.
    public var isTimed: Bool {
        switch self {
        case .subRip, .webVTT: true
        case .plainText, .markdown, .docx: false
        }
    }
}

public struct ExportOptions: Hashable, Sendable {
    public var includeTimestamps: Bool
    public var includeSpeakerLabels: Bool
    /// Maximum characters per subtitle cue.
    public var maximumCueLength: Int

    public init(
        includeTimestamps: Bool = false,
        includeSpeakerLabels: Bool = false,
        maximumCueLength: Int = 84
    ) {
        self.includeTimestamps = includeTimestamps
        self.includeSpeakerLabels = includeSpeakerLabels
        self.maximumCueLength = maximumCueLength
    }

    public static let `default` = ExportOptions()
}

/// Writes a transcript in one format.
public protocol Exporting: Sendable {
    var format: ExportFormat { get }
    func export(_ transcript: Transcript, options: ExportOptions) throws -> Data
}

public extension Exporting {
    /// A sensible filename for a transcript of this variant.
    func filename(base: String, variant: TranscriptVariant) -> String {
        "\(base) — \(variant.rawValue).\(format.fileExtension)"
    }
}

/// Every exporter, keyed by format.
public enum Exporters {
    public static func make(_ format: ExportFormat) -> any Exporting {
        switch format {
        case .plainText: PlainTextExporter()
        case .markdown: MarkdownExporter()
        case .docx: DOCXExporter()
        case .subRip: SubRipExporter()
        case .webVTT: WebVTTExporter()
        }
    }

    /// Formats that can represent `transcript` faithfully.
    ///
    /// Subtitle formats need timing. The polished variant drops word timings
    /// because its text no longer matches the spoken words, but segment spans
    /// survive, so it can still be captioned — just less finely.
    public static func available(for transcript: Transcript) -> [ExportFormat] {
        let timed = transcript.segments.contains { $0.originalEnd > $0.originalStart }
        return ExportFormat.allCases.filter { !$0.isTimed || timed }
    }
}

// MARK: - Plain text

public struct PlainTextExporter: Exporting {
    public let format = ExportFormat.plainText
    public init() {}

    public func export(_ transcript: Transcript, options: ExportOptions = .default) throws -> Data {
        var lines: [String] = []
        for (index, segment) in transcript.segments.enumerated() {
            guard !segment.text.isEmpty || segment.warnings.contains(.transcriptionGap) else { continue }
            var line = ""
            if options.includeTimestamps {
                line += "[\(segment.originalStart)] "
            }
            if options.includeSpeakerLabels, let speaker = segment.speaker {
                line += "Speaker \(speaker.short): "
            }
            // A gap is shown rather than silently closed up, so a reader knows
            // where the recording could not be transcribed.
            line += segment.warnings.contains(.transcriptionGap)
                ? "[untranscribed: \(segment.originalStart) – \(segment.originalEnd)]"
                : segment.text

            let breaksParagraph = index > 0
                && (segment.precedingGap ?? .zero) >= SilenceParameters.default.paragraphPauseThreshold
            if breaksParagraph || options.includeTimestamps || options.includeSpeakerLabels {
                lines.append(breaksParagraph && !lines.isEmpty ? "\n" + line : line)
            } else if var last = lines.popLast() {
                last += " " + line
                lines.append(last)
            } else {
                lines.append(line)
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}

// MARK: - Markdown

public struct MarkdownExporter: Exporting {
    public let format = ExportFormat.markdown
    public init() {}

    public func export(_ transcript: Transcript, options: ExportOptions = .default) throws -> Data {
        var out = ""
        out += "# Transcript\n\n"
        out += "*\(transcript.variant.rawValue.capitalized)"
        if let range = transcript.timeRange {
            out += " · \(range.duration)"
        }
        out += " · \(transcript.wordCount) words*\n\n"

        let body = try PlainTextExporter().export(transcript, options: options)
        // Escaped so a transcript containing Markdown syntax reads as text.
        out += escape(String(decoding: body, as: UTF8.self))
        out += "\n"
        return Data(out.utf8)
    }

    /// Escapes the characters that would otherwise be read as formatting.
    private func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if "*_`#[]<>".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

// MARK: - Subtitles

public struct SubRipExporter: Exporting {
    public let format = ExportFormat.subRip
    public let builder: CueBuilder

    public init(builder: CueBuilder = .default) { self.builder = builder }

    public func export(_ transcript: Transcript, options: ExportOptions = .default) throws -> Data {
        let cues = builder.cues(from: transcript)
        guard !cues.isEmpty else {
            throw VoxScriptaError.analysisFailed(stage: "export",
                                               reason: "this transcript has no timed content")
        }
        var out = ""
        for cue in cues {
            out += "\(cue.index)\n"
            out += "\(Timecode.subRip(cue.range.start)) --> \(Timecode.subRip(cue.range.end))\n"
            if options.includeSpeakerLabels, let speaker = cue.speaker {
                out += "Speaker \(speaker.short): "
            }
            out += cue.lines.joined(separator: "\n")
            out += "\n\n"
        }
        return Data(out.utf8)
    }
}

public struct WebVTTExporter: Exporting {
    public let format = ExportFormat.webVTT
    public let builder: CueBuilder

    public init(builder: CueBuilder = .default) { self.builder = builder }

    public func export(_ transcript: Transcript, options: ExportOptions = .default) throws -> Data {
        let cues = builder.cues(from: transcript)
        guard !cues.isEmpty else {
            throw VoxScriptaError.analysisFailed(stage: "export",
                                               reason: "this transcript has no timed content")
        }
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(cue.index)\n"
            out += "\(Timecode.webVTT(cue.range.start)) --> \(Timecode.webVTT(cue.range.end))\n"
            if options.includeSpeakerLabels, let speaker = cue.speaker {
                // VTT's own speaker markup, which players can style.
                out += "<v Speaker \(speaker.short)>"
            }
            out += cue.lines.joined(separator: "\n")
            out += "\n\n"
        }
        return Data(out.utf8)
    }
}

// MARK: - DOCX

/// Writes Office Open XML directly.
///
/// A `.docx` is a zip of XML. Doing it by hand is a few hundred lines against a
/// small in-tree zip writer, which beats importing a document toolkit to produce
/// paragraphs of plain text.
public struct DOCXExporter: Exporting {
    public let format = ExportFormat.docx
    public init() {}

    public func export(_ transcript: Transcript, options: ExportOptions = .default) throws -> Data {
        var zip = ZIPWriter()
        zip.add(Data(Self.contentTypes.utf8), at: "[Content_Types].xml")
        zip.add(Data(Self.rootRelationships.utf8), at: "_rels/.rels")
        zip.add(Data(Self.documentRelationships.utf8), at: "word/_rels/document.xml.rels")
        zip.add(Data(Self.styles.utf8), at: "word/styles.xml")
        zip.add(Data(body(for: transcript, options: options).utf8), at: "word/document.xml")
        return zip.finalize()
    }

    private func body(for transcript: Transcript, options: ExportOptions) -> String {
        var paragraphs: [String] = []
        paragraphs.append(Self.paragraph("Transcript", style: "Title"))
        paragraphs.append(Self.paragraph(
            "\(transcript.variant.rawValue.capitalized) · \(transcript.wordCount) words",
            style: "Subtitle"))

        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            paragraphs.append(Self.paragraph(current.joined(separator: " ")))
            current = []
        }

        for (index, segment) in transcript.segments.enumerated() {
            if segment.warnings.contains(.transcriptionGap) {
                flush()
                paragraphs.append(Self.paragraph(
                    "[untranscribed: \(segment.originalStart) – \(segment.originalEnd)]",
                    style: "Quote"))
                continue
            }
            guard !segment.text.isEmpty else { continue }

            let breaksParagraph = index > 0
                && (segment.precedingGap ?? .zero) >= SilenceParameters.default.paragraphPauseThreshold
            if breaksParagraph { flush() }

            var text = segment.text
            if options.includeTimestamps { text = "[\(segment.originalStart)] " + text }
            if options.includeSpeakerLabels, let speaker = segment.speaker {
                text = "Speaker \(speaker.short): " + text
            }
            current.append(text)
        }
        flush()

        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>\(paragraphs.joined())<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
            </w:body></w:document>
            """
    }

    private static func paragraph(_ text: String, style: String? = nil) -> String {
        let properties = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        // xml:space preserve, or Word collapses the spacing a transcript needs.
        return "<w:p>\(properties)<w:r><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r></w:p>"
    }

    /// Escapes XML, and strips control characters Word rejects outright.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // Word refuses a document containing raw control characters.
                if let scalar = character.unicodeScalars.first,
                   scalar.value < 0x20, character != "\n", character != "\t" { continue }
                out.append(character)
            }
        }
        return out
    }

    // MARK: Container parts

    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """

    private static let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

    private static let documentRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """

    private static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/>
        <w:rPr><w:sz w:val="48"/><w:b/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/>
        <w:rPr><w:sz w:val="22"/><w:i/><w:color w:val="666666"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/>
        <w:rPr><w:i/><w:color w:val="888888"/></w:rPr></w:style>
        </w:styles>
        """
}
