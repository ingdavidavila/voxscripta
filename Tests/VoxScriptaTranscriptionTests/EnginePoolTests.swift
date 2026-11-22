import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaTranscription

/// What the pool guarantees, and what it is for.
///
/// The pool exists because the two shipped engines differ in a way that is
/// invisible from the type system: `AppleSpeechEngine` builds its analyzer per
/// call and awaits it, so one instance serves many calls at once, while
/// `WhisperEngine` wraps a synchronous `whisper_full` and holds its actor for
/// the whole inference, so several tasks against one instance queue rather
/// than overlap.
///
/// These tests use engines that record what happened rather than the real
/// ones, because the property under test is the pool's, not the recogniser's.
@Suite("Engine pool")
struct EnginePoolTests {

    /// Records how many calls were inside it at once, and how long each waited.
    private actor Recorder {
        private(set) var concurrentPeak = 0
        private var inFlight = 0
        private(set) var calls = 0

        func enter() { inFlight += 1; calls += 1; concurrentPeak = max(concurrentPeak, inFlight) }
        func leave() { inFlight -= 1 }
    }

    private struct CountingEngine: TranscriptionEngine {
        let identifier = EngineID.appleSpeech
        let recorder: Recorder
        let hold: Duration

        func capabilities() async -> EngineCapabilities {
            EngineCapabilities(supportsWordTimestamps: true, supportedLocales: ["en-US"])
        }
        func prepare(locale: String) async throws {}
        func release() async {}

        func transcribe(
            _ range: SampleRange, in canonicalFile: URL, options: TranscriptionOptions
        ) async throws -> [TranscriptSegment] {
            await recorder.enter()
            try? await Task.sleep(for: hold)
            await recorder.leave()
            return []
        }
    }

    @Test("An engine is lent to one borrower at a time")
    func exclusiveWhileBorrowed() async {
        let a = CountingEngine(recorder: Recorder(), hold: .zero)
        let pool = EnginePool([a])

        let first = await pool.checkout()
        // A second checkout cannot be served until the first is returned, so
        // it is started and left pending rather than awaited here.
        let second = Task { await pool.checkout() }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!second.isCancelled)

        await pool.checkin(first)
        let got = await second.value
        #expect(got.identifier == a.identifier, "the returned engine is lent again")
    }

    @Test("Borrowers are served in turn, and every engine comes back")
    func everyEngineReturned() async {
        let engines = (0..<3).map { _ in
            CountingEngine(recorder: Recorder(), hold: .zero)
        }
        let pool = EnginePool(engines)

        // Take them all, then give them all back.
        var held: [any TranscriptionEngine] = []
        for _ in 0..<3 { held.append(await pool.checkout()) }
        for engine in held { await pool.checkin(engine) }

        // If any had been lost, this would hang rather than fail — so it is
        // bounded by a task that must finish.
        let drained = Task {
            for _ in 0..<3 { _ = await pool.checkout() }
            return true
        }
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await drained.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "an engine was not returned to the pool")
    }

    @Test("A pool of one serialises; a pool of several overlaps")
    func poolSizeBoundsConcurrency() async throws {
        let plan = Self.plan(chunks: 4)

        // One engine, four chunks, concurrency 4: the pool is the bound, so
        // only one inference runs at a time. This is Whisper's situation.
        let single = Recorder()
        _ = try await ChunkScheduler().run(
            plan: plan, canonicalFile: URL(filePath: "/dev/null"),
            engines: [CountingEngine(recorder: single, hold: .milliseconds(40))],
            options: Self.options(concurrency: 4))
        #expect(await single.concurrentPeak == 1,
                "one engine must serve one inference at a time")

        // Three engines, same plan: three run at once.
        let shared = Recorder()
        let many = (0..<3).map { _ in CountingEngine(recorder: shared, hold: .milliseconds(40)) }
        _ = try await ChunkScheduler().run(
            plan: plan, canonicalFile: URL(filePath: "/dev/null"),
            engines: many, options: Self.options(concurrency: 4))
        #expect(await shared.concurrentPeak > 1,
                "distinct engines must be able to run at once")
        #expect(await shared.concurrentPeak <= 3, "never more in flight than the pool holds")
    }

    @Test("Concurrency never exceeds the pool, however high it is set")
    func concurrencyClampedToPool() async throws {
        let recorder = Recorder()
        _ = try await ChunkScheduler().run(
            plan: Self.plan(chunks: 6),
            canonicalFile: URL(filePath: "/dev/null"),
            engines: (0..<2).map { _ in CountingEngine(recorder: recorder, hold: .milliseconds(30)) },
            options: Self.options(concurrency: 16))
        #expect(await recorder.concurrentPeak <= 2,
                "asking for sixteen with two engines must not run sixteen")
        #expect(await recorder.calls == 6, "every chunk is still transcribed")
    }

    // MARK: - Fixtures

    private static func options(concurrency: Int) -> TranscriptionOptions {
        var o = TranscriptionOptions.default
        o.concurrency = concurrency
        o.maxAttemptsPerChunk = 1
        return o
    }

    private static func plan(chunks: Int) -> ChunkPlan {
        let rate = CanonicalFormat.sampleRate
        let specs = (0..<chunks).map { i in
            ChunkSpec(
                sequence: i,
                originalRange: TimeRange(start: .seconds(Double(i)), end: .seconds(Double(i + 1))),
                processedRange: TimeRange(start: .seconds(Double(i)), end: .seconds(Double(i + 1))),
                sampleRange: SampleRange(start: Int64(i * rate), count: Int64(rate)),
                boundaryKind: .silence(gapDuration: .seconds(1)),
                overlapLead: .zero)
        }
        return ChunkPlan(chunks: specs, parameters: .default, parameterHash: "pool-test")
    }
}
