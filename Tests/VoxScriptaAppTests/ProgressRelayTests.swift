import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaPipeline
@testable import VoxScriptaApp

/// The mechanism behind "the UI never looks frozen".
///
/// A six-hour job reports progress far faster than a person can read it — every
/// chunk, every buffer. Dispatching each one to the main actor would spend the
/// UI's time laying out the same label instead of drawing. These tests pin the
/// coalescing that prevents it.
@Suite("Progress coalescing")
struct ProgressRelayTests {

    private func report(_ fraction: Double, _ state: JobState = .transcribing) -> JobProgressReport {
        JobProgressReport(state: state, fraction: fraction, detail: "working")
    }

    @Test("A burst of reports is collapsed")
    func collapsesBurst() async throws {
        let delivered = Counter()
        let relay = ProgressRelay(interval: .milliseconds(50)) { _ in delivered.increment() }

        // A thousand reports as fast as the pipeline could produce them.
        for i in 0..<1000 { relay.send(report(Double(i) / 1000)) }

        // Far fewer than a thousand reach the UI.
        let count = delivered.value
        #expect(count < 20, "delivered \(count) of 1000 reports")
        #expect(count >= 1, "nothing was delivered at all")
    }

    @Test("Reports resume after the interval elapses")
    func deliversAfterInterval() async throws {
        let delivered = Counter()
        let relay = ProgressRelay(interval: .milliseconds(30)) { _ in delivered.increment() }

        relay.send(report(0.1))
        try await Task.sleep(for: .milliseconds(60))
        relay.send(report(0.2))
        try await Task.sleep(for: .milliseconds(60))
        relay.send(report(0.3))

        #expect(delivered.value == 3)
    }

    @Test("Completion is never dropped")
    func completionAlwaysDelivered() {
        // Throttling must not swallow the report that says the job finished, or
        // the UI would sit at 97% forever.
        let received = Box<[Double]>([])
        let relay = ProgressRelay(interval: .seconds(10)) { r in received.mutate { $0.append(r.fraction) } }

        relay.send(report(0.5))          // delivered: first send
        relay.send(report(0.6))          // throttled
        relay.send(report(1.0, .complete))   // must arrive despite the throttle

        #expect(received.value.contains(1.0))
    }

    @Test("Terminal states are never dropped")
    func terminalStatesDelivered() {
        let received = Box<[JobState]>([])
        let relay = ProgressRelay(interval: .seconds(10)) { r in received.mutate { $0.append(r.state) } }

        relay.send(report(0.2))
        relay.send(report(0.3, .cancelled))
        relay.send(report(0.3, .failed))

        #expect(received.value.contains(.cancelled))
        #expect(received.value.contains(.failed))
    }

    @Test("Sending from many threads at once is safe")
    func concurrentSends() async {
        let delivered = Counter()
        let relay = ProgressRelay(interval: .milliseconds(1)) { _ in delivered.increment() }

        // The scheduler reports from whichever task finishes a chunk, so this is
        // the real access pattern rather than a synthetic stress test.
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<200 {
                        relay.send(JobProgressReport(
                            state: .transcribing,
                            fraction: Double(i) / 200, detail: "worker \(worker)"))
                    }
                }
            }
        }
        #expect(delivered.value > 0)
    }
}

/// Thread-safe counter for the callbacks above.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Thread-safe box.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&storage); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
}
