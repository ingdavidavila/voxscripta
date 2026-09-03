import Foundation
import VoxVerbaCore

/// Durable job and chunk bookkeeping.
///
/// Backed by SQLite in WAL mode so a chunk's result file and its state row commit
/// together and survive power loss. Phase 3 introduces GRDB; the protocol exists
/// now so the scheduler can be written against it.
public protocol JobStoring: Sendable {
    func loadState() async throws -> JobState
    func setState(_ state: JobState) async throws

    func loadChunkRecords() async throws -> [ChunkRecord]
    func upsert(_ record: ChunkRecord) async throws

    /// Chunks the scheduler still owes work for.
    func outstandingChunks() async throws -> [ChunkRecord]

    /// Commits a chunk's result file and its state row as one unit.
    func commitChunkResult(_ record: ChunkRecord, resultData: Data, to url: URL) async throws
}

/// Phase 3 implementation site.
public struct JobStore: JobStoring {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func loadState() async throws -> JobState {
        throw VoxVerbaError.notImplemented("JobStore.loadState — Phase 3")
    }
    public func setState(_ state: JobState) async throws {
        throw VoxVerbaError.notImplemented("JobStore.setState — Phase 3")
    }
    public func loadChunkRecords() async throws -> [ChunkRecord] {
        throw VoxVerbaError.notImplemented("JobStore.loadChunkRecords — Phase 3")
    }
    public func upsert(_ record: ChunkRecord) async throws {
        throw VoxVerbaError.notImplemented("JobStore.upsert — Phase 3")
    }
    public func outstandingChunks() async throws -> [ChunkRecord] {
        throw VoxVerbaError.notImplemented("JobStore.outstandingChunks — Phase 3")
    }
    public func commitChunkResult(_ record: ChunkRecord, resultData: Data, to url: URL) async throws {
        throw VoxVerbaError.notImplemented("JobStore.commitChunkResult — Phase 3")
    }
}
