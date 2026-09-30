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

    public func run(
        plan: ChunkPlan,
        canonicalFile: URL,
        engine: any TranscriptionEngine,
        options: TranscriptionOptions,
        skipping completed: Set<ChunkID> = [],
        onChunkComplete: @escaping @Sendable (ChunkTranscript) async throws -> Void = { _ in },
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> SchedulerOutcome {
        let pending = plan.chunks.filter { !completed.contains($0.id) }
        let total = plan.chunks.count
        let alreadyDone = total - pending.count

        guard !pending.isEmpty else {
            return SchedulerOutcome(transcripts: [], records: [])
        }

        let collector = ResultCollector(alreadyCompleted: alreadyDone, total: total)
        let concurrency = Swift.max(1, Swift.min(options.concurrency, pending.count))

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0

            func addTask(_ chunk: ChunkSpec) {
                group.addTask {
                    let outcome = await Self.transcribeWithRetries(
                        chunk: chunk, canonicalFile: canonicalFile, engine: engine,
                        options: options, backoff: retryBackoff)

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
                let segments = try await engine.transcribe(
                    chunk.sampleRange, in: canonicalFile, options: options)
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
