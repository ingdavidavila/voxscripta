import Foundation
import VoxVerbaCore

/// The default engine: Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+).
///
/// Chosen over Whisper for English on this platform because published independent
/// benchmarks put it ahead on word error rate at roughly three times the speed,
/// its models are managed by the OS through `AssetInventory` (so they add nothing
/// to the app bundle and need no download UI), it emits `audioTimeRange` word
/// timings that the merger and the polish validator both depend on, and it runs
/// in a system process — so ASR model memory never appears in this app's footprint
/// and an engine crash cannot take down the app.
///
/// - Note: Phase 2 implements this over `SpeechAnalyzer.analyzeSequence(from:)`.
public struct AppleSpeechEngine: TranscriptionEngine {
    public let identifier = EngineID.appleSpeech

    public var capabilities: EngineCapabilities {
        EngineCapabilities(
            supportsWordTimestamps: true,
            supportsDiarization: false,
            supportsTranslation: false,
            // Populated at runtime from `SpeechTranscriber.supportedLocales`;
            // Phase 2 replaces this placeholder with the real query.
            supportedLocales: [],
            maximumChunkDuration: nil
        )
    }

    public init() {}

    public func prepare(locale: String) async throws {
        throw VoxVerbaError.notImplemented("AppleSpeechEngine.prepare — Phase 2")
    }

    public func transcribe(
        _ range: SampleRange,
        in canonicalFile: URL,
        options: TranscriptionOptions
    ) async throws -> [TranscriptSegment] {
        throw VoxVerbaError.notImplemented("AppleSpeechEngine.transcribe — Phase 2")
    }

    public func release() async {}
}
