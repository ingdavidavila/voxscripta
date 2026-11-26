import Foundation

/// What went wrong, in a form a person can read before deciding to send it.
///
/// There is no telemetry in this application and there is not going to be. The
/// build ships without a network entitlement, the Android manifest declares no
/// `INTERNET` permission, and CI fails if a networking API is referenced — that
/// absence is the privacy claim, and a report the *app* transmits would dissolve
/// it however carefully the payload were filtered.
///
/// So the application writes a report and hands it to the person. They read it,
/// and they send it with their own mail or messaging app, or not at all. The
/// engine still cannot reach the network; the claim still holds; the report
/// still arrives.
///
/// ## What this deliberately does not contain
///
/// No transcript text, in any variant. No audio. No file contents of any kind.
/// Not the account email, which the engine never sees anyway.
///
/// And no paths, which is the part that needs saying rather than assuming: a
/// path carries the person's account name, and an audio file's name is often
/// the most identifying string in the whole system — "Entrevista con Marta.wav"
/// names a person who never agreed to appear in a bug report. Both are reduced
/// by ``redact(_:)`` to the shape that is diagnostic and nothing beyond it.
public struct DiagnosticsReport: Sendable, Equatable {

    public struct Failure: Sendable, Equatable {
        /// The stable `VoxScriptaError` code, never the rendered sentence: a
        /// code is the same in every language and names the case exactly.
        public let code: String
        /// The error's values, with paths reduced. Omitted entirely when the
        /// case carries nothing.
        public let details: [String: String]
        public let chunk: Int?

        public init(code: String, details: [String: String], chunk: Int? = nil) {
            self.code = code
            self.details = details
            self.chunk = chunk
        }
    }

    public let appVersion: String
    public let platform: String
    public let osVersion: String
    /// Which recogniser ran, as `EngineID`'s raw value.
    public let engine: String?
    public let modelIdentity: String?
    public let concurrency: Int?
    public let locale: String?
    public let jobState: String?
    public let chunksTotal: Int
    public let chunksComplete: Int
    public let chunksFailed: Int
    public let failures: [Failure]
    public let generatedAt: Date

    public init(
        appVersion: String = VoxScripta.version,
        platform: String = DiagnosticsReport.currentPlatform,
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        engine: String? = nil,
        modelIdentity: String? = nil,
        concurrency: Int? = nil,
        locale: String? = nil,
        jobState: String? = nil,
        chunksTotal: Int = 0,
        chunksComplete: Int = 0,
        chunksFailed: Int = 0,
        failures: [Failure] = [],
        generatedAt: Date = Date()
    ) {
        self.appVersion = appVersion
        self.platform = platform
        self.osVersion = osVersion
        self.engine = engine
        self.modelIdentity = modelIdentity
        self.concurrency = concurrency
        self.locale = locale
        self.jobState = jobState
        self.chunksTotal = chunksTotal
        self.chunksComplete = chunksComplete
        self.chunksFailed = chunksFailed
        self.failures = failures
        self.generatedAt = generatedAt
    }

    public static var currentPlatform: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(Android)
        "Android"
        #elseif os(Windows)
        "Windows"
        #elseif os(Linux)
        "Linux"
        #else
        "unknown"
        #endif
    }

    /// Reduces a value to what is diagnostic, dropping what identifies.
    ///
    /// A path becomes its extension: `/Users/marta/Interviews/Entrevista con
    /// Marta.wav` becomes `<path>.wav`. The extension is the part that explains
    /// a decoding failure; the rest names a person and their account.
    ///
    /// Applied to every value in a failure's details, because the error cases
    /// carrying a path — `sourceUnavailable`, `sourceChanged`, `noAudioTrack`,
    /// `ioFailure` — are exactly the ones a person reports.
    ///
    /// Conservative on purpose: anything containing a separator is treated as a
    /// path even if it is not one. A reason string that happens to hold a slash
    /// loses detail, and that is the right way for this to fail.
    public static func redact(_ value: String) -> String {
        guard value.contains("/") || value.contains("\\") else { return value }
        let name = value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let suffix = name.split(separator: ".").count > 1
            ? "." + (name.split(separator: ".").last.map(String.init) ?? "")
            : ""
        return "<path>" + suffix
    }

    /// The report as text, which is what the person reads and sends.
    ///
    /// Plain text rather than JSON: somebody has to be able to look at this and
    /// satisfy themselves it carries nothing of theirs, and that is harder in a
    /// single escaped line than in a list of labelled rows.
    public func formatted() -> String {
        var lines: [String] = []
        lines.append("Vox Scripta diagnostics")
        lines.append("")
        lines.append("Generated   \(ISO8601DateFormatter().string(from: generatedAt))")
        lines.append("App         \(appVersion)")
        lines.append("Platform    \(platform) \(osVersion)")
        if let engine { lines.append("Engine      \(engine)") }
        if let modelIdentity, !modelIdentity.isEmpty { lines.append("Model       \(modelIdentity)") }
        if let locale { lines.append("Locale      \(locale)") }
        if let concurrency { lines.append("Concurrency \(concurrency)") }
        if let jobState { lines.append("Job state   \(jobState)") }

        if chunksTotal > 0 {
            lines.append("Chunks      \(chunksComplete) of \(chunksTotal) complete"
                         + (chunksFailed > 0 ? ", \(chunksFailed) failed" : ""))
        }

        if failures.isEmpty {
            lines.append("")
            lines.append("No failures recorded.")
        } else {
            lines.append("")
            lines.append("Failures")
            for failure in failures {
                let where_ = failure.chunk.map { " (chunk \($0))" } ?? ""
                lines.append("  \(failure.code)\(where_)")
                for key in failure.details.keys.sorted() {
                    lines.append("    \(key): \(failure.details[key] ?? "")")
                }
            }
        }

        lines.append("")
        lines.append("Contains no transcript text, no audio, and no file paths.")
        lines.append("Nothing is sent by this app — you choose where this goes.")
        return lines.joined(separator: "\n")
    }
}

public extension DiagnosticsReport.Failure {
    /// Builds a failure from an error, reducing every value it carries.
    init(_ error: VoxScriptaError, chunk: Int? = nil) {
        self.init(code: error.code,
                  details: error.details.mapValues(DiagnosticsReport.redact),
                  chunk: chunk)
    }
}
