import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaTranscription

/// Builds a plan of `count` chunks, each `seconds` long, all soft boundaries.
func makePlan(count: Int, seconds: Double = 10, overlapEvery: Int? = nil) -> ChunkPlan {
    let rate = CanonicalFormat.sampleRate
    var chunks: [ChunkSpec] = []
    for i in 0..<count {
        let start = MediaTime.seconds(Double(i) * seconds)
        let end = start + .seconds(seconds)
        let hard = overlapEvery.map { i % $0 == 0 && i < count - 1 } ?? false
        chunks.append(ChunkSpec(
            sequence: i,
            originalRange: TimeRange(start: start, end: end),
            processedRange: TimeRange(start: start, end: end),
            sampleRange: SampleRange(start: start.samples(at: rate),
                                     count: MediaTime.seconds(seconds).samples(at: rate)),
            boundaryKind: hard ? .hardCut
                : (i == count - 1 ? .endOfMedia : .silence(gapDuration: .seconds(1))),
            overlapLead: .zero))
    }
    return ChunkPlan(chunks: chunks, parameters: .default, parameterHash: "test")
}

@Suite("Chunk scheduler")
struct ChunkSchedulerTests {
    private let dummyAudio = URL(filePath: "/dev/null")

    @Test("Every chunk is transcribed and results come back ordered")
    func allSucceed() async throws {
        let plan = makePlan(count: 12)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)

        let outcome = try await ChunkScheduler().run(
            plan: plan, canonicalFile: dummyAudio, engine: engine, options: .default)

        #expect(outcome.transcripts.count == 12)
        #expect(outcome.transcripts.map(\.sequence) == Array(0..<12))
        #expect(outcome.failedChunks.isEmpty)
        #expect(outcome.completedCount == 12)
    }

    @Test("Concurrency never exceeds the configured limit", arguments: [1, 2, 4])
    func respectsConcurrency(limit: Int) async throws {
        let plan = makePlan(count: 16)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)
        for i in 0..<16 {
            await engine.setBehaviour(.slow(.milliseconds(15)), forSequence: i)
        }

        var options = TranscriptionOptions.default
        options.concurrency = limit
        _ = try await ChunkScheduler().run(
            plan: plan, canonicalFile: dummyAudio, engine: engine, options: options)

        let peak = await engine.peakConcurrency
        #expect(peak <= limit, "peak concurrency \(peak) exceeded limit \(limit)")
        // Above 1, the scheduler should actually be using the headroom.
        if limit > 1 { #expect(peak > 1) }
    }

    @Test("A transient failure is retried and then succeeds")
    func retriesTransientFailure() async throws {
        let plan = makePlan(count: 5)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)
        await engine.setBehaviour(.failTimes(2), forSequence: 3)

        let outcome = try await ChunkScheduler(retryBackoff: .milliseconds(1)).run(
            plan: plan, canonicalFile: dummyAudio, engine: engine, options: .default)

        #expect(outcome.transcripts.count == 5)
        #expect(await engine.attempts(forSequence: 3) == 3)
        #expect(outcome.records.first { $0.sequence == 3 }?.state == .completed)
    }

    @Test("A permanently failing chunk does not fail the job")
    func permanentFailureIsIsolated() async throws {
        // §17: 200 chunks with one corrupt region should yield 199 good chunks
        // and a visible marker, not a dead job.
        let plan = makePlan(count: 10)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)
        await engine.setBehaviour(.failAlways, forSequence: 4)

        let outcome = try await ChunkScheduler(retryBackoff: .milliseconds(1)).run(
            plan: plan, canonicalFile: dummyAudio, engine: engine, options: .default)

        #expect(outcome.transcripts.count == 9)
        #expect(outcome.failedChunks.count == 1)
        #expect(outcome.failedChunks[0].sequence == 4)
        #expect(await engine.attempts(forSequence: 4) == TranscriptionOptions.default.maxAttemptsPerChunk)
        #expect(!outcome.transcripts.contains { $0.sequence == 4 })
    }

    @Test("Already-completed chunks are not transcribed again")
    func skipsCompleted() async throws {
        // The resume path: chunks 0–6 are done, so only 7–9 should run.
        let plan = makePlan(count: 10)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)
        let done = Set(plan.chunks.prefix(7).map(\.id))

        let outcome = try await ChunkScheduler().run(
            plan: plan, canonicalFile: dummyAudio, engine: engine,
            options: .default, skipping: done)

        #expect(outcome.transcripts.count == 3)
        #expect(outcome.transcripts.map(\.sequence) == [7, 8, 9])
        let started = await engine.startOrder
        #expect(Set(started) == [7, 8, 9])
    }

    @Test("Each result is committed before the chunk counts as done")
    func commitsBeforeCounting() async throws {
        let plan = makePlan(count: 8)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)

        let committed = Committed()
        let outcome = try await ChunkScheduler().run(
            plan: plan, canonicalFile: dummyAudio, engine: engine, options: .default,
            onChunkComplete: { await committed.add($0.sequence) })

        #expect(await committed.count() == 8)
        #expect(await committed.sorted() == outcome.transcripts.map(\.sequence))
    }

    @Test("Progress is reported for every chunk and ends at the total")
    func reportsProgress() async throws {
        let plan = makePlan(count: 9)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)

        let seen = Committed()
        _ = try await ChunkScheduler().run(
            plan: plan, canonicalFile: dummyAudio, engine: engine, options: .default,
            progress: { done, total in
                #expect(total == 9)
                Task { await seen.add(done) }
            })
        // The final report must say everything finished.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await seen.sorted().last == 9)
    }

    @Test("Cancellation stops scheduling and leaves chunks resumable")
    func cancellation() async throws {
        let plan = makePlan(count: 40)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)
        for i in 0..<40 { await engine.setBehaviour(.slow(.milliseconds(30)), forSequence: i) }

        let task = Task {
            try await ChunkScheduler().run(
                plan: plan, canonicalFile: dummyAudio, engine: engine, options: .default)
        }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        // Either the group throws CancellationError or it returns early; both
        // leave untouched chunks untouched, which is what resume needs.
        _ = try? await task.value
        let started = await engine.startOrder
        #expect(started.count < 40, "cancellation did not stop scheduling")
    }
}

/// Collects values from concurrent callbacks.
actor Committed {
    private var values: [Int] = []
    func add(_ v: Int) { values.append(v) }
    func count() -> Int { values.count }
    func sorted() -> [Int] { values.sorted() }
}
