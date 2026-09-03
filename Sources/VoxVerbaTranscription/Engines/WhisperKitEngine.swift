import Foundation
import VoxVerbaCore

/// The multilingual alternate engine: WhisperKit running a CoreML Whisper model.
///
/// Kept alongside the Apple engine for two reasons that will not go away. Apple
/// covers roughly 30 locales against Whisper's 100-plus, so some recordings are
/// simply not transcribable by the default engine. And an OS-versioned model
/// cannot give cross-machine reproducibility, which the benchmark suite needs.
///
/// - Note: Phase 2 or 2.1 implements this. Adding it introduces the WhisperKit
///   package dependency and a model-download path, both of which are deliberately
///   absent from Phase 0.
public struct WhisperKitEngine: TranscriptionEngine {
    public let identifier = EngineID.whisperKit

    public var capabilities: EngineCapabilities {
        EngineCapabilities(
            supportsWordTimestamps: true,
            supportsDiarization: false,
            supportsTranslation: true,
            supportedLocales: [],
            maximumChunkDuration: nil
        )
    }

    public init() {}

    public func prepare(locale: String) async throws {
        throw VoxVerbaError.notImplemented("WhisperKitEngine.prepare — Phase 2")
    }

    public func transcribe(
        _ range: SampleRange,
        in canonicalFile: URL,
        options: TranscriptionOptions
    ) async throws -> [TranscriptSegment] {
        throw VoxVerbaError.notImplemented("WhisperKitEngine.transcribe — Phase 2")
    }

    public func release() async {}
}
