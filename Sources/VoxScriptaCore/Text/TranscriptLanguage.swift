import Foundation

/// A language the text stages know how to work in.
///
/// Distinct from the transcription locale, and deliberately coarser. The speech
/// engine cares that Mexican and Castilian Spanish are different models;
/// everything downstream — which sounds are fillers, which words negate, how a
/// rewrite is checked — is the same for both. So `es-MX` and `es-ES` map to one
/// case here, and the locale keeps its full identifier in the manifest.
///
/// The set is small on purpose. A language appears here only once its lexicons
/// exist and its validation has been measured, because the alternative is an
/// app that silently applies English rules to text that is not English. A
/// locale the engine can transcribe but this enum does not cover still works —
/// it produces a verbatim transcript and the text stages decline rather than
/// guess. See ``TranscriptLanguage/init(localeIdentifier:)``.
public enum TranscriptLanguage: String, Sendable, Codable, CaseIterable, Hashable {
    case english
    case spanish

    /// The language a BCP-47 identifier belongs to, or `nil` when the text
    /// stages have no lexicons for it.
    ///
    /// Returning `nil` rather than defaulting to English is the point. Running
    /// the English filler list over Portuguese would quietly delete real words.
    public init?(localeIdentifier: String) {
        let code = localeIdentifier
            .split(separator: "-", maxSplits: 1).first
            .map(String.init)?
            .lowercased()
        switch code {
        case "en": self = .english
        case "es": self = .spanish
        default: return nil
        }
    }

    /// The BCP-47 primary subtag.
    public var languageCode: String {
        switch self {
        case .english: "en"
        case .spanish: "es"
        }
    }

    /// Locales the app offers for this language, most common first.
    ///
    /// Intersected with what the engine actually supports before being shown;
    /// this list says which variants are worth offering, not which exist.
    public var offeredLocales: [String] {
        switch self {
        case .english: ["en-US", "en-GB", "en-AU", "en-CA", "en-IE", "en-IN", "en-NZ", "en-ZA"]
        case .spanish: ["es-ES", "es-MX", "es-US", "es-CL"]
        }
    }
}
