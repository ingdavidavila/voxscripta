import Foundation
import SQLite3
import VoxVerbaCore

/// Which pipeline stage a recorded input hash belongs to.
public enum StageKey: String, Sendable, CaseIterable {
    case decode
    case analyze
    case silence
    case chunking
    case transcription
    case merge
    case clean
    case polish
}

/// Durable job and chunk bookkeeping.
public protocol JobStoring: Sendable {
    func loadState() async throws -> JobState
    func setState(_ state: JobState) async throws

    func loadChunkRecords() async throws -> [ChunkRecord]
    func replaceChunkRecords(_ records: [ChunkRecord]) async throws
    func upsert(_ record: ChunkRecord) async throws
    func outstandingChunks() async throws -> [ChunkRecord]

    func stageHash(_ stage: StageKey) async throws -> String?
    func setStageHash(_ stage: StageKey, to hash: String) async throws
    func clearStageHashes(from stage: StageKey) async throws

    func commitChunkResult(_ record: ChunkRecord, resultData: Data, to url: URL) async throws
    func recoverInterruptedChunks() async throws -> Int
}

/// SQLite-backed job store.
///
/// Raw SQLite rather than an ORM: the schema is three tables and the access
/// pattern is a dozen statements, so a dependency would buy query building we do
/// not need while costing a fetch at build time. The project is otherwise
/// dependency-free and builds offline, which is worth preserving.
///
/// WAL mode is what makes a crash mid-write safe — an interrupted transaction
/// rolls back cleanly on the next open rather than leaving a torn database.
public actor JobStore: JobStoring {
    private let connection: SQLiteConnection
    private var db: OpaquePointer? { connection.handle }
    private let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        connection = try SQLiteConnection(path: url.path)
        guard let handle = connection.handle else {
            throw VoxVerbaError.ioFailure(path: url.path, reason: "could not open the job database")
        }

        // WAL for crash safety; FULL synchronous so a committed transaction is
        // durable. This database is written once per chunk, so the cost is
        // irrelevant next to the guarantee.
        try Self.exec(handle, """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = FULL;
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS job (
                id          INTEGER PRIMARY KEY CHECK (id = 1),
                state       TEXT    NOT NULL,
                updated_at  REAL    NOT NULL
            );
            CREATE TABLE IF NOT EXISTS chunks (
                id                  TEXT    PRIMARY KEY,
                sequence            INTEGER NOT NULL UNIQUE,
                state               TEXT    NOT NULL,
                attempts            INTEGER NOT NULL DEFAULT 0,
                last_error          TEXT,
                completed_at        REAL,
                processing_duration REAL
            );
            CREATE INDEX IF NOT EXISTS chunks_state ON chunks(state);
            CREATE TABLE IF NOT EXISTS stage_hashes (
                stage       TEXT PRIMARY KEY,
                input_hash  TEXT NOT NULL,
                completed_at REAL NOT NULL
            );
            INSERT OR IGNORE INTO job (id, state, updated_at) VALUES (1, 'imported', 0);
            """)
    }

    /// Closes the database. Also happens automatically when the store is released.
    public func close() { connection.close() }

    // MARK: - Job state

    public func loadState() throws -> JobState {
        let raw = try queryString("SELECT state FROM job WHERE id = 1")
        guard let raw, let state = JobState(rawValue: raw) else {
            throw VoxVerbaError.projectCorrupt(reason: "the job state is missing or unreadable")
        }
        return state
    }

    public func setState(_ state: JobState) throws {
        try run("UPDATE job SET state = ?, updated_at = ? WHERE id = 1") { stmt in
            Self.bind(stmt, 1, state.rawValue)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        }
    }

    // MARK: - Chunks

    public func loadChunkRecords() throws -> [ChunkRecord] {
        var out: [ChunkRecord] = []
        try query("""
            SELECT id, sequence, state, attempts, last_error, completed_at, processing_duration
            FROM chunks ORDER BY sequence
            """) { stmt in
            guard let record = Self.decodeChunk(stmt) else { return }
            out.append(record)
        }
        return out
    }

    public func replaceChunkRecords(_ records: [ChunkRecord]) throws {
        try transaction {
            try run("DELETE FROM chunks") { _ in }
            for record in records { try insertOrReplace(record) }
        }
    }

    public func upsert(_ record: ChunkRecord) throws {
        try insertOrReplace(record)
    }

    public func outstandingChunks() throws -> [ChunkRecord] {
        try loadChunkRecords().filter { $0.state.isOutstanding }
    }

    /// Resets chunks left mid-flight by a crash.
    ///
    /// A chunk still marked `inFlight` at open means the process died while
    /// transcribing it. Its attempt count is preserved deliberately: a chunk that
    /// reliably kills the engine must not be retried forever across restarts.
    ///
    /// - Returns: How many chunks were recovered.
    public func recoverInterruptedChunks() throws -> Int {
        let interrupted = try loadChunkRecords().filter {
            $0.state == .inFlight || $0.state == .retryScheduled
        }
        guard !interrupted.isEmpty else { return 0 }
        try transaction {
            for var record in interrupted {
                record.state = .pending
                try insertOrReplace(record)
            }
        }
        return interrupted.count
    }

    // MARK: - Stage hashes

    public func stageHash(_ stage: StageKey) throws -> String? {
        try queryString("SELECT input_hash FROM stage_hashes WHERE stage = '\(stage.rawValue)'")
    }

    public func setStageHash(_ stage: StageKey, to hash: String) throws {
        try run("INSERT OR REPLACE INTO stage_hashes (stage, input_hash, completed_at) VALUES (?, ?, ?)") { stmt in
            Self.bind(stmt, 1, stage.rawValue)
            Self.bind(stmt, 2, hash)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        }
    }

    /// Invalidates `stage` and everything downstream of it.
    public func clearStageHashes(from stage: StageKey) throws {
        guard let index = StageKey.allCases.firstIndex(of: stage) else { return }
        let doomed = StageKey.allCases[index...].map { "'\($0.rawValue)'" }.joined(separator: ",")
        try transaction {
            try run("DELETE FROM stage_hashes WHERE stage IN (\(doomed))") { _ in }
        }
    }

    // MARK: - Commit

    /// Writes a chunk's result and marks it complete.
    ///
    /// Order is load-bearing. The result file is written and flushed *first*, then
    /// the row is committed. A crash between the two leaves a file on disk whose
    /// row still says pending, so the chunk simply runs again and overwrites it —
    /// wasted work, but correct.
    ///
    /// The reverse order would be unsafe: a row claiming `completed` while the
    /// file is missing or truncated makes the merger read garbage, and no later
    /// stage could detect it.
    public func commitChunkResult(_ record: ChunkRecord, resultData: Data, to url: URL) throws {
        try AtomicFile.write(resultData, to: url)
        try insertOrReplace(record)
    }

    // MARK: - SQLite plumbing

    private func insertOrReplace(_ record: ChunkRecord) throws {
        try run("""
            INSERT OR REPLACE INTO chunks
                (id, sequence, state, attempts, last_error, completed_at, processing_duration)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """) { stmt in
            Self.bind(stmt, 1, record.id.rawValue.uuidString)
            sqlite3_bind_int64(stmt, 2, Int64(record.sequence))
            Self.bind(stmt, 3, record.state.rawValue)
            sqlite3_bind_int64(stmt, 4, Int64(record.attempts))
            if let error = record.lastError { Self.bind(stmt, 5, error) } else { sqlite3_bind_null(stmt, 5) }
            if let at = record.completedAt {
                sqlite3_bind_double(stmt, 6, at.timeIntervalSince1970)
            } else { sqlite3_bind_null(stmt, 6) }
            if let d = record.processingDuration {
                sqlite3_bind_double(stmt, 7, d)
            } else { sqlite3_bind_null(stmt, 7) }
        }
    }

    private static func decodeChunk(_ stmt: OpaquePointer) -> ChunkRecord? {
        guard let idText = sqlite3_column_text(stmt, 0),
              let uuid = UUID(uuidString: String(cString: idText)),
              let stateText = sqlite3_column_text(stmt, 2),
              let state = ChunkState(rawValue: String(cString: stateText))
        else { return nil }

        return ChunkRecord(
            id: ChunkID(rawValue: uuid),
            sequence: Int(sqlite3_column_int64(stmt, 1)),
            state: state,
            attempts: Int(sqlite3_column_int64(stmt, 3)),
            lastError: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            completedAt: sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            processingDuration: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 6))
    }

    private func transaction(_ body: () throws -> Void) throws {
        guard let db else { throw VoxVerbaError.projectCorrupt(reason: "the job store is closed") }
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            try body()
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let db else { throw VoxVerbaError.projectCorrupt(reason: "the job store is closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Self.error(db, "preparing a statement")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw Self.error(db, "executing a statement")
        }
    }

    private func query(_ sql: String, each: (OpaquePointer) -> Void) throws {
        guard let db else { throw VoxVerbaError.projectCorrupt(reason: "the job store is closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Self.error(db, "preparing a query")
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
    }

    private func queryString(_ sql: String) throws -> String? {
        var out: String?
        try query(sql) { stmt in
            if let text = sqlite3_column_text(stmt, 0) { out = String(cString: text) }
        }
        return out
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? "unknown SQLite failure"
            sqlite3_free(message)
            throw VoxVerbaError.projectCorrupt(reason: reason)
        }
    }

    private static func error(_ db: OpaquePointer, _ context: String) -> VoxVerbaError {
        .projectCorrupt(reason: "\(context): \(String(cString: sqlite3_errmsg(db)))")
    }

    /// Binds a string, copying it so the caller's storage need not outlive the step.
    private static func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        // SQLITE_TRANSIENT tells SQLite to take its own copy. Without it the
        // pointer can dangle before the statement runs.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }
}

/// Owns a SQLite handle and closes it exactly once.
///
/// A separate reference type because an actor's `deinit` is nonisolated and may
/// not touch its own non-Sendable state — so the handle needs an owner whose
/// lifetime the compiler can reason about independently.
private final class SQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK else {
            if let h { sqlite3_close_v2(h) }
            throw VoxVerbaError.ioFailure(path: path, reason: "could not open the job database")
        }
        handle = h
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    deinit { close() }
}
