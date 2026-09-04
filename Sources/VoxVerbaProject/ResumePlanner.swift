import Foundation
import VoxVerbaCore

/// What resuming an interrupted job requires.
public enum ResumePlan: Sendable, Equatable {
    /// Nothing to do.
    case alreadyComplete
    /// The source file is gone or unreadable.
    case sourceMissing(path: String)
    /// The source changed; everything derived from it is invalid.
    case fullRebuild(reason: String)
    /// Restart from this stage. Everything before it is valid and reusable.
    case restart(from: StageKey)
    /// Transcription was interrupted; only these chunks remain.
    case resumeTranscription(chunks: [ChunkID])
    /// All chunks are done but the transcript was never written.
    case resumeMerge
}

/// The inputs each stage's validity depends on.
///
/// A stage is reusable only if its recorded hash still matches a hash computed
/// from its current inputs — which is what makes changing one silence parameter
/// invalidate the silence map and everything after it, while leaving the
/// expensive canonical decode alone.
public struct StageInputs: Sendable {
    public let sourceContentHash: String
    public let frameGeometryDescription: String
    public let silenceParameters: SilenceParameters
    public let chunkParameters: ChunkParameters
    public let engineID: EngineID
    public let locale: String
    /// Recorded because engine output is deterministic at a fixed concurrency but
    /// not across values, so resuming at a different setting can shift a word.
    public let concurrency: Int

    public init(
        sourceContentHash: String,
        frameGeometryDescription: String,
        silenceParameters: SilenceParameters,
        chunkParameters: ChunkParameters,
        engineID: EngineID,
        locale: String,
        concurrency: Int
    ) {
        self.sourceContentHash = sourceContentHash
        self.frameGeometryDescription = frameGeometryDescription
        self.silenceParameters = silenceParameters
        self.chunkParameters = chunkParameters
        self.engineID = engineID
        self.locale = locale
        self.concurrency = concurrency
    }

    /// The hash a stage must match to be considered still valid.
    ///
    /// Each stage folds in the previous one's hash, so invalidation cascades
    /// forward automatically and never backward.
    public func hash(for stage: StageKey) -> String {
        switch stage {
        case .decode:
            return ContentHash.string("decode|\(sourceContentHash)")
        case .analyze:
            return ContentHash.string("analyze|\(hash(for: .decode))|\(frameGeometryDescription)")
        case .silence:
            return ContentHash.string("silence|\(hash(for: .analyze))|\(describe(silenceParameters))")
        case .chunking:
            return ContentHash.string("chunking|\(hash(for: .silence))|\(describe(chunkParameters))")
        case .transcription:
            return ContentHash.string(
                "transcription|\(hash(for: .chunking))|\(engineID.rawValue)|\(locale)|\(concurrency)")
        case .merge:
            return ContentHash.string("merge|\(hash(for: .transcription))")
        case .clean:
            return ContentHash.string("clean|\(hash(for: .merge))")
        case .polish:
            return ContentHash.string("polish|\(hash(for: .clean))")
        }
    }

    /// A stable textual form, so the hash does not depend on `Hashable` seeding.
    ///
    /// Swift's `hashValue` is randomized per process, so using it here would
    /// invalidate every stage on every launch.
    private func describe(_ p: SilenceParameters) -> String {
        [p.marginDB, p.hysteresisDB, p.absoluteFloorDB].map { "\($0)" }.joined(separator: ",")
        + "|" + [p.minSpeechDuration, p.minSilenceDuration, p.padLead, p.padTrail,
                 p.paragraphPauseThreshold, p.sectionPauseThreshold]
            .map { "\($0.nanoseconds)" }.joined(separator: ",")
        + "|\(p.fricativeProtection)"
    }

    private func describe(_ p: ChunkParameters) -> String {
        [p.minDuration, p.maxDuration, p.targetDuration, p.overlapDuration, p.minBoundaryGap]
            .map { "\($0.nanoseconds)" }.joined(separator: ",")
    }
}

/// Decides where an interrupted or cancelled job picks up.
public struct ResumePlanner: Sendable {
    public init() {}

    public func plan(for project: Project, inputs: StageInputs) async throws -> ResumePlan {
        // 1. The source must still be there and still be the same file.
        let resolved: (url: URL, release: @Sendable () -> Void)
        do {
            resolved = try project.resolveSource()
        } catch {
            return .sourceMissing(path: project.manifest.source.displayName)
        }
        defer { resolved.release() }

        let currentHash = try ContentHash.file(at: resolved.url)
        guard currentHash == project.manifest.source.contentHash else {
            return .fullRebuild(reason: "the audio file has changed since it was imported")
        }

        // 2. Walk the stages in order. The first one whose artifacts are missing
        //    or whose inputs have changed is where work resumes.
        for stage in [StageKey.decode, .analyze, .silence, .chunking] {
            let recorded = try await project.store.stageHash(stage)
            guard recorded == inputs.hash(for: stage),
                  artifactsExist(for: stage, in: project.package)
            else {
                return .restart(from: stage)
            }
        }

        // 3. Transcription resumes per chunk rather than per stage.
        let recordedTranscription = try await project.store.stageHash(.transcription)
        if recordedTranscription != inputs.hash(for: .transcription) {
            return .restart(from: .transcription)
        }

        let records = try await project.store.loadChunkRecords()
        guard !records.isEmpty else { return .restart(from: .chunking) }

        let outstanding = records.filter { $0.state.isOutstanding }
        if !outstanding.isEmpty {
            return .resumeTranscription(chunks: outstanding.map(\.id))
        }

        // 4. Every chunk is accounted for; the transcript may still be missing.
        let mergeHash = try await project.store.stageHash(.merge)
        if mergeHash != inputs.hash(for: .merge)
            || !FileManager.default.fileExists(atPath: project.package.transcriptURL.path) {
            return .resumeMerge
        }

        return .alreadyComplete
    }

    /// Whether a stage's on-disk output is present.
    ///
    /// A recorded hash alone is not enough: the file could have been deleted by
    /// a cleanup, by the user, or by a failed disk. Both must agree.
    private func artifactsExist(for stage: StageKey, in package: ProjectPackage) -> Bool {
        let fm = FileManager.default
        switch stage {
        case .decode: return fm.fileExists(atPath: package.canonicalAudioURL.path)
        case .analyze: return fm.fileExists(atPath: package.framesURL.path)
        case .silence: return fm.fileExists(atPath: package.silenceMapURL.path)
        case .chunking: return fm.fileExists(atPath: package.chunkPlanURL.path)
        case .transcription, .merge: return fm.fileExists(atPath: package.transcriptURL.path)
        case .clean, .polish: return true
        }
    }
}
