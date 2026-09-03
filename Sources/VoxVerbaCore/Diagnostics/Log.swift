import OSLog

/// Shared loggers, one per module.
///
/// Anything derived from user audio or transcript text is logged with the
/// `privacy: .private` qualifier so it never lands in a sysdiagnose. The §26
/// privacy claim has to hold for logs too.
public enum Log {
    public static let subsystem = "com.voxverba.app"

    public static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    public static let dsp = Logger(subsystem: subsystem, category: "dsp")
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    public static let language = Logger(subsystem: subsystem, category: "language")
    public static let project = Logger(subsystem: subsystem, category: "project")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let bench = Logger(subsystem: subsystem, category: "bench")
}
