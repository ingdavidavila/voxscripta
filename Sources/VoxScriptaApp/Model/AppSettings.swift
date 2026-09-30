import Foundation
import VoxScriptaCore
import VoxScriptaTranscription
import VoxScriptaLanguage
import VoxScriptaPipeline
import VoxScriptaProject

/// User-facing settings (§29), persisted between launches.
///
/// Kept flat and `Codable` so the whole thing round-trips through one defaults
/// key. Every value here also participates in the pipeline's stage hashes, so
/// changing one invalidates exactly the work that depended on it.
struct AppSettings: Codable, Sendable, Equatable {
    // Audio
    var silenceMarginDB: Float = SilenceParameters.default.marginDB
    var minimumSilenceSeconds: Double = SilenceParameters.default.minSilenceDuration.seconds
    var padLeadSeconds: Double = SilenceParameters.default.padLead.seconds
    var padTrailSeconds: Double = SilenceParameters.default.padTrail.seconds
    var maximumChunkSeconds: Double = ChunkParameters.default.maxDuration.seconds

    // Transcription
    var locale: String = "en-US"
    var concurrency: Int = TranscriptionOptions.default.concurrency

    // Language
    var removeFillers: Bool = true
    var collapseRepetitions: Bool = true
    var polishEnabled: Bool = true
    /// Which language model polishes.
    ///
    /// Automatic prefers Apple's system model and falls back to the bundled one,
    /// which is what lets POLISHED be promised on any Mac.
    var polishBackend: PolishBackendPreference = .automatic

    // Output and storage
    var defaultVariant: TranscriptVariant = .clean
    var copyOriginalIntoProject: Bool = false
    /// Keep scratch audio after a job finishes.
    ///
    /// Off by default, per §5. For a six-hour recording the intermediates are
    /// about 1.4 GB per project, and the transcripts do not need them.
    var keepIntermediateFiles: Bool = false

    var silenceParameters: SilenceParameters {
        var p = SilenceParameters.default
        p.marginDB = silenceMarginDB
        p.minSilenceDuration = .seconds(minimumSilenceSeconds)
        p.padLead = .seconds(padLeadSeconds)
        p.padTrail = .seconds(padTrailSeconds)
        return p
    }

    var chunkParameters: ChunkParameters {
        var p = ChunkParameters.default
        p.maxDuration = .seconds(maximumChunkSeconds)
        p.targetDuration = .seconds(maximumChunkSeconds * 0.8)
        p.minDuration = .seconds(maximumChunkSeconds * 0.4)
        return p
    }

    var cleanParameters: CleanParameters {
        var p = CleanParameters.default
        p.removeFillers = removeFillers
        p.collapseRepetitions = collapseRepetitions
        return p
    }

    var polishParameters: PolishParameters { .default }

    // MARK: - Persistence

    private static let key = "com.voxscripta.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
