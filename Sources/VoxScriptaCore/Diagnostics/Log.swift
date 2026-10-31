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

    public func debug(_ message: @autoclosure () -> String) {}
    public func info(_ message: @autoclosure () -> String) {}
    public func notice(_ message: @autoclosure () -> String) {}
    public func warning(_ message: @autoclosure () -> String) {}
    public func error(_ message: @autoclosure () -> String) {}
    public func critical(_ message: @autoclosure () -> String) {}
    public func fault(_ message: @autoclosure () -> String) {}
    public func log(_ message: @autoclosure () -> String) {}
}
#endif
