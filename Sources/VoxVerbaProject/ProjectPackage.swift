import Foundation
import VoxVerbaCore

/// The on-disk layout of a `.voxverba` project.
///
/// A package directory rather than a database file, so it is user-inspectable,
/// Time Machine friendly, and recoverable by hand if the app ever fails.
public struct ProjectPackage: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let fileExtension = "voxverba"

    public var manifestURL: URL { root.appending(path: "manifest.json") }
    public var jobStoreURL: URL { root.appending(path: "job.sqlite") }

    /// The imported original. Never opened for writing, anywhere in the codebase.
    public var originalDirectory: URL { root.appending(path: "Original") }

    /// Derived audio and analysis. Safe to delete; regenerable from the original.
    public var derivedDirectory: URL { root.appending(path: "Derived") }
    public var canonicalAudioURL: URL {
        derivedDirectory.appending(path: "canonical.\(CanonicalFormat.fileExtension)")
    }
    public var framesURL: URL { derivedDirectory.appending(path: "frames.bin") }
    public var peaksURL: URL { derivedDirectory.appending(path: "peaks.bin") }
    public var silenceMapURL: URL { derivedDirectory.appending(path: "silence_map.json") }
    public var chunkPlanURL: URL { derivedDirectory.appending(path: "chunk_plan.json") }

    /// Per-chunk results, written atomically. Safe to delete after merge.
    public var chunksDirectory: URL {
        root.appending(path: "Transcription").appending(path: "chunks")
    }
    public func chunkResultURL(sequence: Int) -> URL {
        chunksDirectory.appending(path: String(format: "%04d.json", sequence))
    }

    /// Final outputs. Never touched by automated cleanup.
    public var outputDirectory: URL { root.appending(path: "Output") }
    public var transcriptURL: URL { outputDirectory.appending(path: "transcript.json") }
    public var cleanTranscriptURL: URL { outputDirectory.appending(path: "clean.json") }
    /// Where a rendered variant is written as plain text.
    public func textURL(for variant: TranscriptVariant) -> URL {
        outputDirectory.appending(path: "\(variant.rawValue).txt")
    }
    /// The audit trail for the CLEAN pass.
    public var cleanEditsURL: URL { outputDirectory.appending(path: "clean_edits.json") }
    public var polishedTranscriptURL: URL { outputDirectory.appending(path: "polished.json") }
    /// Per-sentence provenance for POLISHED: what changed, and what the validator said.
    public var polishReportURL: URL { outputDirectory.appending(path: "polish_report.json") }
    /// The optional silence-removed copy of the recording, and its time map.
    ///
    /// Lives in `Output/` rather than `Derived/` because a user asked for it and
    /// cleanup must not reclaim it.
    public var silenceRemovedAudioURL: URL {
        outputDirectory.appending(path: "silence-removed.wav")
    }
    public var silenceRemovalMapURL: URL {
        outputDirectory.appending(path: "silence-removed.json")
    }

    /// Why polish did not run, when it did not.
    ///
    /// Written so a missing polished transcript always has a stated reason on
    /// disk. A silently absent output is indistinguishable from a bug.
    public var polishSkippedURL: URL { outputDirectory.appending(path: "polish_skipped.txt") }

    /// Directories cleanup may remove once a job completes (§5).
    ///
    /// `Original`, `manifest.json` and `Output` are absent from this list on
    /// purpose, and no other code path deletes them.
    public var reclaimableDirectories: [URL] {
        [derivedDirectory, root.appending(path: "Transcription")]
    }
}

/// What a project records about itself, and the hashes resume validates against.
public struct ProjectManifest: Sendable, Codable {
    public let schemaVersion: Int
    public let projectID: ProjectID
    public let source: AudioSource
    public var silenceParameters: SilenceParameters
    public var chunkParameters: ChunkParameters
    public var engineID: EngineID
    /// Transcription locale, stored so reopening uses what the project was built with.
    public var locale: String
    /// Chunks transcribed at once when this project was built.
    ///
    /// Stored for the same reason as the silence and chunk parameters: it is part
    /// of the transcription stage's input hash, so a project reopened at a
    /// different value would re-transcribe. Engine output is not reproducible
    /// across concurrency settings, so that invalidation is correct — which makes
    /// remembering the original value the only way to avoid it.
    public var concurrency: Int
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        schemaVersion: Int = VoxVerba.projectSchemaVersion,
        projectID: ProjectID = ProjectID(),
        source: AudioSource,
        silenceParameters: SilenceParameters = .default,
        chunkParameters: ChunkParameters = .default,
        engineID: EngineID = .appleSpeech,
        locale: String = "en-US",
        concurrency: Int = 4,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.source = source
        self.silenceParameters = silenceParameters
        self.chunkParameters = chunkParameters
        self.engineID = engineID
        self.locale = locale
        self.concurrency = concurrency
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
