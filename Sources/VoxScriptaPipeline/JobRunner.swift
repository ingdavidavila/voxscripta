import Foundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaTranscription
import VoxScriptaLanguage
import VoxScriptaMLX
import VoxScriptaProject

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
    public var clean: CleanParameters
    /// Polish settings, or `nil` to stop after CLEAN.
    public var polish: PolishParameters?
    /// Which language model the polish pass should use.
    public var polishBackend: PolishBackendPreference
    /// An explicit model folder, overriding whatever the app bundles.
    public var polishModelDirectory: URL?

    /// Keep the scratch audio and per-chunk results after a job finishes.
    ///
    /// §5 asks that intermediates be cleaned up automatically unless the user
    /// chooses otherwise, so the default is to reclaim them. For a six-hour
    /// recording that is about 1.4 GB of canonical PCM per project. Nothing in
    /// `Original/` or `Output/` is ever touched, and a reclaimed project stays
    /// openable — the transcripts are the result, the scratch work is not.
    public var keepIntermediates: Bool
    /// Test-only fault injection.
    public var crashPoint: CrashPoint?

    public init(
        transcription: TranscriptionOptions = .default,
        geometry: FrameGeometry = .default,
        clean: CleanParameters = .default,
        polish: PolishParameters? = .default,
        polishBackend: PolishBackendPreference = .automatic,
        polishModelDirectory: URL? = nil,
        keepIntermediates: Bool = false,
        crashPoint: CrashPoint? = nil
    ) {
        self.transcription = transcription
        self.geometry = geometry
        self.clean = clean
        self.polish = polish
        self.polishBackend = polishBackend
        self.polishModelDirectory = polishModelDirectory
        self.keepIntermediates = keepIntermediates
        self.crashPoint = crashPoint
    }
}

/// Progress across the whole pipeline.
public struct JobProgressReport: Sendable {
    public let state: JobState
    public let fraction: Double
    public let detail: String

    public init(state: JobState, fraction: Double, detail: String) {
        self.state = state
        self.fraction = fraction
        self.detail = detail
    }
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
        let options = resolved(options, for: project)
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
            // From the manifest, not the caller. These are part of the
            // transcription hash, so taking them from ambient defaults would make
            // simply reopening a project re-transcribe it.
            locale: project.manifest.locale,
            concurrency: project.manifest.concurrency)

        let plan = try await ResumePlanner().plan(for: project, inputs: inputs)

        switch plan {
        case .sourceMissing(let path):
            throw VoxScriptaError.sourceUnavailable(path: path)
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

        // Only POLISH is missing — a crash between cleaning and polishing leaves
        // exactly this. Everything upstream is valid, including the clean
        // transcript, so only the language model pass is redone.
        if startStage == .polish {
            let clean = try AtomicFile.readJSON(Transcript.self, from: package.cleanTranscriptURL)
            try await runPolishStage(project: project, clean: clean,
                                     options: options, progress: progress)
            try await project.store.setState(.complete)
            progress(JobProgressReport(state: .complete, fraction: 1, detail: "Complete"))
            return try AtomicFile.readJSON(Transcript.self, from: package.transcriptURL)
        }

        // Only the CLEAN pass is missing — a crash between writing the verbatim
        // transcript and cleaning it leaves exactly this state. Everything
        // upstream is valid, so redo just the last, cheap, deterministic stage.
        if startStage == .clean {
            let verbatim = try AtomicFile.readJSON(Transcript.self, from: package.transcriptURL)
            let cleaned = try await runCleanStage(project: project, verbatim: verbatim,
                                                  options: options, progress: progress)
            try await runPolishStage(project: project, clean: cleaned,
                                     options: options, progress: progress)
            try await finish(project: project, options: options, progress: progress)
            return verbatim
        }

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
            // Peaks are cheap here and expensive later: the UI needs a waveform
            // the moment a project opens, long before it would want to re-read
            // the audio.
            if let peaks = try? WaveformPeaks.build(canonicalFile: package.canonicalAudioURL) {
                try? AtomicFile.writeJSON(peaks, to: package.peaksURL, formatting: [])
            }
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
                             to: package.textURL(for: .verbatim))
        try await project.store.setStageHash(.merge, to: inputs.hash(for: .merge))
        try crashIfRequested(options, .merge, .after)

        let cleaned = try await runCleanStage(project: project, verbatim: transcript,
                                              options: options, progress: progress)
        try crashIfRequested(options, .clean, .after)

        try await runPolishStage(project: project, clean: cleaned,
                                 options: options, progress: progress)
        try crashIfRequested(options, .polish, .after)

        try await finish(project: project, options: options, progress: progress)
        return transcript
    }

    /// Marks the job complete and reclaims scratch storage.
    ///
    /// Reclaiming last, after every output is durable, so a failure here can only
    /// cost disk space rather than results.
    private func finish(
        project: Project,
        options: JobOptions,
        progress: @escaping @Sendable (JobProgressReport) -> Void
    ) async throws {
        try await project.store.setState(.complete)

        if !options.keepIntermediates {
            let freed = (try? project.reclaimDerivedStorage()) ?? 0
            if freed > 0 {
                Log.project.info("reclaimed \(freed / (1 << 20)) MB of intermediate files")
            }
        }
        progress(JobProgressReport(state: .complete, fraction: 1, detail: "Complete"))
    }

    /// The CLEAN pass: deterministic rules only, no model.
    ///
    /// Separate because it is also the whole of a clean-only resume, and because
    /// keeping it in one place makes it obvious that nothing here consults a
    /// language model.
    private func runCleanStage(
        project: Project,
        verbatim: Transcript,
        options: JobOptions,
        progress: @Sendable (JobProgressReport) -> Void
    ) async throws -> Transcript {
        let package = project.package
        try await advance(project, .cleaning, progress, 0.92, "Cleaning transcript")

        let cleaned = try CleanProcessor().process(
            verbatim: verbatim, parameters: options.clean,
            silenceParameters: project.manifest.silenceParameters)

        try AtomicFile.writeJSON(cleaned.transcript, to: package.cleanTranscriptURL)
        try AtomicFile.write(Data(cleaned.transcript.plainText().utf8),
                             to: package.textURL(for: .clean))
        // The edit log ships alongside, so the pass is auditable rather than
        // merely claimed to be safe.
        try AtomicFile.writeJSON(cleaned.edits, to: package.cleanEditsURL)

        let inputs = try await stageInputs(for: project, options: options)
        try await project.store.setStageHash(.clean, to: inputs.hash(for: .clean))
        return cleaned.transcript
    }

    /// Rebuilds the stage input set from a project's manifest and options.
    /// Options with the manifest's stored transcription settings applied.
    ///
    /// A project's locale and concurrency belong to the project, exactly like its
    /// silence thresholds.
    private func resolved(_ options: JobOptions, for project: Project) -> JobOptions {
        var resolved = options
        resolved.transcription.locale = project.manifest.locale
        resolved.transcription.concurrency = project.manifest.concurrency
        return resolved
    }

    private func stageInputs(for project: Project, options: JobOptions) async throws -> StageInputs {
        StageInputs(
            sourceContentHash: project.manifest.source.contentHash,
            frameGeometryDescription: "\(options.geometry.windowDuration.nanoseconds)"
                + ",\(options.geometry.hopDuration.nanoseconds),\(options.geometry.sampleRate)",
            silenceParameters: project.manifest.silenceParameters,
            chunkParameters: project.manifest.chunkParameters,
            engineID: project.manifest.engineID,
            // From the manifest, not the caller. These are part of the
            // transcription hash, so taking them from ambient defaults would make
            // simply reopening a project re-transcribe it.
            locale: project.manifest.locale,
            concurrency: project.manifest.concurrency)
    }

    /// Reads a produced variant back from a completed project.
    public static func transcript(
        _ variant: TranscriptVariant, from package: ProjectPackage
    ) throws -> Transcript {
        switch variant {
        case .verbatim: return try AtomicFile.readJSON(Transcript.self, from: package.transcriptURL)
        case .clean: return try AtomicFile.readJSON(Transcript.self, from: package.cleanTranscriptURL)
        case .polished:
            guard FileManager.default.fileExists(atPath: package.polishedTranscriptURL.path) else {
                throw VoxScriptaError.modelUnavailable(
                    .systemDefault,
                    reason: "this project has no polished transcript; the model may be unavailable")
            }
            return try AtomicFile.readJSON(Transcript.self, from: package.polishedTranscriptURL)
        }
    }

    /// Runs POLISHED, the only stage that involves a language model.
    ///
    /// It is also the only stage allowed to decline. If the model is unavailable
    /// — Apple Intelligence off, device ineligible, assets still downloading —
    /// the job still completes with verbatim and clean, and the reason is written
    /// to disk so a missing polished transcript is never unexplained.
    private func runPolishStage(
        project: Project,
        clean: Transcript,
        options: JobOptions,
        progress: @escaping @Sendable (JobProgressReport) -> Void
    ) async throws {
        guard let parameters = options.polish else { return }
        let package = project.package

        try await advance(project, .polishing, progress, 0.94, "Polishing transcript")

        let resolved: ResolvedBackend
        do {
            resolved = try PolishBackendResolver.resolve(
                options.polishBackend, modelDirectory: options.polishModelDirectory)
        } catch {
            let reason = (error as? VoxScriptaError)?.errorDescription ?? error.localizedDescription
            try? AtomicFile.write(Data(reason.utf8), to: package.polishSkippedURL)
            Log.language.notice("polish skipped: \(reason, privacy: .public)")
            return
        }
        let host = resolved.host

        do {
            try await host.load()
            let polished = try await PolishProcessor().process(
                clean: clean, parameters: parameters, host: host,
                progress: { fraction in
                    progress(JobProgressReport(
                        state: .polishing, fraction: 0.94 + 0.05 * fraction,
                        detail: "Polishing transcript"))
                })
            await host.unload()

            try AtomicFile.writeJSON(polished.transcript, to: package.polishedTranscriptURL)
            try AtomicFile.write(Data(polished.transcript.plainText().utf8),
                                 to: package.textURL(for: .polished))
            try AtomicFile.writeJSON(polished.sentences, to: package.polishReportURL)
            try? FileManager.default.removeItem(at: package.polishSkippedURL)
            Log.language.info("polished with \(resolved.describedAs, privacy: .public)")

            let inputs = try await stageInputs(for: project, options: options)
            try await project.store.setStageHash(.polish, to: inputs.hash(for: .polish))
        } catch {
            await host.unload()
            let reason = (error as? VoxScriptaError)?.errorDescription ?? error.localizedDescription
            try? AtomicFile.write(Data(reason.utf8), to: package.polishSkippedURL)
            Log.language.notice("polish skipped: \(reason, privacy: .public)")
        }
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
        FileHandle.standardError.write(Data("voxscripta: simulated crash \(context)\n".utf8))
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
