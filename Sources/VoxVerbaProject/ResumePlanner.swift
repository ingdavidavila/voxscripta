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
    /// Transcription and merge are done; only the language passes remain.
    case resumeLanguagePasses
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

        // 2. Is the job already finished?
        //
        //    Checked before anything looks at derived data, because derived data
        //    is reclaimable. Cleanup deletes canonical.f32 and the chunk results
        //    on purpose, and a planner that walked the stages first would see the
        //    decode missing and re-run the entire pipeline on a project that was
        //    complete — turning a storage saving into a full re-transcription.
        //
        //    The stage hashes live in the database, which cleanup never touches,
        //    so a finished project can still prove it is finished.
        if try await isComplete(project, inputs: inputs) {
            return .alreadyComplete
        }

        // 3. Walk the stages in order. The first one whose artifacts are missing
        //    or whose inputs have changed is where work resumes.
        for stage in [StageKey.decode, .analyze, .silence, .chunking] {
            let recorded = try await project.store.stageHash(stage)
            guard recorded == inputs.hash(for: stage),
                  artifactsExist(for: stage, in: project.package)
            else {
                return .restart(from: stage)
            }
        }

        // 4. Transcription resumes per chunk rather than per stage.
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

        // 5. Every chunk is accounted for; the transcript may still be missing.
        let mergeHash = try await project.store.stageHash(.merge)
        if mergeHash != inputs.hash(for: .merge)
            || !FileManager.default.fileExists(atPath: project.package.transcriptURL.path) {
            return .resumeMerge
        }

        // 5. The verbatim transcript exists, but the deterministic CLEAN pass may
        //    not have run — a crash between the two leaves exactly that state.
        let cleanHash = try await project.store.stageHash(.clean)
        if cleanHash != inputs.hash(for: .clean)
            || !FileManager.default.fileExists(atPath: project.package.cleanTranscriptURL.path) {
            return .restart(from: .clean)
        }

        // 6. Polish is optional, so "absent" is not automatically "unfinished".
        //    A recorded skip reason means the stage ran and declined — the model
        //    was unavailable — and the job is genuinely complete. No hash, no
        //    output and no reason means it never ran, which a crash between clean
        //    and polish produces exactly.
        let polishHash = try await project.store.stageHash(.polish)
        let hasPolish = FileManager.default.fileExists(
            atPath: project.package.polishedTranscriptURL.path)
        let declined = FileManager.default.fileExists(
            atPath: project.package.polishSkippedURL.path)

        if !declined, polishHash != inputs.hash(for: .polish) || !hasPolish {
            return .restart(from: .polish)
        }

        return .alreadyComplete
    }

    /// Whether every output the pipeline promises is present and current.
    ///
    /// Deliberately looks only at `Output/` and the recorded hashes, never at
    /// `Derived/`. Those two directories differ in kind: one is the result, the
    /// other is scratch work that exists to be thrown away.
    private func isComplete(_ project: Project, inputs: StageInputs) async throws -> Bool {
        let fm = FileManager.default
        let package = project.package

        guard fm.fileExists(atPath: package.transcriptURL.path),
              try await project.store.stageHash(.merge) == inputs.hash(for: .merge),
              fm.fileExists(atPath: package.cleanTranscriptURL.path),
              try await project.store.stageHash(.clean) == inputs.hash(for: .clean)
        else { return false }

        // Polish may legitimately be absent when the model declined, which the
        // skip marker records.
        if fm.fileExists(atPath: package.polishSkippedURL.path) { return true }
        guard fm.fileExists(atPath: package.polishedTranscriptURL.path) else { return false }
        let polishHash = try await project.store.stageHash(.polish)
        return polishHash == inputs.hash(for: .polish)
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
        case .clean: return fm.fileExists(atPath: package.cleanTranscriptURL.path)
        case .polish:
            return fm.fileExists(atPath: package.polishedTranscriptURL.path)
                || fm.fileExists(atPath: package.polishSkippedURL.path)
        }
    }
}
