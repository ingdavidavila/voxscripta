import Foundation
import VoxVerbaCore
import VoxVerbaTranscription

/// A deterministic stand-in for a real speech engine.
///
/// The scheduler and the merger have logic worth testing precisely — retry
/// budgets, ordering under concurrency, overlap de-duplication — and none of it
/// should depend on a speech model's output. This engine emits predictable words
/// derived from a chunk's position, so an assertion about ordering is an
/// assertion about the scheduler rather than about the weather.
public actor MockTranscriptionEngine: TranscriptionEngine {
    /// How the engine should behave for a given chunk.
    public enum Behaviour: Sendable {
        case succeed
        /// Fail this many times, then succeed. Exercises the retry path.
        case failTimes(Int)
        /// Always fail. Exercises the permanent-failure path.
        case failAlways
        /// Take this long, so concurrency has something to overlap.
        case slow(Duration)
    }

    public nonisolated let identifier = EngineID.mock
    /// Words emitted per second of audio.
    public nonisolated let wordsPerSecond: Double

    private var behaviours: [Int: Behaviour] = [:]
    /// Maps a chunk's starting sample to its sequence number.
    private var sequenceBySampleStart: [Int64: Int] = [:]
    private var attemptCounts: [Int: Int] = [:]
    private var prepared = false

    /// Peak number of concurrent `transcribe` calls observed.
    public private(set) var peakConcurrency = 0
    private var activeCalls = 0
    /// Chunk sequences in the order transcription started.
    public private(set) var startOrder: [Int] = []

    public init(wordsPerSecond: Double = 2.0) {
        self.wordsPerSecond = wordsPerSecond
    }

    /// Registers a plan so the engine can name chunks by sequence.
    ///
    /// `transcribe` receives only a sample range, so without this the engine
    /// would have to infer identity from timing — which makes tests read as if
    /// they are asserting about arithmetic rather than about scheduling.
    public func register(plan: ChunkPlan) {
        for chunk in plan.chunks {
            sequenceBySampleStart[chunk.sampleRange.start] = chunk.sequence
        }
    }

    public func setBehaviour(_ behaviour: Behaviour, forSequence sequence: Int) {
        behaviours[sequence] = behaviour
    }

    public func capabilities() async -> EngineCapabilities {
        EngineCapabilities(supportsWordTimestamps: true, supportedLocales: ["en-US"])
    }

    public func prepare(locale: String) async throws { prepared = true }
    public func release() async { prepared = false }

    /// Words this engine will emit for a chunk, so tests can predict output.
    public nonisolated func expectedWords(forSequence sequence: Int, count: Int) -> [String] {
        (0..<count).map { "c\(sequence)w\($0)" }
    }

    public func transcribe(
        _ range: SampleRange,
        in canonicalFile: URL,
        options: TranscriptionOptions
    ) async throws -> [TranscriptSegment] {
        // The mock keys behaviour off the chunk's start time, which the scheduler
        // passes through unchanged.
        let startTime = MediaTime(samples: range.start, sampleRate: CanonicalFormat.sampleRate)
        let duration = MediaTime(samples: range.count, sampleRate: CanonicalFormat.sampleRate)
        let sequence = sequenceBySampleStart[range.start] ?? Int(startTime.seconds.rounded())

        activeCalls += 1
        peakConcurrency = Swift.max(peakConcurrency, activeCalls)
        startOrder.append(sequence)
        defer { activeCalls -= 1 }

        let attempt = (attemptCounts[sequence] ?? 0) + 1
        attemptCounts[sequence] = attempt

        switch behaviours[sequence] ?? .succeed {
        case .succeed:
            break
        case .failTimes(let n) where attempt <= n:
            throw VoxVerbaError.transcriptionFailed(chunk: ChunkID(), reason: "mock failure \(attempt)")
        case .failTimes:
            break
        case .failAlways:
            throw VoxVerbaError.transcriptionFailed(chunk: ChunkID(), reason: "mock permanent failure")
        case .slow(let delay):
            try await Task.sleep(for: delay)
        }

        let wordCount = Swift.max(1, Int(duration.seconds * wordsPerSecond))
        let step = duration.seconds / Double(wordCount)
        var words: [Word] = []
        for i in 0..<wordCount {
            let wordStart = startTime + .seconds(Double(i) * step)
            words.append(Word(text: "c\(sequence)w\(i)",
                              originalStart: wordStart,
                              originalEnd: wordStart + .seconds(step * 0.8),
                              confidence: 0.9))
        }
        return [TranscriptSegment(
            originalStart: startTime,
            originalEnd: startTime + duration,
            text: words.map(\.text).joined(separator: " "),
            words: words,
            confidence: 0.9
        )]
    }

    public func attempts(forSequence sequence: Int) -> Int { attemptCounts[sequence] ?? 0 }
}
