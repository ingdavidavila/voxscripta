import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaProject
import VoxScriptaTestSupport
@testable import VoxScriptaPipeline

/// Drives the real CLI as a subprocess so crashes are real crashes.
///
/// Recovery cannot be verified in-process. Throwing an error unwinds cleanly and
/// runs `defer` blocks — precisely the case that already works. Only killing a
/// separate process with `SIGKILL` proves that what reached the disk beforehand
/// is enough to resume from.
struct CLI {
    static let binary: URL = {
        let fm = FileManager.default

        // Walk up from the running test executable; the CLI is built beside it.
        var directory = URL(filePath: ProcessInfo.processInfo.arguments[0])
        for _ in 0..<8 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appending(path: "voxscripta-cli")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        // Fall back to the package root, derived from this file's compile-time
        // path, and search the build directory for the current architecture.
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()   // VoxScriptaPipelineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let build = packageRoot.appending(path: ".build")
        if let entries = try? fm.contentsOfDirectory(atPath: build.path) {
            for entry in entries {
                for configuration in ["debug", "release"] {
                    let candidate = build.appending(path: entry)
                        .appending(path: configuration).appending(path: "voxscripta-cli")
                    if fm.isExecutableFile(atPath: candidate.path) { return candidate }
                }
            }
        }
        fatalError("could not locate voxscripta-cli; searched from \(ProcessInfo.processInfo.arguments[0]) and \(build.path)")
    }()

    /// Runs the CLI and returns its exit status.
    @discardableResult
    static func run(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

@Suite("Crash recovery", .serialized)
struct CrashRecoveryTests {

    /// Roughly 25 seconds of speech — long enough for several chunks.
    private func makeAudio(in directory: URL) async throws -> URL {
        let samples = try await SpeechCorpus.render(Array(SpeechCorpus.standard.prefix(4)))
        let url = directory.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: samples, to: url, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)
        return url
    }

    /// Concurrency 1 throughout: the engine is reproducible there, and these tests
    /// are about the pipeline's durability rather than the model's stability.
    private let baseArguments = ["--chunk-max", "12", "--concurrency", "1", "--quiet"]

    /// For tests that inspect scratch files, which cleanup removes by default.
    private var keepingIntermediates: [String] { baseArguments + ["--keep-intermediates"] }

    @Test("A clean run and a crash-then-resume produce the same transcript",
          arguments: ["decode", "analyze", "silence", "chunking", "merge", "clean", "polish"])
    func resumesFromEveryStage(crashStage: String) async throws {
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)

        let baseline = tmp.url.appending(path: "baseline.txt")
        let clean = tmp.url.appending(path: "clean.voxscripta")
        #expect(try CLI.run([
            "run", audio.path, "--project", clean.path, "--out", baseline.path,
        ] + baseArguments) == 0)

        let crashed = tmp.url.appending(path: "crashed.voxscripta")
        let status = try CLI.run([
            "run", audio.path, "--project", crashed.path, "--crash-at", crashStage,
        ] + baseArguments)
        // SIGKILL, not a clean exit.
        #expect(status != 0, "the run at \(crashStage) exited cleanly instead of crashing")

        let resumed = tmp.url.appending(path: "resumed.txt")
        #expect(try CLI.run([
            "run", "--project", crashed.path, "--out", resumed.path,
        ] + baseArguments) == 0)

        let expected = try String(contentsOf: baseline, encoding: .utf8)
        let actual = try String(contentsOf: resumed, encoding: .utf8)
        #expect(expected == actual, "resume after \(crashStage) diverged from the clean run")
        #expect(!expected.isEmpty)
    }

    @Test("Transcription resumes at the chunk that was in flight")
    func resumesMidTranscription() async throws {
        // §17's scenario: some chunks are done, one was interrupted, and the
        // completed ones must not be transcribed again.
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)

        let baseline = tmp.url.appending(path: "baseline.txt")
        let clean = tmp.url.appending(path: "clean.voxscripta")
        #expect(try CLI.run([
            "run", audio.path, "--project", clean.path, "--out", baseline.path,
        ] + baseArguments) == 0)

        let crashed = tmp.url.appending(path: "crashed.voxscripta")
        let status = try CLI.run([
            "run", audio.path, "--project", crashed.path,
            "--crash-at", "transcription", "--crash-after-chunks", "1",
        ] + baseArguments)
        #expect(status != 0)

        // Exactly one chunk should have been committed before the crash.
        let store = try JobStore(url: crashed.appending(path: "job.sqlite"))
        let records = try await store.loadChunkRecords()
        let completedBefore = records.filter { $0.state == .completed }
        #expect(completedBefore.count == 1, "expected one committed chunk, got \(completedBefore.count)")
        #expect(records.count > 1, "the test needs a plan with several chunks")
        await store.close()

        let resumed = tmp.url.appending(path: "resumed.txt")
        #expect(try CLI.run([
            "run", "--project", crashed.path, "--out", resumed.path,
        ] + baseArguments) == 0)

        let expectedText = try String(contentsOf: baseline, encoding: .utf8)
        let actualText = try String(contentsOf: resumed, encoding: .utf8)
        #expect(expectedText == actualText)
    }

    @Test("A completed project is not recomputed")
    func completedProjectIsCheap() async throws {
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)
        let project = tmp.url.appending(path: "p.voxscripta")
        let first = tmp.url.appending(path: "first.txt")
        let second = tmp.url.appending(path: "second.txt")

        #expect(try CLI.run(["run", audio.path, "--project", project.path,
                             "--out", first.path] + baseArguments) == 0)

        let started = ContinuousClock.now
        #expect(try CLI.run(["run", "--project", project.path,
                             "--out", second.path] + baseArguments) == 0)
        let elapsed = ContinuousClock.now - started

        let firstText = try String(contentsOf: first, encoding: .utf8)
        let secondText = try String(contentsOf: second, encoding: .utf8)
        #expect(firstText == secondText)
        // Reading a finished transcript back should be near-instant, not a
        // second pass over the audio.
        #expect(elapsed < .seconds(3), "a completed project re-ran work: \(elapsed)")
    }

    @Test("Changing a silence parameter reuses the decode but redoes the rest")
    func selectiveInvalidation() async throws {
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)
        let project = tmp.url.appending(path: "p.voxscripta")

        #expect(try CLI.run(["run", audio.path, "--project", project.path,
                             "--out", tmp.url.appending(path: "a.txt").path]
                            + keepingIntermediates) == 0)

        let canonical = project.appending(path: "Derived/canonical.f32")
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
        let decodedAt = attributes[.modificationDate] as! Date

        // Re-open with a different threshold by rewriting the manifest, which is
        // what a settings change does.
        let manifestURL = project.appending(path: "manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var silence = json["silenceParameters"] as! [String: Any]
        silence["marginDB"] = (silence["marginDB"] as! Double) + 3
        json["silenceParameters"] = silence
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        try await Task.sleep(for: .milliseconds(1100))   // filesystem timestamp resolution
        #expect(try CLI.run(["run", "--project", project.path,
                             "--out", tmp.url.appending(path: "b.txt").path]
                            + keepingIntermediates) == 0)

        // The expensive decode survived a threshold change; that is the whole
        // point of hashing stage inputs separately.
        let after = try FileManager.default.attributesOfItem(atPath: canonical.path)
        #expect((after[.modificationDate] as! Date) == decodedAt,
                "the canonical decode was redone for a silence-parameter change")
    }

    @Test("A source that changed on disk forces a full rebuild")
    func sourceChangeRebuilds() async throws {
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)
        let project = tmp.url.appending(path: "p.voxscripta")
        #expect(try CLI.run(["run", audio.path, "--project", project.path,
                             "--out", tmp.url.appending(path: "a.txt").path] + baseArguments) == 0)

        // Replace the audio with different content at the same path.
        let other = try await SpeechCorpus.render([SpeechCorpus.standard[4]])
        try AudioFileWriter.write(samples: other, to: audio, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        let out = tmp.url.appending(path: "b.txt")
        #expect(try CLI.run(["run", "--project", project.path, "--out", out.path] + baseArguments) == 0)

        // The transcript must reflect the new audio, not the stale derived data.
        let text = try String(contentsOf: out, encoding: .utf8).lowercased()
        #expect(text.contains("fox") || text.contains("dog"),
                "stale derived data survived a source change: \(text.prefix(120))")
    }
}

/// §5: intermediates are reclaimed automatically, and reclaiming must not cost
/// anything except disk space.
@Suite("Intermediate cleanup", .serialized)
struct CleanupTests {

    private func makeAudio(in directory: URL) async throws -> URL {
        let samples = try await SpeechCorpus.render(Array(SpeechCorpus.standard.prefix(3)))
        let url = directory.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: samples, to: url, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)
        return url
    }

    private let arguments = ["--chunk-max", "12", "--concurrency", "1", "--quiet"]

    @Test("A finished job reclaims its scratch files")
    func reclaimsAfterCompletion() async throws {
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)
        let project = tmp.url.appending(path: "p.voxscripta")
        #expect(try CLI.run(["run", audio.path, "--project", project.path] + arguments) == 0)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: project.appending(path: "Derived").path),
                "scratch audio survived a completed job")
        // The results and the original are untouched.
        #expect(fm.fileExists(atPath: project.appending(path: "Output/clean.txt").path))
        #expect(fm.fileExists(atPath: project.appending(path: "manifest.json").path))
        #expect(fm.fileExists(atPath: audio.path))
    }

    @Test("Keeping intermediates is respected")
    func keepsWhenAsked() async throws {
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)
        let project = tmp.url.appending(path: "p.voxscripta")
        #expect(try CLI.run(["run", audio.path, "--project", project.path,
                             "--keep-intermediates"] + arguments) == 0)
        #expect(FileManager.default.fileExists(
            atPath: project.appending(path: "Derived/canonical.f32").path))
    }

    @Test("A reclaimed project reopens without re-running anything")
    func reclaimedProjectStaysComplete() async throws {
        // The trap this whole change had to avoid: the resume planner used to
        // check derived artifacts before checking completion, so a cleaned
        // project looked unfinished and re-transcribed from scratch — turning a
        // storage saving into a full re-run.
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)
        let project = tmp.url.appending(path: "p.voxscripta")
        let first = tmp.url.appending(path: "first.txt")
        let second = tmp.url.appending(path: "second.txt")

        #expect(try CLI.run(["run", audio.path, "--project", project.path,
                             "--out", first.path] + arguments) == 0)
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: "Derived").path))

        let started = ContinuousClock.now
        #expect(try CLI.run(["run", "--project", project.path,
                             "--out", second.path] + arguments) == 0)
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(3), "a reclaimed project re-ran work: \(elapsed)")
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: "Derived").path),
                "reopening regenerated scratch files it did not need")

        let a = try String(contentsOf: first, encoding: .utf8)
        let b = try String(contentsOf: second, encoding: .utf8)
        #expect(a == b)
    }

    @Test("The clean command reclaims an existing project")
    func cleanCommand() async throws {
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)
        let project = tmp.url.appending(path: "p.voxscripta")
        #expect(try CLI.run(["run", audio.path, "--project", project.path,
                             "--keep-intermediates"] + arguments) == 0)
        #expect(FileManager.default.fileExists(atPath: project.appending(path: "Derived").path))

        #expect(try CLI.run(["clean", "--project", project.path]) == 0)
        #expect(!FileManager.default.fileExists(atPath: project.appending(path: "Derived").path))
        #expect(FileManager.default.fileExists(atPath: project.appending(path: "Output/clean.txt").path))
    }

    @Test("Reopening a project does not re-transcribe it")
    func reopeningIsStable() async throws {
        // Locale and concurrency live in the manifest for this reason: taking
        // them from ambient defaults meant simply reopening a project built at a
        // different setting invalidated its transcription.
        let tmp = try TempDirectory()
        let audio = try await makeAudio(in: tmp.url)
        let project = tmp.url.appending(path: "p.voxscripta")
        #expect(try CLI.run(["run", audio.path, "--project", project.path,
                             "--concurrency", "1"] + ["--chunk-max", "12", "--quiet"]) == 0)

        // Reopened with no flags at all, so the defaults differ from the build.
        let started = ContinuousClock.now
        #expect(try CLI.run(["run", "--project", project.path, "--quiet"]) == 0)
        #expect(ContinuousClock.now - started < .seconds(3),
                "reopening with default flags re-transcribed the project")
    }
}
