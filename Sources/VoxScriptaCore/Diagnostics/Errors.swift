import Foundation

/// The error taxonomy for the whole pipeline.
///
/// Errors are grouped by whether the caller can do anything about them, because
/// that is the distinction the scheduler needs: ``isRetryable`` decides whether
/// a failed chunk goes back into the queue or is marked permanently failed.
public enum VoxScriptaError: Error, Sendable, Equatable {

    // ── Source ──────────────────────────────────────────────────────────────
    /// The imported file is gone, or its security-scoped bookmark no longer resolves.
    case sourceUnavailable(path: String)
    /// The file exists but its content hash no longer matches the manifest.
    case sourceChanged(path: String)
    case unsupportedFormat(description: String)
    /// The container opened, but carries no audio — a silent video, typically.
    /// Distinct from ``unsupportedFormat`` because nothing is wrong with the file.
    case noAudioTrack(path: String)
    /// A container macOS has no demuxer for. The fix is to convert the file,
    /// so the error names the extension rather than a codec.
    case unsupportedContainer(fileExtension: String)
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
             .noAudioTrack, .unsupportedContainer,
             .analysisFailed, .noSpeechDetected, .localeUnsupported, .modelAssetMissing,
             .contextWindowExceeded, .validationRejected, .projectCorrupt, .schemaTooNew,
             .insufficientDiskSpace, .cancelled, .notImplemented:
            return false
        }
    }

    /// Whether this error should fail the entire job rather than a single work item.
    public var isFatalToJob: Bool {
        switch self {
        case .sourceUnavailable, .sourceChanged, .unsupportedFormat, .noAudioTrack,
             .unsupportedContainer, .projectCorrupt,
             .schemaTooNew, .insufficientDiskSpace:
            return true
        default:
            return false
        }
    }
}

extension VoxScriptaError: LocalizedError {
    /// Localized through `Bundle.main`, which is the app bundle at runtime.
    ///
    /// `String(localized:)` turns each interpolation into a format specifier
    /// when it builds the lookup key, so every value is converted to a `String`
    /// first and every specifier is therefore `%@`. Numbers go through
    /// `formatted()` on the way, which also gets them the right thousands
    /// separator for the reader's locale — "1.000" in Spanish, "1,000" in
    /// English.
    ///
    /// The CLI has no translations in its bundle and falls back to English,
    /// which is correct: a terminal is not localized by this app.
    /// Joins reasons for display, kept out of the interpolation on purpose.
    private static func list(_ reasons: [String]) -> String {
        reasons.joined(separator: "; ")
    }

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let path):
            String(localized: "The audio file could not be found at \(path).")
        case .sourceChanged(let path):
            String(localized: "The audio file at \(path) has changed since it was imported.")
        case .unsupportedFormat(let detail):
            String(localized: "This audio format is not supported: \(detail).")
        case .noAudioTrack(let path):
            String(localized: "“\(URL(filePath: path).lastPathComponent)” has no audio track, so there is nothing to transcribe.")
        case .unsupportedContainer(let fileExtension):
            String(localized: "macOS cannot read .\(fileExtension) files. Convert it to .mp4, .m4a or .wav first — a stream copy is enough, and costs no quality.")
        case .decodingFailed(let reason):
            String(localized: "The audio could not be decoded: \(reason).")
        case .analysisFailed(let stage, let reason):
            String(localized: "Audio analysis failed during \(stage): \(reason).")
        case .noSpeechDetected:
            String(localized: "No speech was detected in this recording.")
        case .engineUnavailable(let engine, let reason):
            String(localized: "The \(String(describing: engine)) engine is unavailable: \(reason).")
        case .localeUnsupported(let engine, let locale):
            String(localized: "The \(String(describing: engine)) engine does not support \(locale).")
        case .transcriptionFailed(let chunk, let reason):
            String(localized: "Chunk \(chunk.short) could not be transcribed: \(reason).")
        case .modelAssetMissing(let detail):
            String(localized: "A required model asset is missing: \(detail).")
        case .modelUnavailable(let model, let reason):
            String(localized: "The language model \(String(describing: model)) is unavailable: \(reason).")
        case .contextWindowExceeded(let tokens, let limit):
            String(localized: "Input of \(tokens.formatted()) tokens exceeds the \(limit.formatted())-token limit.")
        case .validationRejected(let reasons):
            // Joined outside the interpolation: a nested string literal inside
            // one hides the whole call from the key extractor, and the string
            // then ships untranslated looking deliberate.
            String(localized: "Polished output failed validation: \(Self.list(reasons)).")
        case .projectCorrupt(let reason):
            String(localized: "The project file is damaged: \(reason).")
        case .schemaTooNew(let found, let supported):
            String(localized: "This project was made by a newer version (schema \(found.formatted()), this app supports \(supported.formatted())).")
        case .insufficientDiskSpace(let needed, let available):
            String(localized: "Needs \(needed.formatted(.byteCount(style: .file))) of free space; \(available.formatted(.byteCount(style: .file))) available.")
        case .ioFailure(let path, let reason):
            String(localized: "Could not read or write \(path): \(reason).")
        case .cancelled:
            String(localized: "Processing was cancelled.")
        case .notImplemented(let what):
            String(localized: "Not implemented yet: \(what).")
        }
    }
}
