import Foundation
import VoxScriptaCore

/// What a scheduling run produced.
public struct SchedulerOutcome: Sendable {
    /// Successful results, ordered by chunk sequence.
    public let transcripts: [ChunkTranscript]
    /// Bookkeeping for every chunk, including the ones that failed.
    public let records: [ChunkRecord]

    public init(transcripts: [ChunkTranscript], records: [ChunkRecord]) {
        self.transcripts = transcripts.sorted { $0.sequence < $1.sequence }
        self.records = records.sorted { $0.sequence < $1.sequence }
    }

    /// Chunks that exhausted their retries. The job continues without them.
    public var failedChunks: [ChunkRecord] {
        records.filter { $0.state == .failedPermanent }
    }

    public var completedCount: Int { records.filter { $0.state == .completed }.count }
}

/// Hands an engine to each chunk in flight, and takes it back afterwards.
///
/// Only needed for engines that cannot serve two calls at once — which is
/// whisper.cpp, because `whisper_full` is synchronous and holds its actor for
/// the whole inference. Several tasks against one instance queue rather than
/// overlap, so parallelism there means an instance each.
///
/// An engine that *can* take concurrent calls is pooled too, with a pool of
/// one: the same code path, one instance, and every task borrowing it in turn
/// without ever waiting, because its calls suspend rather than block.
///
/// Borrowing spans the inference and nothing else. The engine goes back before
/// the result is committed, so a slow write never holds a context, and so a
/// failure in the commit path cannot leak one.
actor EnginePool {
    private var free: [any TranscriptionEngine]
    private var waiting: [CheckedContinuation<any TranscriptionEngine, Never>] = []

    init(_ engines: [any TranscriptionEngine]) {
        precondition(!engines.isEmpty, "an engine pool needs at least one engine")
        free = engines
    }

    func checkout() async -> any TranscriptionEngine {
        if let engine = free.popLast() { return engine }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func checkin(_ engine: any TranscriptionEngine) {
        if let next = waiting.popLast() { next.resume(returning: engine) }
        else { free.append(engine) }
    }
}

/// Drives chunk transcription with bounded concurrency and a retry budget.
///
/// Two behaviours here are deliberate and worth stating.
///
/// **A failed chunk does not fail the job.** After its retries are exhausted the
/// chunk is marked `failedPermanent`, a gap marker takes its place in the
/// transcript, and the remaining chunks proceed. A 200-chunk lecture with one
/// corrupt region should yield 199 good chunks and a visible marker, not nothing.
///
/// **Results are committed as they arrive.** `onChunkComplete` runs before the
/// scheduler moves on, which is the seam Phase 3's atomic commit plugs into — and
/// is what makes resume land on a durable boundary rather than mid-flight.
public protocol ChunkScheduling: Sendable {
    func run(
        plan: ChunkPlan,
        canonicalFile: URL,
        engine: any TranscriptionEngine,
        options: TranscriptionOptions,
        skipping completed: Set<ChunkID>,
        onChunkComplete: @escaping @Sendable (ChunkTranscript) async throws -> Void,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> SchedulerOutcome
}

public struct ChunkScheduler: ChunkScheduling {
    /// Base delay before a retry; doubled on each further attempt.
    public let retryBackoff: Duration

    public init(retryBackoff: Duration = .milliseconds(250)) {
        self.retryBackoff = retryBackoff
    }

    /// The one-engine case, which is every caller that existed before pools.
    ///
    /// Kept so the public API is unchanged, and because it is the right call
    /// for an engine whose own calls overlap: one instance, every chunk
    /// borrowing it in turn and none of them waiting.
    public func run(
        plan: ChunkPlan,
        canonicalFile: URL,
        engine: any TranscriptionEngine,
        options: TranscriptionOptions,
        skipping completed: Set<ChunkID> = [],
        onChunkComplete: @escaping @Sendable (ChunkTranscript) async throws -> Void = { _ in },
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> SchedulerOutcome {
        // The pool is the set of slots, so one engine that serves concurrent
        // calls fills every slot with itself: each task borrows the same
        // instance and none of them waits, which is how this behaved before
        // pools existed. One that cannot gets a pool of one, and its chunks
        // queue — also exactly as before. Either way a caller holding a
        // single engine gets the behaviour it used to get.
        let slots = await engine.capabilities().supportsConcurrentCalls
            ? Swift.max(1, options.concurrency) : 1
        return try await run(plan: plan, canonicalFile: canonicalFile,
                      engines: Array(repeating: engine, count: slots),
                      options: options, skipping: completed,
                      onChunkComplete: onChunkComplete, progress: progress)
    }

    public func run(
        plan: ChunkPlan,
        canonicalFile: URL,
        engines: [any TranscriptionEngine],
        options: TranscriptionOptions,
        skipping completed: Set<ChunkID> = [],
        onChunkComplete: @escaping @Sendable (ChunkTranscript) async throws -> Void = { _ in },
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> SchedulerOutcome {
        let pool = EnginePool(engines)
        let pending = plan.chunks.filter { !completed.contains($0.id) }
        let total = plan.chunks.count
        let alreadyDone = total - pending.count

        guard !pending.isEmpty else {
            return SchedulerOutcome(transcripts: [], records: [])
        }

        let collector = ResultCollector(alreadyCompleted: alreadyDone, total: total)
        // Never more in flight than there are engines to serve them: an extra
        // task would only queue on `checkout()`, which looks like parallelism
        // and is not.
        let concurrency = Swift.max(1, Swift.min(options.concurrency, pending.count, engines.count))

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0

            func addTask(_ chunk: ChunkSpec) {
                group.addTask {
                    // Borrowed for the inference only. `transcribeWithRetries`
                    // returns an outcome rather than throwing, so there is no
                    // path between these two lines that skips the return.
                    let engine = await pool.checkout()
                    let outcome = await Self.transcribeWithRetries(
                        chunk: chunk, canonicalFile: canonicalFile, engine: engine,
                        options: options, backoff: retryBackoff)
                    await pool.checkin(engine)

                    switch outcome {
                    case .success(let transcript, let record):
                        // Commit before counting it done, so a crash between the
                        // two cannot lose work that was reported as finished.
                        try await onChunkComplete(transcript)
                        await collector.record(transcript: transcript, record: record)
                    case .failure(let record):
                        await collector.record(transcript: nil, record: record)
                    }
                    let (done, count) = await collector.counts()
                    progress(done, count)
                }
            }

            // Prime the group to the concurrency limit, then top it up as tasks
            // finish. This bounds in-flight work rather than in-flight *tasks*.
            while next < pending.count && next < concurrency {
                addTask(pending[next])
                next += 1
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if next < pending.count {
                    addTask(pending[next])
                    next += 1
                }
            }
        }

        return await collector.outcome()
    }

    // MARK: - Retry

    private enum ChunkOutcome {
        case success(ChunkTranscript, ChunkRecord)
        case failure(ChunkRecord)
    }

    private static func transcribeWithRetries(
        chunk: ChunkSpec,
        canonicalFile: URL,
        engine: any TranscriptionEngine,
        options: TranscriptionOptions,
        backoff: Duration
    ) async -> ChunkOutcome {
        var record = ChunkRecord(id: chunk.id, sequence: chunk.sequence, state: .inFlight)
        var delay = backoff

        while record.attempts < options.maxAttemptsPerChunk {
            record.attempts += 1
            let started = ContinuousClock.now

            do {
                try Task.checkCancellation()
                let reported = try await engine.transcribe(
                    chunk.sampleRange, in: canonicalFile, options: options)
                // An engine may only speak about the audio it was given.
                let segments = Self.clamped(reported, to: chunk.originalRange)
                let elapsed = ContinuousClock.now - started

                record.state = .completed
                record.completedAt = Date()
                record.processingDuration = elapsed.elapsedSeconds
                record.lastError = nil

                return .success(
                    ChunkTranscript(
                        chunkID: chunk.id, sequence: chunk.sequence, segments: segments,
                        engineID: engine.identifier, processingDuration: elapsed.elapsedSeconds),
                    record)
            } catch is CancellationError {
                record.state = .pending      // resume will pick it up unchanged
                record.lastError = "cancelled"
                return .failure(record)
            } catch {
                record.lastError = error.localizedDescription
                let retryable = (error as? VoxScriptaError)?.isRetryable ?? true
                guard retryable, record.attempts < options.maxAttemptsPerChunk else {
                    record.state = .failedPermanent
                    return .failure(record)
                }
                record.state = .retryScheduled
                try? await Task.sleep(for: delay)
                delay = delay * 2
            }
        }

        record.state = .failedPermanent
        return .failure(record)
    }

    /// Keeps a chunk's segments inside the chunk.
    ///
    /// An engine is given one span of audio and may only speak about that span,
    /// but Whisper's timestamps are quantized and its last segment of a window
    /// can land past the end of what it was handed. Measured on a 15-minute
    /// recording: chunk 0 covered 0.00–242.86 s and reported a segment ending
    /// at 243.32 s, 0.46 s beyond its own audio.
    ///
    /// That is enough to break everything downstream. The merger requires
    /// segments in ascending, non-overlapping order — rightly, since the whole
    /// transcript's structure rests on it — so one overshooting segment makes
    /// the next chunk's first segment start before the previous one ended and
    /// the merge throws. The practical effect was that no recording long
    /// enough to need more than one chunk could be transcribed at all.
    ///
    /// Clamped here rather than in each engine because the constraint belongs
    /// to the chunk, not to any engine's idea of time, and one implementation
    /// then covers every engine including ones not yet written.
    ///
    /// Times are clamped and nothing is dropped. A segment whose timestamps are
    /// wrong still holds words that were really said — the engine heard only
    /// this chunk's audio, so the text came from inside it whatever the clock
    /// says — and discarding it would turn a timing error into missing words.
    static func clamped(_ segments: [TranscriptSegment],
                        to range: TimeRange) -> [TranscriptSegment] {
        segments.map { segment in
            var bounded = segment
            let start = MediaTime.min(MediaTime.max(segment.originalStart, range.start), range.end)
            bounded.originalStart = start
            bounded.originalEnd = MediaTime.min(MediaTime.max(segment.originalEnd, start), range.end)
            return bounded
        }
    }
}

/// Accumulates results across concurrent tasks.
private actor ResultCollector {
    private var transcripts: [ChunkTranscript] = []
    private var records: [ChunkRecord] = []
    private var done: Int
    private let total: Int

    init(alreadyCompleted: Int, total: Int) {
        done = alreadyCompleted
        self.total = total
    }

    func record(transcript: ChunkTranscript?, record: ChunkRecord) {
        if let transcript { transcripts.append(transcript) }
        records.append(record)
        done += 1
    }

    func counts() -> (Int, Int) { (done, total) }

    func outcome() -> SchedulerOutcome {
        SchedulerOutcome(transcripts: transcripts, records: records)
    }
}

public extension Duration {
    /// The duration as floating-point seconds.
    ///
    /// Named to avoid colliding with the `Duration.seconds(_:)` factory, which
    /// otherwise wins member lookup on an instance.
    var elapsedSeconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
