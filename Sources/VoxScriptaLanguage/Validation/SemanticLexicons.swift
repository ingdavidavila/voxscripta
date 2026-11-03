import Foundation
import VoxScriptaCore

/// Word lists the meaning-preservation checks depend on.
///
/// These are closed sets on purpose. A validator built on a model's judgement of
/// whether a model's output was faithful is circular; these are flat lookups that
/// behave identically every time.
public enum SemanticLexicons {

    /// Markers that negate a clause.
    ///
    /// Dropping or adding one inverts a claim, which is the single most damaging
    /// transformation POLISHED could make: "we did not approve" becoming "we
    /// approved" is fluent, plausible, and completely wrong.
    public static func negations(for language: TranscriptLanguage) -> Set<String> {
        switch language {
        case .english: englishNegations
        case .spanish: spanishNegations
        }
    }

    /// Negation spelled across more than one word.
    ///
    /// A token set cannot see these: neither "far" nor "from" is negative
    /// alone, and both are far too common to add. Measured need rather than
    /// completeness — these are the forms `EnglishRejectionCorpus` caught
    /// escaping after the single-word list was extended.
    public static func negationPhrases(
        for language: TranscriptLanguage
    ) -> [[String]] {
        switch language {
        case .english: englishNegationPhrases
        case .spanish: []
        }
    }

    public static func hedges(for language: TranscriptLanguage) -> Set<String> {
        switch language {
        case .english: englishHedges
        case .spanish: spanishHedges
        }
    }

    public static func stopWords(for language: TranscriptLanguage) -> Set<String> {
        switch language {
        case .english: englishStopWords
        case .spanish: spanishStopWords
        }
    }

    /// Spanish negation, and the most load-bearing list in this file.
    ///
    /// In English this check is one of two defences on Apple and the only one
    /// everywhere else, and it is now measured in both configurations — see
    /// ``englishNegations``. In Spanish the distance check catches no
    /// negation at all, so this list has always been the only thing standing
    /// between a polish pass and an inverted meaning. It is
    /// therefore deliberately over-inclusive, and both accented and bare forms
    /// are present because ``normalize`` keeps accents while engines are not
    /// consistent about emitting them.
    ///
    /// Spanish also negates twice — "no vimos nada" is a single negation, not
    /// two — so the check counts tokens on each side and compares totals
    /// rather than reasoning about polarity, which survives double negation
    /// intact.
    static let spanishNegations: Set<String> = [
        "no", "ni", "nunca", "jamás", "jamas", "nada", "nadie", "ninguno",
        "ninguna", "ningún", "ningun", "ningunos", "ningunas", "tampoco",
        "sin", "falta", "faltan", "faltó", "falto", "carece", "carecen",
        "ausente", "ausentes", "incapaz", "incapaces", "imposible",
        "imposibles", "fracasó", "fracaso", "fracasa", "falla", "fallan",
        "falló", "fallo", "niega", "niegan", "negó", "nego", "negar",
        "rechaza", "rechazan", "rechazó", "rechazo",
    ]

    /// Spanish hedges and epistemic qualifiers.
    ///
    /// Single tokens only, because the check counts tokens. Multi-word hedges
    /// — "tal vez", "más o menos", "a lo mejor" — are represented by their
    /// distinctive member ("quizá" has none, so "tal" is too common to use).
    /// That makes the list slightly leaky for phrases, which is the safe
    /// direction: a missed hedge is a rewrite that gets looked at, not one
    /// that slips through as fact.
    static let spanishHedges: Set<String> = [
        "quizá", "quiza", "quizás", "quizas", "acaso", "posiblemente",
        "probablemente", "aparentemente", "presumiblemente", "supuestamente",
        "podría", "podria", "podrían", "podrian", "puede", "pueden",
        "debería", "deberia", "deberían", "deberian", "parece", "parecen",
        "pareciera", "creo", "creemos", "pienso", "pensamos", "supongo",
        "suponemos", "imagino", "diría", "diria", "aproximadamente", "casi",
        "cerca", "alrededor", "roughly", "generalmente", "usualmente",
        "normalmente", "frecuentemente", "ocasionalmente", "suele", "suelen",
        "tiende", "tienden", "bastante", "algo", "relativamente",
    ]

    /// Spanish function words excluded from content-word overlap.
    ///
    /// Negations are deliberately absent, exactly as "not" is absent from the
    /// English list: they carry meaning and must not be discounted.
    static let spanishStopWords: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "lo",
        "de", "del", "a", "al", "en", "con", "por", "para", "sobre", "entre",
        "hasta", "desde", "hacia", "según", "segun", "durante",
        "y", "e", "o", "u", "pero", "sino", "aunque", "porque", "pues",
        "que", "qué", "quien", "quién", "cual", "cuál", "cuyo", "cuya",
        "como", "cómo", "cuando", "cuándo", "donde", "dónde", "si",
        "este", "esta", "estos", "estas", "ese", "esa", "esos", "esas",
        "aquel", "aquella", "esto", "eso", "aquello",
        "yo", "tú", "tu", "él", "ella", "usted", "nosotros", "nosotras",
        "vosotros", "ellos", "ellas", "ustedes", "me", "te", "se", "nos", "os",
        "mi", "mis", "su", "sus", "nuestro", "nuestra", "vuestro",
        "es", "son", "era", "eran", "fue", "fueron", "ser", "estar", "está",
        "esta", "están", "estan", "estaba", "estaban", "he", "ha", "han",
        "había", "habia", "haber", "hay", "muy", "ya", "también", "tambien",
        "así", "asi", "ahí", "ahi", "allí", "alli", "aquí", "aqui",
    ]

    /// English negation.
    ///
    /// The second half of this list was added after measuring, not before. The
    /// list used to hold only words that *look* negative — `not`, `never`,
    /// `nobody` — and `EnglishRejectionCorpus` showed what that misses: with
    /// the embedding gone, seven of twenty-nine meaning-changing rewrites got
    /// through, and every one of them was negation spelled without a negative
    /// word. "We hardly finished on time" became "We finished on time";
    /// "They disagreed" became "They agreed"; "He denied signing it" became
    /// "He signed it".
    ///
    /// Three of those seven also got through *with* the embedding, on a Mac.
    /// So this was never only an off-Apple problem — it was a hole in English
    /// that the embedding happened to cover most of the time.
    static let englishNegations: Set<String> = [
        // Overt negation: a negative word doing the negating.
        "not", "no", "never", "none", "nobody", "nothing", "nowhere", "neither",
        "nor", "cannot", "cant", "wont", "dont", "doesnt", "didnt", "isnt",
        "arent", "wasnt", "werent", "hasnt", "havent", "hadnt", "shouldnt",
        "wouldnt", "couldnt", "wont", "aint", "without", "lack", "lacks",
        "lacking", "absent", "fail", "fails", "failed", "unable",

        // Approximative negators. "Hardly finished" is nearer to "did not
        // finish" than to "finished", and dropping one reads as a tidy-up.
        "hardly", "scarcely", "barely", "seldom", "rarely",

        // Bare `few` is negative where `a few` is not — "few people agreed"
        // against "a few people agreed". Counting it costs a false rejection
        // if a polish pass rewrites "a few" as "several", which is a change of
        // quantity that the stage has no business making anyway.
        "few",

        // Verbs that negate their complement. Dropping one inverts the
        // sentence without touching a negative word: "denied signing it"
        // becomes "signed it".
        "deny", "denies", "denied", "denying",
        "refuse", "refuses", "refused", "refusing",
        "reject", "rejects", "rejected", "rejecting",
        "decline", "declines", "declined", "declining",
        "prevent", "prevents", "prevented", "preventing",

        // The dis- prefix, which reverses a verb while looking like a word of
        // its own. Only the forms a transcript plausibly contains.
        "disagree", "disagrees", "disagreed",
        "disapprove", "disapproves", "disapproved",
        "disallow", "disallows", "disallowed",
    ]

    /// English negation written across words.
    ///
    /// Both of these survived the single-word list and were caught escaping by
    /// measurement: "That is far from settled" became "That is settled", and
    /// "It is anything but finished" became "It is finished". Each reads as a
    /// tidy-up and reverses the sentence.
    /// Exactly the two the measurement demanded, and no more.
    ///
    /// "nothing but", "rather than" and "instead of" were in the first version
    /// of this list and are gone: the first double-counts against the `nothing`
    /// token, and the other two are not negation — adding markers nothing has
    /// shown to be needed trades real false rejections for imagined safety.
    static let englishNegationPhrases: [[String]] = [
        ["far", "from"],
        ["anything", "but"],
    ]

    /// Hedges and epistemic qualifiers.
    ///
    /// Removing one promotes a qualified statement to a flat assertion. "It might
    /// be possible to finish by Friday" is not "We will finish by Friday", and a
    /// readability pass has no business making that change.
    static let englishHedges: Set<String> = [
        "might", "may", "could", "would", "should", "possibly", "perhaps",
        "maybe", "probably", "likely", "unlikely", "roughly", "approximately",
        "about", "around", "nearly", "almost", "somewhat", "fairly", "rather",
        "seems", "seem", "appears", "appear", "suggests", "suggest", "think",
        "believe", "guess", "suppose", "presumably", "apparently", "potentially",
        "generally", "usually", "often", "sometimes", "occasionally", "tends",
    ]

    /// Function words excluded from content-word overlap.
    static let englishStopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "than", "that",
        "this", "these", "those", "of", "to", "in", "on", "at", "by", "for",
        "with", "from", "as", "is", "are", "was", "were", "be", "been", "being",
        "am", "do", "does", "did", "have", "has", "had", "will", "shall",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us",
        "them", "my", "your", "his", "its", "our", "their", "so", "up", "out",
        "there", "here", "what", "which", "who", "whom", "when", "where", "how",
    ]

    /// Counts how many tokens fall in `lexicon`, comparing without punctuation.
    public static func count(_ tokens: [String], in lexicon: Set<String>) -> Int {
        tokens.count { lexicon.contains(normalize($0)) }
    }

    /// Which lexicon members appear, as a multiset keyed by token.
    public static func occurrences(_ tokens: [String], in lexicon: Set<String>) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens {
            let key = normalize(token)
            if lexicon.contains(key) { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// Counts multi-word markers, as a sliding window over the same
    /// normalized tokens the single-word count uses — so "Far from settled"
    /// and "far from settled" compare equal, like everything else here.
    public static func phraseOccurrences(
        _ tokens: [String], in phrases: [[String]]
    ) -> [String: Int] {
        guard !phrases.isEmpty else { return [:] }
        let normalized = tokens.map(normalize)
        var counts: [String: Int] = [:]
        for phrase in phrases where phrase.count <= normalized.count {
            let key = phrase.joined(separator: " ")
            for start in 0...(normalized.count - phrase.count)
            where Array(normalized[start..<(start + phrase.count)]) == phrase {
                counts[key, default: 0] += 1
            }
        }
        return counts
    }

    /// Lower-cased with apostrophes and punctuation removed, so "didn't" and
    /// "didnt" compare equal.
    static func normalize(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
