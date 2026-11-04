import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaProject
import VoxScriptaTestSupport
@testable import VoxScriptaPipeline

/// The paywall where every interface meets it.
///
/// `JobRunner.run` is the one method the SwiftUI app, the CLI and the C ABI
/// all pass through. The wall first went into `vs_job_start` alone, which
/// left Mac and iPhone — the platforms that can actually ship — open, because
/// neither uses the C ABI. These tests pin the gate at the junction rather
/// than at one of the three doors.
@Suite("Entitlement gate")
struct EntitlementGateTests {

    /// A project over half a second of silence.
    ///
    /// Nothing here transcribes anything: the gate is meant to refuse before
    /// the audio is even resolved, and the cheapest proof of that is a job
    /// that would be trivial if it ever started.
    private func makeProject() async throws -> Project {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "voxscripta-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let audio = root.appending(path: "silence.wav")
        try AudioFileWriter.write(
            samples: [Float](repeating: 0, count: CanonicalFormat.sampleRate / 2),
            to: audio, format: .wav, sampleRate: CanonicalFormat.sampleRate)

        let decoder = CanonicalDecoder()
        return try await ProjectStore().create(
            from: audio,
            at: root.appending(path: "p.voxscripta"),
            chunking: .default,
            probe: { (try await decoder.probe(url: $0), try decoder.duration(of: $0)) })
    }

    private func store(startedDaysAgo days: Double) -> EntitlementStore {
        let store = EntitlementStore(location: FileManager.default.temporaryDirectory
            .appending(path: "voxscripta-gate-rec-\(UUID().uuidString)")
            .appending(path: "entitlement.json"))
        _ = store.state(now: Date().addingTimeInterval(-days * 86_400))
        return store
    }

    @Test("An expired trial refuses the job")
    func expiredTrialRefuses() async throws {
        let project = try await makeProject()
        let runner = JobRunner(gate: store(startedDaysAgo: 4))

        let thrown = await #expect(throws: VoxScriptaError.self) {
            try await runner.run(project: project)
        }
        guard case .notEntitled(let reason) = thrown else {
            Issue.record("expected notEntitled, got \(String(describing: thrown))")
            return
        }
        // The refusal has to say the existing work is still reachable, or the
        // user reasonably concludes it is gone.
        #expect(reason.contains("exported"))
    }

    @Test("A running trial lets the job start")
    func runningTrialAllows() async throws {
        let project = try await makeProject()
        let runner = JobRunner(gate: store(startedDaysAgo: 1))

        // It may still fail further on — half a second of silence has nothing
        // to transcribe — but it must not fail at the wall.
        do {
            _ = try await runner.run(project: project)
        } catch let error as VoxScriptaError {
            if case .notEntitled = error {
                Issue.record("the paywall refused a job inside the trial")
            }
        } catch {
            // Anything else is the pipeline's business, not this test's.
        }
    }

    @Test("A live subscription lets the job start long after the trial")
    func subscriptionAllows() async throws {
        let project = try await makeProject()
        let gate = store(startedDaysAgo: 90)
        _ = gate.record(subscription: .init(
            productID: "voxscripta.yearly",
            period: .yearly,
            expires: Date().addingTimeInterval(300 * 86_400)))

        do {
            _ = try await JobRunner(gate: gate).run(project: project)
        } catch let error as VoxScriptaError {
            if case .notEntitled = error {
                Issue.record("the paywall refused a paid-up subscriber")
            }
        } catch {}
    }

    @Test("The wall is checked before the source is resolved")
    func gateRunsBeforeTheSource() async throws {
        let project = try await makeProject()
        // Delete the audio out from under the project. If the gate ran after
        // the source was resolved, this would fail with sourceUnavailable
        // instead — and an expired user would be told their file was missing.
        let (sourceURL, release) = try project.resolveSource()
        release()
        try FileManager.default.removeItem(at: sourceURL)

        let thrown = await #expect(throws: VoxScriptaError.self) {
            try await JobRunner(gate: store(startedDaysAgo: 4)).run(project: project)
        }
        guard case .notEntitled = thrown else {
            Issue.record("expected the paywall, got \(String(describing: thrown))")
            return
        }
    }
}
