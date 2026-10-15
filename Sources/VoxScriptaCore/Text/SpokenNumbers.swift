import Foundation

/// Canonicalizes numbers written as words into digits.
///
/// Speech engines normalize aggressively: "five hundred" comes back as "500" and
/// "third" as "3rd". Two parts of VoxScripta have to see through that.
///
/// Word error rate would otherwise count a correct transcription as three errors
/// for writing the number the way people write numbers. And the polish
/// validator's numeric-conservation check (§14) has to recognize that "500" and
/// "five hundred" are the same quantity while "1,000" is not — which is exactly
/// the transformation that must be caught.
public enum SpokenNumbers {

    // MARK: - Spanish
    //
    // Not a translation of the English tables. Spanish builds numbers
    // differently in three ways that matter here.
    //
    // The hundreds are distinct words rather than "two" plus "hundred", so
    // doscientos is 200 outright and belongs with the additive values, not
    // with the multiplicative scales.
    //
    // Sixteen to twenty-nine are single words — dieciséis, veintitrés — where
    // English compounds, so they sit in the units table.
    //
    // "y" joins tens to units and nothing else: "treinta y cuatro" but never
    // "ciento y veinte". The parser enforces that rather than accepting the
    // connector anywhere, which also stops the ordinary conjunction in "cinco
    // y dos" from reading as seven.

    private static let spanishUnits: [String: Int] = [
        "cero": 0, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5,
        "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10, "once": 11,
        "doce": 12, "trece": 13, "catorce": 14, "quince": 15,
        "dieciséis": 16, "dieciseis": 16, "diecisiete": 17, "dieciocho": 18,
        "diecinueve": 19, "veinte": 20,
        "veintiuno": 21, "veintiún": 21, "veintiun": 21, "veintiuna": 21,
        "veintidós": 22, "veintidos": 22, "veintitrés": 23, "veintitres": 23,
        "veinticuatro": 24, "veinticinco": 25, "veintiséis": 26, "veintiseis": 26,
        "veintisiete": 27, "veintiocho": 28, "veintinueve": 29,
        // The hundreds, additive rather than scaled.
        "cien": 100, "ciento": 100, "doscientos": 200, "doscientas": 200,
        "trescientos": 300, "trescientas": 300, "cuatrocientos": 400,
        "cuatrocientas": 400, "quinientos": 500, "quinientas": 500,
        "seiscientos": 600, "seiscientas": 600, "setecientos": 700,
        "setecientas": 700, "ochocientos": 800, "ochocientas": 800,
        "novecientos": 900, "novecientas": 900,
    ]

    private static let spanishTens: [String: Int] = [
        "treinta": 30, "cuarenta": 40, "cincuenta": 50,
        "sesenta": 60, "setenta": 70, "ochenta": 80, "noventa": 90,
    ]

    private static let spanishScales: [String: Int] = [
        "mil": 1_000, "millón": 1_000_000, "millon": 1_000_000,
        "millones": 1_000_000,
    ]

    /// Spanish ordinals, with two words deliberately absent.
    ///
    /// "segundo" and "segunda" are the ordinal *and* the unit of time, and
    /// "treinta segundos" is far commoner in a transcript than "the second
    /// item". Folding them to 2 would turn a duration into a count, so they
    /// are left as words. The same collision exists in English with "second",
    /// where the table does include it; that is a known quirk kept as it is
    /// because changing it would move every WER baseline and golden file.
    private static let spanishOrdinals: [String: Int] = [
        "primero": 1, "primer": 1, "primera": 1,
        "tercero": 3, "tercer": 3, "tercera": 3,
        "cuarto": 4, "cuarta": 4, "quinto": 5, "quinta": 5,
        "sexto": 6, "sexta": 6, "séptimo": 7, "septimo": 7, "séptima": 7,
        "octavo": 8, "octava": 8, "noveno": 9, "novena": 9,
        "décimo": 10, "decimo": 10, "décima": 10,
        "undécimo": 11, "undecimo": 11, "duodécimo": 12, "duodecimo": 12,
        "vigésimo": 20, "vigesimo": 20, "trigésimo": 30, "trigesimo": 30,
        "cuadragésimo": 40, "quincuagésimo": 50, "sexagésimo": 60,
        "septuagésimo": 70, "octogésimo": 80, "nonagésimo": 90,
        "centésimo": 100, "centesimo": 100, "milésimo": 1_000,
    ]

    /// "un" and "una" are the indefinite article before they are the numeral,
    /// and "un informe" must not become "1 informe". They count as one only
    /// directly before a scale word, which is the one place the article cannot
    /// appear: "un millón", "veintiún mil".
    private static let spanishArticleNumerals: Set<String> = ["un", "una", "uno"]

    /// Ordinal markers that survive tokenization as separate tokens, as in
    /// "1.º" splitting into "1" and "º".
    private static let ordinalMarkers: Set<String> = ["º", "ª", "°", "er", "os", "as"]

    // MARK: - English

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    /// Ordinal words mapped to their cardinal value.
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1_000,
    ]

    /// Rewrites runs of number words into a single digit token.
    ///
    /// - Parameter tokens: Lower-cased, punctuation-stripped words.
    public static func canonicalize(_ tokens: [String],
                                    in language: TranscriptLanguage = .english) -> [String] {
        var out: [String] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            // A token already written in digits: strip separators and any
            // ordinal suffix so "3rd", "3" and "third" all land on "3".
            if let digits = numericValue(of: token) {
                out.append(digits)
                index += 1
                // Spanish writes ordinals as "1.º" and "3.er", which the
                // tokenizer splits before the suffix stripper ever sees them.
                // The marker is dropped here instead, where the digit it
                // belongs to is still in view.
                if language == .spanish, index < tokens.count,
                   ordinalMarkers.contains(tokens[index]) {
                    index += 1
                }
                continue
            }

            if let (value, consumed) = parseNumberRun(tokens, from: index, language: language) {
                out.append(String(value))
                index += consumed
                continue
            }

            out.append(token)
            index += 1
        }
        return out
    }

    /// The canonical digit string for an already-numeric token, or `nil`.
    private static func numericValue(of token: String) -> String? {
        var body = token.replacingOccurrences(of: ",", with: "")
        // Spanish writes ordinals as 1.º, 2.ª, 3.er. The masculine and feminine
        // markers are stripped whole; the bare letters "o" and "a" are not,
        // because stripping those would eat real words.
        for marker in ["º", "ª", "°"] where body.hasSuffix(marker) {
            body = String(body.dropLast())
        }
        if body.hasSuffix("er"), body.dropLast(2).allSatisfy(\.isNumber) {
            body = String(body.dropLast(2))
        }
        body = body.replacingOccurrences(of: ".", with: "")
        for suffix in ["st", "nd", "rd", "th"] where body.hasSuffix(suffix) {
            let stem = String(body.dropLast(2))
            if !stem.isEmpty, stem.allSatisfy(\.isNumber) { body = stem }
        }
        guard !body.isEmpty, body.allSatisfy(\.isNumber) else { return nil }
        // Drop leading zeros without turning "0" into "".
        let trimmed = String(body.drop { $0 == "0" })
        return trimmed.isEmpty ? "0" : trimmed
    }

    /// Parses a run of number words starting at `start`.
    ///
    /// - Returns: The value and how many tokens it consumed, or `nil` when the
    ///   token at `start` does not begin a number.
    private static func parseNumberRun(_ tokens: [String], from start: Int,
                                       language: TranscriptLanguage) -> (Int, Int)? {
        switch language {
        case .english: parseEnglishRun(tokens, from: start)
        case .spanish: parseSpanishRun(tokens, from: start)
        }
    }

    /// Spanish runs, which differ from English in the connector rule and in
    /// treating the hundreds as additive values.
    private static func parseSpanishRun(_ tokens: [String], from start: Int) -> (Int, Int)? {
        var total = 0
        var current = 0
        var index = start
        var consumed = 0
        var sawNumber = false
        var lastWasTens = false

        while index < tokens.count {
            let token = tokens[index]

            if let value = spanishUnits[token] {
                current += value
                sawNumber = true
                lastWasTens = false
            } else if let value = spanishTens[token] {
                current += value
                sawNumber = true
                lastWasTens = true
            } else if spanishArticleNumerals.contains(token) {
                // Only a numeral immediately before a scale; otherwise it is
                // the article and the run has not started.
                let next = index + 1
                guard next < tokens.count, spanishScales[tokens[next]] != nil else {
                    return sawNumber ? (total + current, consumed) : nil
                }
                current += 1
                sawNumber = true
                lastWasTens = false
            } else if let value = spanishOrdinals[token] {
                if value >= 100 {
                    current = Swift.max(current, 1) * value
                } else {
                    current += value
                }
                sawNumber = true
                index += 1
                consumed += 1
                break
            } else if let scale = spanishScales[token] {
                // "mil personas" is a thousand people — Spanish does not
                // require the "un" that English requires before "thousand".
                // "millones" alone is vague ("millions of"), so it still needs
                // a count in front of it.
                guard sawNumber || token == "mil" else { return nil }
                total += Swift.max(current, 1) * scale
                current = 0
                // Set here too, so a run opening on a bare "mil" survives the
                // final guard.
                sawNumber = true
                lastWasTens = false
            } else if token == "y" {
                // Joins tens to units and nothing else, so the ordinary
                // conjunction does not turn "cinco y dos" into seven.
                let next = index + 1
                guard lastWasTens, next < tokens.count,
                      let unit = spanishUnits[tokens[next]], unit < 10
                else { break }
            } else {
                break
            }
            index += 1
            consumed += 1
        }

        guard sawNumber else { return nil }
        return (total + current, consumed)
    }

    private static func parseEnglishRun(_ tokens: [String], from start: Int) -> (Int, Int)? {
        var total = 0        // completed scale groups
        var current = 0      // the group being built
        var index = start
        var consumed = 0
        var sawNumber = false

        while index < tokens.count {
            let token = tokens[index]

            if let value = units[token] ?? tens[token] {
                current += value
                sawNumber = true
            } else if let value = ordinals[token] {
                // An ordinal terminates the run: "twenty third" is 23, and
                // whatever follows is not part of the number.
                if value >= 100 {
                    current = Swift.max(current, 1) * value
                } else {
                    current += value
                }
                sawNumber = true
                index += 1
                consumed += 1
                break
            } else if let scale = scales[token] {
                guard sawNumber else { return nil }
                if scale == 100 {
                    current = Swift.max(current, 1) * scale
                } else {
                    total += Swift.max(current, 1) * scale
                    current = 0
                }
            } else if token == "and" && sawNumber {
                // "three hundred and twelve" — only inside a run, and only when
                // a number actually follows.
                let next = index + 1
                guard next < tokens.count,
                      units[tokens[next]] != nil || tens[tokens[next]] != nil
                        || ordinals[tokens[next]] != nil
                else { break }
            } else {
                break
            }
            index += 1
            consumed += 1
        }

        guard sawNumber else { return nil }
        return (total + current, consumed)
    }
}
