import Foundation
import VoxVerbaCore

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
///
/// - Note: Phase 8 implements these. DOCX is written as OOXML directly rather than
///   through a document toolkit — a `.docx` is a zip of XML, and doing it by hand
///   is a few hundred lines against one small zip dependency.
public protocol Exporting: Sendable {
    var format: ExportFormat { get }
    func export(_ transcript: Transcript, options: ExportOptions) throws -> Data
}

/// Phase 8 implementation site.
public struct PlainTextExporter: Exporting {
    public let format = ExportFormat.plainText
    public init() {}
    public func export(_ transcript: Transcript, options: ExportOptions) throws -> Data {
        throw VoxVerbaError.notImplemented("PlainTextExporter.export — Phase 8")
    }
}

/// Phase 8 implementation site.
public struct SubRipExporter: Exporting {
    public let format = ExportFormat.subRip
    public init() {}
    public func export(_ transcript: Transcript, options: ExportOptions) throws -> Data {
        throw VoxVerbaError.notImplemented("SubRipExporter.export — Phase 8")
    }
}
