import Foundation
import VoxVerbaCore

/// What an engine can do. The scheduler consults this instead of special-casing
/// engine identities, so adding Parakeet in V2 changes no scheduling code.
public struct EngineCapabilities: Hashable, Sendable {
    public let supportsWordTimestamps: Bool
    public let supportsDiarization: Bool
    public let supportsTranslation: Bool
    /// Locales the engine can transcribe. Apple covers roughly 30; Whisper 100+.
    public let supportedLocales: Set<String>
    /// Longest span the engine accepts in one call, or `nil` for no limit.
    public let maximumChunkDuration: MediaTime?

    public init(
        supportsWordTimestamps: Bool,
        supportsDiarization: Bool = false,
        supportsTranslation: Bool = false,
        supportedLocales: Set<String>,
        maximumChunkDuration: MediaTime? = nil
    ) {
        self.supportsWordTimestamps = supportsWordTimestamps
        self.supportsDiarization = supportsDiarization
        self.supportsTranslation = supportsTranslation
        self.supportedLocales = supportedLocales
        self.maximumChunkDuration = maximumChunkDuration
    }
}

/// Per-run transcription settings (§29).
public struct TranscriptionOptions: Hashable, Sendable {
    public var locale: String
    public var requestWordTimestamps: Bool
    /// Translate to English rather than transcribing in-language, where supported.
    public var translate: Bool
    /// How many chunks may be in flight at once.
    ///
    /// Defaults to 1. Neural Engine inference is a serialized hardware resource,
    /// so concurrency above 1 often produces contention rather than throughput
    /// while multiplying peak memory. Phase 2's benchmark harness sets the real
    /// default from measurement rather than assumption (§21).
    public var concurrency: Int
    public var maxAttemptsPerChunk: Int

    public init(
        locale: String = "en-US",
        requestWordTimestamps: Bool = true,
        translate: Bool = false,
        concurrency: Int = 1,
        maxAttemptsPerChunk: Int = 3
    ) {
        self.locale = locale
        self.requestWordTimestamps = requestWordTimestamps
        self.translate = translate
        self.concurrency = Swift.max(1, concurrency)
        self.maxAttemptsPerChunk = Swift.max(1, maxAttemptsPerChunk)
    }

    public static let `default` = TranscriptionOptions()
}

/// One chunk's result, before merging.
public struct ChunkTranscript: Sendable, Codable {
    public let chunkID: ChunkID
    public let sequence: Int
    public let segments: [TranscriptSegment]
    public let engineID: EngineID
    /// Wall-clock time the engine took, recorded for the benchmark harness.
    public let processingDuration: TimeInterval

    public init(
        chunkID: ChunkID,
        sequence: Int,
        segments: [TranscriptSegment],
        engineID: EngineID,
        processingDuration: TimeInterval
    ) {
        self.chunkID = chunkID
        self.sequence = sequence
        self.segments = segments
        self.engineID = engineID
        self.processingDuration = processingDuration
    }
}

/// A local speech-to-text engine.
///
/// The scheduler talks only to this protocol. `SpeechTranscriber` is the default
/// implementation and WhisperKit the multilingual alternate; adding Parakeet for
/// diarization in V2 means writing one conforming type and nothing else.
///
/// - Important: Every implementation must be fully local. There is no code path
///   in VoxVerba that sends audio off the machine, and the app ships without the
///   network entitlement so the sandbox enforces it (§26).
public protocol TranscriptionEngine: Sendable {
    var identifier: EngineID { get }
    var capabilities: EngineCapabilities { get }

    /// Loads models and downloads OS-managed assets if needed.
    func prepare(locale: String) async throws

    /// Transcribes one span of the canonical audio file.
    func transcribe(
        _ range: SampleRange,
        in canonicalFile: URL,
        options: TranscriptionOptions
    ) async throws -> [TranscriptSegment]

    /// Releases model resources. Called before the language phase loads its own.
    func release() async
}
