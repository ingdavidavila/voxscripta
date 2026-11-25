import Foundation

/// The machine-readable half of an error, for interfaces that must say it in
/// a language the engine does not speak.
///
/// `errorDescription` renders an English sentence and, on Apple's platforms,
/// looks it up in the app bundle's tables to return Spanish. There is no such
/// lookup off Apple: `String(localized:)` is not in swift-corelibs-foundation,
/// and this project shims it to the identity function — see
/// `Diagnostics/Localization.swift`. So a Spanish Flutter interface on Android
/// showed Spanish chrome around English engine errors.
///
/// Translating inside the engine cannot work as the code is written. By the
/// time the shim sees the string, every interpolation has already been
/// substituted, so "The audio file at /a.wav has changed" can no longer be
/// looked up in a table keyed on "The audio file at %@ has changed". The key
/// is gone before the shim is reached.
///
/// So the interface translates instead, which is what the note in
/// `Localization.swift` has always recommended: the engine reports *what
/// happened* and the values involved, and whoever knows the reader's language
/// writes the sentence. ``code`` is the case and ``details`` are its
/// associated values, unformatted — digits stay digits, because the thousands
/// separator belongs to the reader's locale and not to ours.
public extension VoxScriptaError {

    /// A stable identifier for the case.
    ///
    /// This is a wire contract: an interface maps it to a sentence, so
    /// renaming one silently drops that translation back to English. The
    /// switch is exhaustive on purpose — adding a case to the enum will not
    /// compile until it is given a code here, which is the only way to keep a
    /// new error from shipping untranslatable.
    var code: String {
        switch self {
        case .sourceUnavailable: "sourceUnavailable"
        case .sourceChanged: "sourceChanged"
        case .unsupportedFormat: "unsupportedFormat"
        case .noAudioTrack: "noAudioTrack"
        case .unsupportedContainer: "unsupportedContainer"
        case .decodingFailed: "decodingFailed"
        case .noWordsRecognized: "noWordsRecognized"
        case .microphoneDenied: "microphoneDenied"
        case .recordingFailed: "recordingFailed"
        case .analysisFailed: "analysisFailed"
        case .noSpeechDetected: "noSpeechDetected"
        case .engineUnavailable: "engineUnavailable"
        case .localeUnsupported: "localeUnsupported"
        case .transcriptionFailed: "transcriptionFailed"
        case .modelAssetMissing: "modelAssetMissing"
        case .modelUnavailable: "modelUnavailable"
        case .contextWindowExceeded: "contextWindowExceeded"
        case .validationRejected: "validationRejected"
        case .projectCorrupt: "projectCorrupt"
        case .schemaTooNew: "schemaTooNew"
        case .insufficientDiskSpace: "insufficientDiskSpace"
        case .ioFailure: "ioFailure"
        case .notEntitled: "notEntitled"
        case .cancelled: "cancelled"
        case .notImplemented: "notImplemented"
        }
    }

    /// The case's associated values, keyed by their label.
    ///
    /// Numbers are plain digits rather than `formatted()`: this is data for an
    /// interface to format, and formatting it here would impose this process's
    /// locale on a reader whose language the interface already knows better.
    var details: [String: String] {
        switch self {
        case .sourceUnavailable(let path): ["path": path]
        case .sourceChanged(let path): ["path": path]
        case .unsupportedFormat(let description): ["description": description]
        case .noAudioTrack(let path): ["path": path]
        case .unsupportedContainer(let fileExtension): ["fileExtension": fileExtension]
        case .decodingFailed(let reason): ["reason": reason]
        case .noWordsRecognized(let locale): ["locale": locale]
        case .microphoneDenied: [:]
        case .recordingFailed(let reason): ["reason": reason]
        case .analysisFailed(let stage, let reason): ["stage": stage, "reason": reason]
        case .noSpeechDetected: [:]
        case .engineUnavailable(let engine, let reason):
            ["engine": String(describing: engine), "reason": reason]
        case .localeUnsupported(let engine, let locale):
            ["engine": String(describing: engine), "locale": locale]
        case .transcriptionFailed(let chunk, let reason):
            ["chunk": chunk.short, "reason": reason]
        case .modelAssetMissing(let description): ["description": description]
        case .modelUnavailable(let model, let reason):
            ["model": String(describing: model), "reason": reason]
        case .contextWindowExceeded(let tokens, let limit):
            ["tokens": String(tokens), "limit": String(limit)]
        case .validationRejected(let reasons): ["reasons": reasons.joined(separator: "; ")]
        case .projectCorrupt(let reason): ["reason": reason]
        case .schemaTooNew(let found, let supported):
            ["found": String(found), "supported": String(supported)]
        case .insufficientDiskSpace(let needed, let available):
            ["needed": String(needed), "available": String(available)]
        case .ioFailure(let path, let reason): ["path": path, "reason": reason]
        case .notEntitled(let reason): ["reason": reason]
        case .cancelled: [:]
        case .notImplemented(let detail): ["detail": detail]
        }
    }
}
