import Foundation

/// A type-safe identifier backed by a UUID.
///
/// The phantom `Tag` prevents a `ChunkID` from being passed where a `SegmentID`
/// is expected — a mistake that is otherwise easy to make and hard to see in a
/// pipeline where nearly every function takes an identifier.
public struct TaggedID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// A short, stable, log-friendly prefix. Not unique — for human reading only.
    public var short: String { String(rawValue.uuidString.prefix(8)) }
    public var description: String { rawValue.uuidString }
}

public enum ProjectTag: Sendable {}
public enum SourceTag: Sendable {}
public enum JobTag: Sendable {}
public enum ChunkTag: Sendable {}
public enum SegmentTag: Sendable {}
public enum SpeakerTag: Sendable {}

public typealias ProjectID = TaggedID<ProjectTag>
public typealias SourceID = TaggedID<SourceTag>
public typealias JobID = TaggedID<JobTag>
public typealias ChunkID = TaggedID<ChunkTag>
public typealias SegmentID = TaggedID<SegmentTag>
public typealias SpeakerID = TaggedID<SpeakerTag>

/// Identifies a transcription engine implementation.
public struct EngineID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// Apple's `SpeechAnalyzer` / `SpeechTranscriber`, the default engine.
    public static let appleSpeech = EngineID(rawValue: "apple.speech-transcriber")
    /// WhisperKit running a CoreML Whisper model — the multilingual alternate.
    public static let whisperKit = EngineID(rawValue: "argmax.whisperkit")
    /// whisper.cpp, built from source and linked in. The portable recogniser
    /// for every platform Apple's does not reach.
    public static let whisper = EngineID(rawValue: "whisper.cpp")
    /// Deterministic engine used by tests. Never ships in a release build.
    public static let mock = EngineID(rawValue: "voxscripta.mock")
}

/// Identifies a language model backend and the specific weights it loaded.
public struct ModelID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let backend: String
    public let identifier: String

    public init(backend: String, identifier: String) {
        self.backend = backend
        self.identifier = identifier
    }

    public var description: String { "\(backend):\(identifier)" }

    /// Apple's on-device system model via the Foundation Models framework.
    public static let systemDefault = ModelID(backend: "foundation-models", identifier: "system.default")
}
