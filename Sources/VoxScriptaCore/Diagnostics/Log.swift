#if canImport(OSLog)
import OSLog
#endif

/// Shared loggers, one per module.
///
/// Anything derived from user audio or transcript text is logged with the
/// `privacy: .private` qualifier so it never lands in a sysdiagnose. The §26
/// privacy claim has to hold for logs too.
///
/// `OSLog` exists only on Apple's platforms, so off them the ``Logger`` below
/// stands in for it. The substitute keeps the privacy promise the honest way:
/// it writes nothing at all. A logger that quietly lost its `.private`
/// qualifier on Linux would be worse than no logger, because every call site
/// would still read as though the guarantee held.
public enum Log {
    public static let subsystem = "com.voxscripta.app"

    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    public static let dsp = Logger(subsystem: subsystem, category: "dsp")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let language = Logger(subsystem: subsystem, category: "language")
    public static let project = Logger(subsystem: subsystem, category: "project")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let bench = Logger(subsystem: subsystem, category: "bench")
}

#if !canImport(OSLog)
/// What `OSLog.Logger` is, where there is no `OSLog`.
///
/// Silent on purpose rather than printing. The Apple implementation marks
/// user content `.private` so it never reaches a diagnostic report; a
/// substitute that printed the same calls would break that promise on exactly
/// the platforms least able to notice. Logging off Apple needs a destination
/// chosen deliberately, with the same split between public and private built
/// in — not a `print`.
public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}

    public func debug(_ message: LogMessage) {}
    public func info(_ message: LogMessage) {}
    public func notice(_ message: LogMessage) {}
    public func warning(_ message: LogMessage) {}
    public func error(_ message: LogMessage) {}
    public func critical(_ message: LogMessage) {}
    public func fault(_ message: LogMessage) {}
    public func log(_ message: LogMessage) {}
}

/// What `OSLogMessage` is, where there is no `OSLog`.
///
/// It exists so call sites keep their `privacy:` qualifiers on every platform.
/// The alternative — dropping them off Apple — would mean the same line read
/// `"\(reason, privacy: .public)"` on a Mac and `"\(reason)"` on Linux, and the
/// two would drift until a Mac build leaked user text into a sysdiagnose. So
/// the qualifier is part of the shared source and this type accepts it.
///
/// Nothing is stored. The interpolated values are never even evaluated, which
/// is the other half of the promise: an autoclosure that is never called cannot
/// put a transcript on a disk.
public struct LogMessage: ExpressibleByStringInterpolation, Sendable {

    /// How much of a value a real log would reveal. Mirrors `OSLogPrivacy`'s
    /// cases so the same spelling compiles here.
    public struct Privacy: Sendable {
        public static let `public` = Privacy()
        public static let `private` = Privacy()
        public static let sensitive = Privacy()
        public static let auto = Privacy()
    }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}

        public mutating func appendInterpolation<T>(
            _ value: @autoclosure () -> T, privacy: Privacy = .auto
        ) {}

        /// `OSLogMessage` has a `format:` overload for numbers. Accepted and
        /// discarded, so a formatted Apple log line still compiles here.
        public mutating func appendInterpolation<T>(
            _ value: @autoclosure () -> T, format: Any? = nil, privacy: Privacy = .auto
        ) {}
    }

    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}
#endif
