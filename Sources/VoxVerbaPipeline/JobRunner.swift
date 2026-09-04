import Foundation
import VoxVerbaCore
import VoxVerbaDSP
import VoxVerbaTranscription
import VoxVerbaProject

/// A point at which the runner will deliberately kill the process.
///
/// A test affordance, not a feature. Crash recovery cannot be verified by
/// throwing an error — that unwinds cleanly and runs `defer` blocks, which is
/// precisely the case that already works. Only a real `SIGKILL` proves that what
/// reached the disk before the crash is enough to resume from.
public struct CrashPoint: Sendable, Equatable {
    public enum When: String, Sendable { case before, after }
    public let stage: StageKey
    public let when: When
    /// For the transcription stage: crash after this many chunks have committed.
    public let afterChunks: Int?

    public init(stage: StageKey, when: When = .after, afterChunks: Int? = nil) {
        self.stage = stage
        self.when = when
        self.afterChunks = afterChunks
    }
}

/// How a job should run.
public struct JobOptions: Sendable {
    public var transcription: TranscriptionOptions
    public var geometry: FrameGeometry
    /// Test-only fault injection.
    public var crashPoint: CrashPoint?

    public init(
        transcription: TranscriptionOptions = .default,
        geometry: FrameGeometry = .default,
        crashPoint: CrashPoint? = nil
    ) {
        self.transcription = transcription
        self.geometry = geometry
        self.crashPoint = crashPoint
    }
}

/// Progress across the whole pipeline.
public struct JobProgressReport: Sendable {
    public let state: JobState
    public let fraction: Double
    public let detail: String
}

/// Runs a project's pipeline, persisting after every stage so it can resume.
///
/// The runner owns the state machine. Each stage does its work, commits its
/// artifact atomically, records its input hash, and only then advances the job
/// state — so a crash at any instant leaves the project at a boundary the resume
/// planner can reason about.
public struct JobRunner: Sendable {
    private let engineFactory: @Sendable () -> any TranscriptionEngine

    public init(engineFactory: @escaping @Sendable () -> any TranscriptionEngine = { AppleSpeechEngine() }) {
        self.engineFactory = engineFactory
    }

    public func run(
        project: Project,
        options: JobOptions = JobOptions(),
        progress: @escaping @Sendable (JobProgressReport) -> Void = { _ in }
    ) async throws -> Transcript {
        let package = project.package
        let (sourceURL, release) = try project.resolveSource()
        defer { release() }

        let inputs = StageInputs(
            sourceContentHash: project.manifest.source.contentHash,
            frameGeometryDescription: "\(options.geometry.windowDuration.nanoseconds)"
                + ",\(options.geometry.hopDuration.nanoseconds),\(options.geometry.sampleRate)",
            silenceParameters: project.manifest.silenceParameters,
            chunkParameters: project.manifest.chunkParameters,
            engineID: project.manifest.engineID,
            locale: options.transcription.locale,
            concurrency: options.transcription.concurrency)

        let plan = try await ResumePlanner().plan(for: project, inputs: inputs)

        switch plan {
        case .sourceMissing(let path):
            throw VoxVerbaError.sourceUnavailable(path: path)
        case .alreadyComplete:
            return try AtomicFile.readJSON(Transcript.self, from: package.transcriptURL)
        default:
            break
        }

        let startStage: StageKey
        var resumeChunks: Set<ChunkID>?
        switch plan {
        case .fullRebuild: startStage = .decode
        case .restart(let stage): startStage = stage
        case .resumeTranscription(let chunks):
            startStage = .transcription
            resumeChunks = Set(chunks)
        case .resumeMerge: startStage = .merge
        default: startStage = .decode
        }

        // Anything from the resume point onward is stale by definition.
        try await project.store.clearStageHashes(from: startStage)

        // ── Decode ──────────────────────────────────────────────────────────
        if startStage <= .decode {
            try await advance(project, .analyzing, progress, 0.0, "Decoding audio")
            try crashIfRequested(options, .decode, .before)
            _ = try await CanonicalDecoder().decode(url: sourceURL, to: package.canonicalAudioURL) { p in
                progress(JobProgressReport(state: .analyzing, fraction: p * 0.05, detail: "Decoding audio"))
            }
            try await project.store.setStageHash(.decode, to: inputs.hash(for: .decode))
            try crashIfRequested(options, .decode, .after)
        }

        // ── Analyze ─────────────────────────────────────────────────────────
        var features: FrameFeatures
        if startStage <= .analyze {
            try await advance(project, .analyzing, progress, 0.05, "Measuring audio")
            features = try await FrameAnalyzer().analyze(
                canonicalFile: package.canonicalAudioURL, geometry: options.geometry) { p in
                progress(JobProgressReport(state: .analyzing,
                                           fraction: 0.05 + p * 0.05, detail: "Measuring audio"))
            }
            try AtomicFile.write(features.serialized(), to: package.framesURL)
            try await project.store.setStageHash(.analyze, to: inputs.hash(for: .analyze))
            try crashIfRequested(options, .analyze, .after)
        } else {
            features = try FrameFeatures.deserialized(from: try Data(contentsOf: package.framesURL))
        }

        let duration = features.duration

        // ── Silence ─────────────────────────────────────────────────────────
        var silenceMap: SilenceMap
        if startStage <= .silence {
            try await advance(project, .silenceProcessing, progress, 0.10, "Detecting silence")
            silenceMap = try SilenceDetector().detect(
                features: features, parameters: project.manifest.silenceParameters,
                sourceDuration: duration, parameterHash: inputs.hash(for: .silence))
            try AtomicFile.writeJSON(silenceMap, to: package.silenceMapURL)
            try await project.store.setStageHash(.silence, to: inputs.hash(for: .silence))
            try crashIfRequested(options, .silence, .after)
        } else {
            silenceMap = try AtomicFile.readJSON(SilenceMap.self, from: package.silenceMapURL)
        }

        // ── Chunking ────────────────────────────────────────────────────────
        var chunkPlan: ChunkPlan
        if startStage <= .chunking {
            try await advance(project, .chunking, progress, 0.11, "Planning chunks")
            chunkPlan = try ChunkPlanner().plan(
                silenceMap: silenceMap, parameters: project.manifest.chunkParameters,
                parameterHash: inputs.hash(for: .chunking))
            try AtomicFile.writeJSON(chunkPlan, to: package.chunkPlanURL)
            try await project.store.replaceChunkRecords(
                chunkPlan.chunks.map { ChunkRecord(id: $0.id, sequence: $0.sequence) })
            try await project.store.setStageHash(.chunking, to: inputs.hash(for: .chunking))
            try crashIfRequested(options, .chunking, .after)
        } else {
            chunkPlan = try AtomicFile.readJSON(ChunkPlan.self, from: package.chunkPlanURL)
        }

        // ── Transcription ───────────────────────────────────────────────────
        try await advance(project, .transcribing, progress, 0.12, "Transcribing")
        let engine = engineFactory()
        try await engine.prepare(locale: options.transcription.locale)
        defer { Task { await engine.release() } }

        // Chunks already committed on a previous run are skipped, and their
        // results are read back from disk rather than recomputed.
        let records = try await project.store.loadChunkRecords()
        let completed = Set(records.filter { $0.state == .completed }.map(\.id))
        let skipped = Set(records.filter { $0.state == .failedPermanent || $0.state == .skipped }.map(\.id))
        let alreadyHandled = completed.union(skipped)

        var results: [ChunkTranscript] = []
        for record in records where record.state == .completed {
            let url = package.chunkResultURL(sequence: record.sequence)
            if let loaded = try? AtomicFile.readJSON(ChunkTranscript.self, from: url) {
                results.append(loaded)
            }
        }

        if resumeChunks != nil || !alreadyHandled.isEmpty || startStage <= .transcription {
            let total = chunkPlan.count
            let committedCount = Counter()

            let outcome = try await ChunkScheduler().run(
                plan: chunkPlan, canonicalFile: package.canonicalAudioURL,
                engine: engine, options: options.transcription,
                skipping: alreadyHandled,
                onChunkComplete: { transcript in
                    // The result file lands before the row, so a crash between
                    // them re-runs a chunk rather than losing one.
                    let sequence = transcript.sequence
                    let url = package.chunkResultURL(sequence: sequence)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(transcript)
                    var record = ChunkRecord(id: transcript.chunkID, sequence: sequence,
                                             state: .completed, attempts: 1)
                    record.completedAt = Date()
                    record.processingDuration = transcript.processingDuration
                    try await project.store.commitChunkResult(record, resultData: data, to: url)

                    let n = await committedCount.increment()
                    if let crash = options.crashPoint, crash.stage == .transcription,
                       let after = crash.afterChunks, n >= after {
                        Self.die("transcription after \(n) chunks")
                    }
                },
                progress: { done, _ in
                    progress(JobProgressReport(
                        state: .transcribing,
                        fraction: 0.12 + 0.68 * Double(done) / Double(max(total, 1)),
                        detail: "Transcribing chunk \(done) of \(total)"))
                })

            results.append(contentsOf: outcome.transcripts)
            for record in outcome.records where record.state != .completed {
                try await project.store.upsert(record)
            }
        }

        try await project.store.setStageHash(.transcription, to: inputs.hash(for: .transcription))
        try crashIfRequested(options, .transcription, .after)

        // ── Merge ───────────────────────────────────────────────────────────
        try await advance(project, .merging, progress, 0.82, "Assembling transcript")
        let transcript = try TranscriptMerger().merge(
            chunks: results, plan: chunkPlan, silenceMap: silenceMap,
            provenance: Provenance(
                engineID: engine.identifier,
                silenceParameterHash: inputs.hash(for: .silence),
                chunkParameterHash: inputs.hash(for: .chunking),
                concurrency: options.transcription.concurrency))

        try AtomicFile.writeJSON(transcript, to: package.transcriptURL)
        try AtomicFile.write(Data(transcript.plainText().utf8),
                             to: package.outputDirectory.appending(path: "verbatim.txt"))
        try await project.store.setStageHash(.merge, to: inputs.hash(for: .merge))
        try crashIfRequested(options, .merge, .after)

        try await project.store.setState(.complete)
        progress(JobProgressReport(state: .complete, fraction: 1, detail: "Complete"))
        return transcript
    }

    // MARK: - Helpers

    private func advance(
        _ project: Project, _ state: JobState,
        _ progress: @Sendable (JobProgressReport) -> Void,
        _ fraction: Double, _ detail: String
    ) async throws {
        try Task.checkCancellation()
        try await project.store.setState(state)
        progress(JobProgressReport(state: state, fraction: fraction, detail: detail))
    }

    private func crashIfRequested(_ options: JobOptions, _ stage: StageKey, _ when: CrashPoint.When) throws {
        guard let crash = options.crashPoint, crash.stage == stage, crash.when == when,
              crash.afterChunks == nil else { return }
        Self.die("\(when.rawValue) \(stage.rawValue)")
    }

    /// Kills the process without unwinding.
    ///
    /// `SIGKILL` rather than `exit` or a thrown error: the point is to leave no
    /// opportunity for cleanup, flushes or `defer` blocks, because those are
    /// exactly what a real power loss does not give you.
    private static func die(_ context: String) -> Never {
        FileHandle.standardError.write(Data("voxverba: simulated crash \(context)\n".utf8))
        kill(getpid(), SIGKILL)
        // The kernel terminates the process asynchronously, so execution can
        // continue for a few instructions. Park here rather than falling through
        // to anything that might flush or clean up.
        while true { pause() }
    }
}

/// Counts committed chunks across concurrent callbacks.
private actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
}

extension StageKey: Comparable {
    public static func < (a: StageKey, b: StageKey) -> Bool {
        let order = StageKey.allCases
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}
