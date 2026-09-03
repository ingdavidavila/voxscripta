import Foundation

/// The error taxonomy for the whole pipeline.
///
/// Errors are grouped by whether the caller can do anything about them, because
/// that is the distinction the scheduler needs: ``isRetryable`` decides whether
/// a failed chunk goes back into the queue or is marked permanently failed.
public enum VoxVerbaError: Error, Sendable, Equatable {

    // ── Source ──────────────────────────────────────────────────────────────
    /// The imported file is gone, or its security-scoped bookmark no longer resolves.
    case sourceUnavailable(path: String)
    /// The file exists but its content hash no longer matches the manifest.
    case sourceChanged(path: String)
    case unsupportedFormat(description: String)
    case decodingFailed(reason: String)

    // ── Analysis ────────────────────────────────────────────────────────────
    case analysisFailed(stage: String, reason: String)
    /// The detector found no speech at all. Not a crash — a result the UI must explain.
    case noSpeechDetected

    // ── Transcription ───────────────────────────────────────────────────────
    case engineUnavailable(EngineID, reason: String)
    case localeUnsupported(EngineID, locale: String)
    case transcriptionFailed(chunk: ChunkID, reason: String)
    case modelAssetMissing(description: String)

    // ── Language ────────────────────────────────────────────────────────────
    case modelUnavailable(ModelID, reason: String)
    case contextWindowExceeded(tokens: Int, limit: Int)
    /// Polish output failed the validation gauntlet twice; the window fell back to CLEAN.
    case validationRejected(reasons: [String])

    // ── Persistence ─────────────────────────────────────────────────────────
    case projectCorrupt(reason: String)
    case schemaTooNew(found: Int, supported: Int)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case ioFailure(path: String, reason: String)

    // ── Control flow ────────────────────────────────────────────────────────
    case cancelled
    /// A Phase 0 placeholder. Every occurrence is a scheduled implementation,
    /// not a silent failure — the message names the phase that fills it in.
    case notImplemented(String)

    /// Whether the scheduler should retry the operation that produced this error.
    ///
    /// Retrying a missing file or an unsupported format wastes time and hides the
    /// real problem; retrying a transient I/O or engine failure is often enough.
    public var isRetryable: Bool {
        switch self {
        case .transcriptionFailed, .ioFailure, .engineUnavailable, .modelUnavailable:
            return true
        case .sourceUnavailable, .sourceChanged, .unsupportedFormat, .decodingFailed,
             .analysisFailed, .noSpeechDetected, .localeUnsupported, .modelAssetMissing,
             .contextWindowExceeded, .validationRejected, .projectCorrupt, .schemaTooNew,
             .insufficientDiskSpace, .cancelled, .notImplemented:
            return false
        }
    }

    /// Whether this error should fail the entire job rather than a single work item.
    public var isFatalToJob: Bool {
        switch self {
        case .sourceUnavailable, .sourceChanged, .unsupportedFormat, .projectCorrupt,
             .schemaTooNew, .insufficientDiskSpace:
            return true
        default:
            return false
        }
    }
}

extension VoxVerbaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let p): "The audio file could not be found at \(p)."
        case .sourceChanged(let p): "The audio file at \(p) has changed since it was imported."
        case .unsupportedFormat(let d): "This audio format is not supported: \(d)."
        case .decodingFailed(let r): "The audio could not be decoded: \(r)."
        case .analysisFailed(let s, let r): "Audio analysis failed during \(s): \(r)."
        case .noSpeechDetected: "No speech was detected in this recording."
        case .engineUnavailable(let e, let r): "The \(e) engine is unavailable: \(r)."
        case .localeUnsupported(let e, let l): "The \(e) engine does not support \(l)."
        case .transcriptionFailed(let c, let r): "Chunk \(c.short) could not be transcribed: \(r)."
        case .modelAssetMissing(let d): "A required model asset is missing: \(d)."
        case .modelUnavailable(let m, let r): "The language model \(m) is unavailable: \(r)."
        case .contextWindowExceeded(let t, let l): "Input of \(t) tokens exceeds the \(l)-token limit."
        case .validationRejected(let r): "Polished output failed validation: \(r.joined(separator: "; "))."
        case .projectCorrupt(let r): "The project file is damaged: \(r)."
        case .schemaTooNew(let f, let s): "This project was made by a newer version (schema \(f), this app supports \(s))."
        case .insufficientDiskSpace(let n, let a): "Needs \(n) bytes of free space; \(a) available."
        case .ioFailure(let p, let r): "Could not read or write \(p): \(r)."
        case .cancelled: "Processing was cancelled."
        case .notImplemented(let what): "Not implemented yet: \(what)."
        }
    }
}
