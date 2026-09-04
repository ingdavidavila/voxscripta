import Testing
import Foundation
import VoxVerbaCore
import VoxVerbaTestSupport
@testable import VoxVerbaProject

@Suite("Atomic file writes")
struct AtomicFileTests {

    @Test("A write either lands whole or not at all")
    func atomicity() throws {
        let tmp = try TempDirectory()
        let target = tmp.url.appending(path: "artifact.json")

        try AtomicFile.write(Data(repeating: 0xAB, count: 4096), to: target)
        #expect(try Data(contentsOf: target).count == 4096)

        // Overwriting replaces the whole file, never merges into it.
        try AtomicFile.write(Data(repeating: 0xCD, count: 16), to: target)
        let after = try Data(contentsOf: target)
        #expect(after.count == 16)
        #expect(after.allSatisfy { $0 == 0xCD })
    }

    @Test("No temporary files survive a successful write")
    func noLeftovers() throws {
        let tmp = try TempDirectory()
        for i in 0..<5 {
            try AtomicFile.write(Data("\(i)".utf8), to: tmp.url.appending(path: "f\(i).txt"))
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        #expect(!contents.contains { $0.hasSuffix(".tmp") })
        #expect(contents.count == 5)
    }

    @Test("JSON round-trips through an atomic write")
    func jsonRoundTrip() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "map.json")
        let map = SilenceMap(
            speechRegions: [SpeechRegion(range: TimeRange(start: .seconds(1), end: .seconds(5)),
                                         meanEnergyDB: -20, peakEnergyDB: -10)],
            gaps: [], noiseFloorProfile: [0.5], parameters: .default,
            parameterHash: "abc", sourceDuration: .seconds(10))

        try AtomicFile.writeJSON(map, to: url)
        let back = try AtomicFile.readJSON(SilenceMap.self, from: url)
        #expect(back.speechRegions.count == 1)
        #expect(back.parameterHash == "abc")
        #expect(back.sourceDuration == .seconds(10))
    }

    @Test("Corrupt JSON is reported as a damaged project, not a crash")
    func corruptJSON() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "bad.json")
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: VoxVerbaError.self) {
            _ = try AtomicFile.readJSON(SilenceMap.self, from: url)
        }
    }

    @Test("Content hashing is stable and distinguishes files")
    func hashing() throws {
        let tmp = try TempDirectory()
        let a = tmp.url.appending(path: "a.bin")
        let b = tmp.url.appending(path: "b.bin")
        try Data(repeating: 1, count: 3_000_000).write(to: a)   // spans several read blocks
        try Data(repeating: 2, count: 3_000_000).write(to: b)

        let first = try ContentHash.file(at: a)
        #expect(try ContentHash.file(at: a) == first)
        #expect(try ContentHash.file(at: b) != first)
        #expect(first.count == 64)
    }
}

@Suite("Job store")
struct JobStoreTests {

    @Test("State persists and reloads")
    func stateRoundTrip() async throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "job.sqlite")
        do {
            let store = try JobStore(url: url)
            try await store.setState(.transcribing)
            await store.close()
        }
        let reopened = try JobStore(url: url)
        #expect(try await reopened.loadState() == .transcribing)
    }

    @Test("Chunk records round-trip with all their fields")
    func chunkRoundTrip() async throws {
        let tmp = try TempDirectory()
        let store = try JobStore(url: tmp.url.appending(path: "job.sqlite"))
        var record = ChunkRecord(id: ChunkID(), sequence: 7, state: .completed, attempts: 2)
        record.lastError = "a transient failure"
        record.processingDuration = 1.25
        record.completedAt = Date(timeIntervalSince1970: 1_000_000)

        try await store.upsert(record)
        let loaded = try await store.loadChunkRecords()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == record.id)
        #expect(loaded[0].sequence == 7)
        #expect(loaded[0].state == .completed)
        #expect(loaded[0].attempts == 2)
        #expect(loaded[0].lastError == "a transient failure")
        #expect(loaded[0].processingDuration == 1.25)
    }

    @Test("Records load in sequence order regardless of write order")
    func ordering() async throws {
        let tmp = try TempDirectory()
        let store = try JobStore(url: tmp.url.appending(path: "job.sqlite"))
        for sequence in [5, 1, 9, 3, 0] {
            try await store.upsert(ChunkRecord(id: ChunkID(), sequence: sequence))
        }
        let loaded = try await store.loadChunkRecords()
        #expect(loaded.map(\.sequence) == [0, 1, 3, 5, 9])
    }

    @Test("Outstanding chunks are exactly the unfinished ones")
    func outstanding() async throws {
        let tmp = try TempDirectory()
        let store = try JobStore(url: tmp.url.appending(path: "job.sqlite"))
        let states: [ChunkState] = [.completed, .pending, .failedPermanent, .retryScheduled, .skipped]
        for (i, state) in states.enumerated() {
            try await store.upsert(ChunkRecord(id: ChunkID(), sequence: i, state: state))
        }
        let outstanding = try await store.outstandingChunks()
        #expect(Set(outstanding.map(\.sequence)) == [1, 3])
    }

    @Test("Chunks left in flight by a crash are reset, keeping their attempt count")
    func recoversInterrupted() async throws {
        let tmp = try TempDirectory()
        let store = try JobStore(url: tmp.url.appending(path: "job.sqlite"))
        try await store.upsert(ChunkRecord(id: ChunkID(), sequence: 0, state: .completed))
        try await store.upsert(ChunkRecord(id: ChunkID(), sequence: 1, state: .inFlight, attempts: 2))
        try await store.upsert(ChunkRecord(id: ChunkID(), sequence: 2, state: .retryScheduled, attempts: 1))

        let recovered = try await store.recoverInterruptedChunks()
        #expect(recovered == 2)

        let loaded = try await store.loadChunkRecords()
        #expect(loaded[0].state == .completed)
        #expect(loaded[1].state == .pending)
        // The attempt count survives, so a chunk that reliably kills the engine
        // is not retried forever across restarts.
        #expect(loaded[1].attempts == 2)
        #expect(loaded[2].state == .pending)
        #expect(loaded[2].attempts == 1)
    }

    @Test("Stage hashes persist and clear forward only")
    func stageHashes() async throws {
        let tmp = try TempDirectory()
        let store = try JobStore(url: tmp.url.appending(path: "job.sqlite"))
        for stage in StageKey.allCases {
            try await store.setStageHash(stage, to: "h-\(stage.rawValue)")
        }
        #expect(try await store.stageHash(.silence) == "h-silence")

        // Clearing from silence must invalidate silence and everything after it,
        // and leave decode and analyze alone — that is what saves the expensive
        // decode when a threshold changes.
        try await store.clearStageHashes(from: .silence)
        #expect(try await store.stageHash(.decode) == "h-decode")
        #expect(try await store.stageHash(.analyze) == "h-analyze")
        #expect(try await store.stageHash(.silence) == nil)
        #expect(try await store.stageHash(.chunking) == nil)
        #expect(try await store.stageHash(.transcription) == nil)
    }

    @Test("A committed chunk result is on disk before its row says so")
    func commitOrdering() async throws {
        let tmp = try TempDirectory()
        let store = try JobStore(url: tmp.url.appending(path: "job.sqlite"))
        let url = tmp.url.appending(path: "chunks/0001.json")
        let record = ChunkRecord(id: ChunkID(), sequence: 1, state: .completed)

        try await store.commitChunkResult(record, resultData: Data("result".utf8), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == Data("result".utf8))
        #expect(try await store.loadChunkRecords()[0].state == .completed)
    }

    @Test("Replacing the record set is all-or-nothing")
    func replaceIsTransactional() async throws {
        let tmp = try TempDirectory()
        let store = try JobStore(url: tmp.url.appending(path: "job.sqlite"))
        try await store.upsert(ChunkRecord(id: ChunkID(), sequence: 99))
        let fresh = (0..<5).map { ChunkRecord(id: ChunkID(), sequence: $0) }
        try await store.replaceChunkRecords(fresh)

        let loaded = try await store.loadChunkRecords()
        #expect(loaded.map(\.sequence) == [0, 1, 2, 3, 4])
        #expect(!loaded.contains { $0.sequence == 99 })
    }
}

@Suite("Stage invalidation")
struct StageInputsTests {

    private func inputs(
        source: String = "src",
        silence: SilenceParameters = .default,
        chunking: ChunkParameters = .default,
        concurrency: Int = 4
    ) -> StageInputs {
        StageInputs(sourceContentHash: source, frameGeometryDescription: "g",
                    silenceParameters: silence, chunkParameters: chunking,
                    engineID: .appleSpeech, locale: "en-US", concurrency: concurrency)
    }

    @Test("Hashes are stable across calls and processes")
    func stable() {
        // Swift's Hashable seeding is randomized per process, so anything built
        // on hashValue would invalidate every stage on every launch.
        let a = inputs(), b = inputs()
        for stage in StageKey.allCases {
            #expect(a.hash(for: stage) == b.hash(for: stage))
        }
    }

    @Test("Changing a silence parameter invalidates from silence onward, not before")
    func silenceChangeCascades() {
        var changed = SilenceParameters.default
        changed.marginDB += 2
        let before = inputs(), after = inputs(silence: changed)

        // The expensive decode and analysis survive.
        #expect(before.hash(for: .decode) == after.hash(for: .decode))
        #expect(before.hash(for: .analyze) == after.hash(for: .analyze))
        // Everything downstream is invalidated.
        #expect(before.hash(for: .silence) != after.hash(for: .silence))
        #expect(before.hash(for: .chunking) != after.hash(for: .chunking))
        #expect(before.hash(for: .transcription) != after.hash(for: .transcription))
        #expect(before.hash(for: .merge) != after.hash(for: .merge))
    }

    @Test("Changing chunk parameters leaves the silence map valid")
    func chunkChangeIsNarrower() {
        var changed = ChunkParameters.default
        changed.maxDuration = .seconds(120)
        let before = inputs(), after = inputs(chunking: changed)

        #expect(before.hash(for: .silence) == after.hash(for: .silence))
        #expect(before.hash(for: .chunking) != after.hash(for: .chunking))
    }

    @Test("Changing concurrency invalidates transcription")
    func concurrencyInvalidates() {
        // Engine output is not reproducible across concurrency values, so a
        // resumed job must not mix results produced at different settings.
        let before = inputs(concurrency: 1), after = inputs(concurrency: 4)
        #expect(before.hash(for: .chunking) == after.hash(for: .chunking))
        #expect(before.hash(for: .transcription) != after.hash(for: .transcription))
    }

    @Test("A different source invalidates everything")
    func sourceChangeInvalidatesAll() {
        let before = inputs(source: "a"), after = inputs(source: "b")
        for stage in StageKey.allCases {
            #expect(before.hash(for: stage) != after.hash(for: stage))
        }
    }
}
