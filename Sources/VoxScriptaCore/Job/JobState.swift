import Foundation

/// The phases a job moves through (§17).
///
/// The order of `allCases` is the pipeline order, and the resume planner walks it
/// looking for the first stage whose artifacts are missing or stale — so the
/// declaration order here is load-bearing, not cosmetic.
public enum JobState: String, Sendable, Codable, CaseIterable {
    case imported
    case analyzing
    case silenceProcessing
    case chunking
    case transcribing
    case merging
    case cleaning
    case polishing
    case complete
    case failed
    case cancelled

    /// States from which no further work happens without user action.
    public var isTerminal: Bool {
        switch self {
        case .complete, .failed, .cancelled: true
        default: false
        }
    }

    /// The ordered working phases, excluding terminal states.
    public static var pipeline: [JobState] {
        allCases.filter { !$0.isTerminal }
    }

    /// The phase that normally follows this one, or `nil` at the end of the pipeline.
    public var successor: JobState? {
        switch self {
        case .imported: .analyzing
        case .analyzing: .silenceProcessing
        case .silenceProcessing: .chunking
        case .chunking: .transcribing
        case .transcribing: .merging
        case .merging: .cleaning
        case .cleaning: .polishing
        case .polishing: .complete
        case .complete, .failed, .cancelled: nil
        }
    }

    /// Whether a transition to `next` is legal.
    ///
    /// Forward progress follows ``successor``. Failure and cancellation are legal
    /// from any working state. Re-entering the current state is legal because
    /// resume restarts the interrupted phase from its beginning.
    public func canTransition(to next: JobState) -> Bool {
        if isTerminal { return false }
        if next == .failed || next == .cancelled { return true }
        if next == self { return true }
        return successor == next
    }

    /// Fraction of total pipeline work nominally complete on entering this state.
    ///
    /// These weights are rough placeholders for UI layout in Phase 0; Phase 2's
    /// benchmark harness replaces them with measured proportions.
    public var nominalProgress: Double {
        switch self {
        case .imported: 0.00
        case .analyzing: 0.02
        case .silenceProcessing: 0.08
        case .chunking: 0.10
        case .transcribing: 0.12
        case .merging: 0.80
        case .cleaning: 0.83
        case .polishing: 0.88
        case .complete: 1.00
        case .failed, .cancelled: 0.00
        }
    }
}

/// The lifecycle of a single chunk within the transcribing phase.
public enum ChunkState: String, Sendable, Codable, CaseIterable {
    case pending
    case inFlight
    case completed
    case retryScheduled
    /// Exhausted its retries. The job continues; a gap marker is inserted.
    case failedPermanent
    /// Deliberately not transcribed — silent, or excluded by the user.
    case skipped

    /// Whether the scheduler still has work to do for this chunk.
    public var isOutstanding: Bool {
        switch self {
        case .pending, .inFlight, .retryScheduled: true
        case .completed, .failedPermanent, .skipped: false
        }
    }
}

/// A chunk's durable bookkeeping, one row in the job store.
public struct ChunkRecord: Hashable, Sendable, Codable, Identifiable {
    public let id: ChunkID
    public let sequence: Int
    public var state: ChunkState
    public var attempts: Int
    public var lastError: String?
    public var completedAt: Date?
    /// Wall-clock time of the successful attempt, for the benchmark harness.
    public var processingDuration: TimeInterval?

    public init(
        id: ChunkID,
        sequence: Int,
        state: ChunkState = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        completedAt: Date? = nil,
        processingDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.completedAt = completedAt
        self.processingDuration = processingDuration
    }

    /// Whether another attempt is permitted.
    public func canRetry(maxAttempts: Int) -> Bool {
        attempts < maxAttempts
    }
}

/// A job's overall progress, as the UI consumes it.
///
/// Progress is reported as a coalesced snapshot rather than a stream of per-chunk
/// callbacks, so the main actor is never asked to lay out text hundreds of times
/// a second (§18).
public struct JobProgress: Hashable, Sendable {
    public let state: JobState
    /// Progress within the current phase, `0...1`.
    public let phaseProgress: Double
    public let chunksCompleted: Int
    public let chunksTotal: Int
    /// Human-readable description of the work in flight.
    public let detail: String

    public init(
        state: JobState,
        phaseProgress: Double,
        chunksCompleted: Int = 0,
        chunksTotal: Int = 0,
        detail: String = ""
    ) {
        self.state = state
        self.phaseProgress = Swift.min(Swift.max(phaseProgress, 0), 1)
        self.chunksCompleted = chunksCompleted
        self.chunksTotal = chunksTotal
        self.detail = detail
    }

    /// Overall progress across the whole pipeline, `0...1`.
    public var overallProgress: Double {
        guard !state.isTerminal else { return state == .complete ? 1 : 0 }
        let base = state.nominalProgress
        let next = state.successor?.nominalProgress ?? 1
        return base + (next - base) * phaseProgress
    }
}
