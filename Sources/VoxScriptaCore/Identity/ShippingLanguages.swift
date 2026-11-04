import Foundation

/// The languages this version of Vox Scripta offers.
///
/// Both recognisers can do far more than this. Whisper's multilingual model
/// handles around a hundred languages and Apple's transcriber around thirty,
/// and until now the app offered whatever each one reported.
///
/// This narrows that to English and Spanish, and the reason is not the
/// recognisers — it is everything downstream of them. CLEAN's disfluency
/// lexicons exist for two languages. POLISH's ``ValidationGauntlet``, the
/// thing standing between a language model and a reversed meaning, has been
/// measured in two: 29 of 29 English corruptions caught, 20 of 20 Spanish.
/// The other thirty languages were offered on the strength of the recogniser
/// alone, with nothing measured behind them — a Greek transcript would have
/// been recognised competently and then polished by a validator that has
/// never been tested against Greek negation.
///
/// So this is a correctness boundary rather than a product one: ship what has
/// been measured. Widening it means extending the lexicons and the rejection
/// corpora first, and the measurement is the work, not the list.
///
/// - Note: It saves no space. Both models are single multilingual networks and
///   their weights do not separate by language, so dropping thirty languages
///   from the menu removes nothing from the download. See `Docs/PORTING.md`.
public enum ShippingLanguages {

    /// English first: it is the primary language and the one with the deeper
    /// corpus behind it.
    public static let locales: [String] = [
        "en-US", "en-GB", "es-ES", "es-MX", "es-419",
    ]

    public static let set: Set<String> = Set(locales)

    /// The two-letter codes, for a recogniser that names languages rather
    /// than locales.
    public static let languageCodes: Set<String> = ["en", "es"]

    /// Whether a locale is offered, matching on the language subtag.
    ///
    /// `es-AR` is Spanish and is accepted even though it is not in the list:
    /// refusing a Spanish speaker because their region is not one of three
    /// spellings would be pedantry, and the recogniser treats them alike.
    public static func includes(_ locale: String) -> Bool {
        languageCodes.contains(languageCode(of: locale))
    }

    public static func languageCode(of locale: String) -> String {
        String(locale.split(separator: "-").first ?? "").lowercased()
    }

    /// Narrows a recogniser's own list to what this version offers.
    public static func filter(_ reported: some Sequence<String>) -> Set<String> {
        Set(reported.filter(includes))
    }
}
