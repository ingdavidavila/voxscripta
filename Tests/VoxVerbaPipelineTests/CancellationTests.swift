import Testing
import Foundation
import VoxVerbaCore
import VoxVerbaDSP
import VoxVerbaTranscription
import VoxVerbaProject
import VoxVerbaTestSupport
@testable import VoxVerbaPipeline

/// Cancellation, in-process and with a deterministic engine.
///
/// These use `MockTranscriptionEngine` rather than the real model: the question
/// is whether the runner stops promptly and leaves recoverable state, which is a
/// property of the pipeline and should not depend on how fast a model happens to
/// be on the day.
@Suite("Cancellation", .serialized)
struct CancellationTests {

    private func makeProject(in tmp: borrowing TempDirectory) async throws -> Project {
        // Long enough, with regular pauses, to plan many chunks.
        var spans: [SignalSpan] = []
        for i in 0..<40 {
            let a = Double(i) * 12, b = a + 10
            spans.append(SignalSpan(kind: .voiced,
                                    range: TimeRange(start: .seconds(a), end: .seconds(b)),
                                    levelDB: -20))
            spans.append(SignalSpan(kind: .silence,
                                    range: TimeRange(start: .seconds(b), end: .seconds(a + 12)),
                                    levelDB: -62))
        }
        let samples = SignalSynthesizer().render(spans: spans)
        let audio = tmp.url.appending(path: "long.wav")
        try AudioFileWriter.write(samples: samples, to: audio, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        var chunking = ChunkParameters.default
        chunking.minDuration = .seconds(20)
        chunking.targetDuration = .seconds(30)
        chunking.maxDuration = .seconds(40)

        let decoder = CanonicalDecoder()
        return try await ProjectStore().create(
            from: audio, at: tmp.url.appending(path: "p.voxverba"),
            chunking: chunking,
            probe: { (try await decoder.probe(url: $0), try decoder.duration(of: $0)) })
    }

    /// A mock engine that takes long enough per chunk for a cancel to land.
    ///
    /// Without a delay the mock finishes every chunk in microseconds and the test
    /// measures scheduler throughput rather than cancellation.
    private func slowEngine(chunks: Int = 200) async -> MockTranscriptionEngine {
        let engine = MockTranscriptionEngine()
        for sequence in 0..<chunks {
            await engine.setBehaviour(.slow(.milliseconds(80)), forSequence: sequence)
        }
        return engine
    }

    @Test("Cancelling stops the run and leaves the project resumable")
    func cancelMidTranscription() async throws {
        let tmp = try TempDirectory()
        let project = try await makeProject(in: tmp)

        let engine = await slowEngine()
        let runner = JobRunner(engineFactory: { engine })
        var options = JobOptions()
        options.transcription.concurrency = 1

        let started = Signal()
        let task = Task {
            try await runner.run(project: project, options: options) { report in
                if report.state == .transcribing { Task { await started.fire() } }
            }
        }
        // Let a few chunks land, then cancel mid-flight.
        try await started.wait(timeout: .seconds(20))
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = try? await task.value

        // §19: the original is untouched and the work already done survives.
        let (source, release) = try project.resolveSource()
        defer { release() }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: project.package.canonicalAudioURL.path))

        let records = try await project.store.loadChunkRecords()
        #expect(!records.isEmpty, "the chunk plan should have been committed before transcription")
        let completed = records.filter { $0.state == .completed }
        #expect(completed.count < records.count, "cancellation did not actually stop the run")
    }

    @Test("Resuming a cancelled job finishes it without redoing completed chunks")
    func resumeAfterCancel() async throws {
        let tmp = try TempDirectory()
        let project = try await makeProject(in: tmp)

        let engine = await slowEngine()
        let runner = JobRunner(engineFactory: { engine })
        var options = JobOptions()
        options.transcription.concurrency = 1

        let started = Signal()
        let task = Task {
            try await runner.run(project: project, options: options) { report in
                if report.state == .transcribing { Task { await started.fire() } }
            }
        }
        try await started.wait(timeout: .seconds(20))
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = try? await task.value

        let completedFirst = try await project.store.loadChunkRecords()
            .filter { $0.state == .completed }.map(\.sequence)
        #expect(!completedFirst.isEmpty, "no chunk committed before cancellation")

        // A cancelled job is indistinguishable from a crashed one to the resume
        // planner, so the same path handles both.
        let reopened = try await ProjectStore().open(at: project.package.root)
        let resumeEngine = MockTranscriptionEngine()
        let transcript = try await JobRunner(engineFactory: { resumeEngine })
            .run(project: reopened, options: options)

        #expect(transcript.isMonotonic)
        #expect(!transcript.segments.isEmpty)

        // Chunks finished before the cancel were not transcribed a second time.
        let redone = await resumeEngine.startOrder
        for sequence in completedFirst {
            #expect(!redone.contains(sequence),
                    "chunk \(sequence) was already complete but ran again")
        }

        let finalRecords = try await reopened.store.loadChunkRecords()
        #expect(finalRecords.allSatisfy { !$0.state.isOutstanding })
        #expect(try await reopened.store.loadState() == .complete)
    }

    @Test("A cancelled job leaves no half-written artifacts")
    func noPartialArtifacts() async throws {
        let tmp = try TempDirectory()
        let project = try await makeProject(in: tmp)
        let engine = await slowEngine()

        let task = Task {
            try await JobRunner(engineFactory: { engine })
                .run(project: project, options: JobOptions())
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = try? await task.value

        // Every committed artifact is complete, because each was renamed into
        // place only after its bytes were durable.
        let fm = FileManager.default
        for name in Self.allFileNames(under: project.package.root) {
            #expect(!name.hasSuffix(".tmp"), "a temporary file survived cancellation: \(name)")
        }
        // Anything on disk must be readable, not truncated.
        if fm.fileExists(atPath: project.package.silenceMapURL.path) {
            _ = try AtomicFile.readJSON(SilenceMap.self, from: project.package.silenceMapURL)
        }
        if fm.fileExists(atPath: project.package.chunkPlanURL.path) {
            _ = try AtomicFile.readJSON(ChunkPlan.self, from: project.package.chunkPlanURL)
        }
    }
}

extension CancellationTests {
    /// Collects file names synchronously; directory enumeration is unavailable
    /// from an async context.
    nonisolated static func allFileNames(under root: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for case let url as URL in walker { names.append(url.lastPathComponent) }
        return names
    }
}

/// A one-shot async signal.
actor Signal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else { return }
        fired = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait(timeout: Duration) async throws {
        if fired { return }
        let deadline = ContinuousClock.now + timeout
        while !fired && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
