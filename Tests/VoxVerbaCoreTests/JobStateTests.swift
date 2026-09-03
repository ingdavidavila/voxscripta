import Testing
import Foundation
@testable import VoxVerbaCore

@Suite("Job state machine")
struct JobStateTests {

    @Test("The pipeline chains from imported to complete")
    func pipelineChain() {
        var state = JobState.imported
        var visited: [JobState] = [state]
        while let next = state.successor {
            #expect(state.canTransition(to: next))
            state = next
            visited.append(state)
        }
        #expect(state == .complete)
        #expect(visited == [
            .imported, .analyzing, .silenceProcessing, .chunking,
            .transcribing, .merging, .cleaning, .polishing, .complete,
        ])
    }

    @Test("Skipping a phase is illegal")
    func noSkipping() {
        #expect(!JobState.imported.canTransition(to: .transcribing))
        #expect(!JobState.chunking.canTransition(to: .polishing))
        #expect(!JobState.analyzing.canTransition(to: .complete))
    }

    @Test("Failure and cancellation are legal from any working state")
    func abortAlwaysLegal() {
        for state in JobState.pipeline {
            #expect(state.canTransition(to: .failed))
            #expect(state.canTransition(to: .cancelled))
        }
    }

    @Test("Re-entering the current state is legal, because resume restarts a phase")
    func reentry() {
        for state in JobState.pipeline {
            #expect(state.canTransition(to: state))
        }
    }

    @Test("Terminal states go nowhere")
    func terminalIsFinal() {
        for state in [JobState.complete, .failed, .cancelled] {
            #expect(state.isTerminal)
            #expect(state.successor == nil)
            for other in JobState.allCases {
                #expect(!state.canTransition(to: other))
            }
        }
    }

    @Test("Nominal progress is monotonic across the pipeline")
    func progressMonotonic() {
        let values = JobState.pipeline.map(\.nominalProgress) + [JobState.complete.nominalProgress]
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }
}

@Suite("Chunk records")
struct ChunkRecordTests {

    @Test("Outstanding states are exactly the ones the scheduler still owes work for")
    func outstanding() {
        #expect(ChunkState.pending.isOutstanding)
        #expect(ChunkState.inFlight.isOutstanding)
        #expect(ChunkState.retryScheduled.isOutstanding)
        #expect(!ChunkState.completed.isOutstanding)
        #expect(!ChunkState.failedPermanent.isOutstanding)
        #expect(!ChunkState.skipped.isOutstanding)
    }

    @Test("Retry budget is enforced")
    func retryBudget() {
        var r = ChunkRecord(id: ChunkID(), sequence: 0)
        #expect(r.canRetry(maxAttempts: 3))
        r.attempts = 3
        #expect(!r.canRetry(maxAttempts: 3))
    }
}

@Suite("Job progress")
struct JobProgressTests {

    @Test("Overall progress interpolates within the current phase")
    func interpolation() {
        let start = JobProgress(state: .transcribing, phaseProgress: 0)
        let mid = JobProgress(state: .transcribing, phaseProgress: 0.5)
        let end = JobProgress(state: .transcribing, phaseProgress: 1)
        #expect(start.overallProgress == JobState.transcribing.nominalProgress)
        #expect(end.overallProgress == JobState.merging.nominalProgress)
        #expect(mid.overallProgress > start.overallProgress)
        #expect(mid.overallProgress < end.overallProgress)
    }

    @Test("Phase progress is clamped rather than trusted")
    func clamped() {
        #expect(JobProgress(state: .analyzing, phaseProgress: 5).phaseProgress == 1)
        #expect(JobProgress(state: .analyzing, phaseProgress: -5).phaseProgress == 0)
    }

    @Test("Terminal states report a fixed overall progress")
    func terminal() {
        #expect(JobProgress(state: .complete, phaseProgress: 0).overallProgress == 1)
        #expect(JobProgress(state: .failed, phaseProgress: 1).overallProgress == 0)
        #expect(JobProgress(state: .cancelled, phaseProgress: 1).overallProgress == 0)
    }
}
