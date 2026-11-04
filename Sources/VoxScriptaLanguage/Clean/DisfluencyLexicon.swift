import Foundation
import VoxScriptaCore

/// The closed set of tokens CLEAN is allowed to delete.
///
/// Deliberately narrow. §12 requires CLEAN to stay "extremely faithful to what
/// was said", and its own worked example keeps "basically" and "probably" while
/// dropping only "uh" — so this covers *non-lexical* vocalizations, sounds that
/// carry no propositional content, and nothing else.
///
/// Discourse markers ("you know", "I mean", "like", "basically", "actually") are
/// deliberately absent. They are real words that shade meaning and register, and
/// removing them is a rewrite. If a user wants them gone, that is a POLISHED
/// decision made under validation, not a silent CLEAN edit.
public enum DisfluencyLexicon {

    /// Non-lexical fillers, matched case-insensitively as whole tokens.
    public static func fillers(for language: TranscriptLanguage) -> Set<String> {
        switch language {
        case .english: englishFillers
        case .spanish: spanishFillers
        }
    }

    static let englishFillers: Set<String> = [
        "uh", "um", "erm", "er", "ah", "eh", "mm", "hm", "hmm", "mhm",
        "uhh", "umm", "ahh", "ehh", "mmm",
    ]

    /// Spanish hesitation sounds.
    ///
    /// "este" and "esto" are the hard cases and the reason this list is not a
    /// translation of the English one. Both are ordinary demonstratives — "este
    /// informe", "esto es importante" — and both are also the language's most
    /// common hesitation marker, standing alone where English would say "um".
    /// Only the standalone use is a filler, so they are listed under
    /// ``contextualFillers`` and removed only when nothing attaches to them,
    /// never when they determine a following noun.
    ///
    /// "o sea" and "pues" are absent for the same reason their English
    /// counterparts are: they are discourse markers that shade meaning, and
    /// deleting one is a rewrite rather than a cleanup.
    static let spanishFillers: Set<String> = [
        "eh", "ehh", "em", "emm", "mm", "mmm", "hm", "hmm", "ah", "ahh",
        "uh", "uhm", "mhm",
    ]

    /// Tokens that are fillers only when they stand alone.
    ///
    /// Checked by ``isFiller(_:in:)`` against the following token, because
    /// removing a determiner silently breaks the noun phrase it governs.
    public static func contextualFillers(for language: TranscriptLanguage) -> Set<String> {
        switch language {
        case .english: []
        case .spanish: ["este", "esto", "esteee", "estee"]
        }
    }

    /// Tokens that look like fillers but carry meaning, so are never removed.
    ///
    /// "uh-huh" and "mm-hmm" are affirmations — deleting one can invert the sense
    /// of an answer, which is exactly the failure CLEAN must not have.
    public static func protectedTokens(for language: TranscriptLanguage) -> Set<String> {
        switch language {
        case .english: englishProtected
        case .spanish: spanishProtected
        }
    }

    static let englishProtected: Set<String> = [
        "uh-huh", "uhhuh", "mm-hmm", "mmhmm", "uh-uh", "huh", "oh", "ah-ha", "aha",
    ]

    /// Spanish affirmations and their negative counterpart.
    ///
    /// "ajá" and "mjm" affirm; deleting one can invert an answer, which is the
    /// failure CLEAN must not have. "eh" is absent here on purpose — as a bare
    /// hesitation it is a filler, and its tag-question use ("¿eh?") carries
    /// punctuation that ``normalize`` leaves in place.
    static let spanishProtected: Set<String> = [
        "ajá", "aja", "ajam", "mjm", "mju", "ujum", "oh", "ay", "uy", "huy",
    ]

    /// Words that legitimately appear twice in a row, so are never collapsed.
    ///
    /// "I had had enough" and "the thing that that man said" are grammatical.
    /// Collapsing them deletes a real word and changes the sentence.
    public static func legitimatelyDoubled(for language: TranscriptLanguage) -> Set<String> {
        switch language {
        case .english: englishDoubled
        case .spanish: spanishDoubled
        }
    }

    static let englishDoubled: Set<String> = [
        "had", "that", "did", "do", "is", "who", "what", "no", "very", "long", "far", "many",
    ]

    /// Spanish words that legitimately repeat.
    ///
    /// "no no" is an emphatic refusal and collapsing it weakens a negation,
    /// which matters more in Spanish than in English: the semantic-distance
    /// check barely registers Spanish negation, so the lexical defences carry
    /// the weight. "que que" appears in "creo que que viene", "muy muy" and
    /// "casi casi" are ordinary intensifiers.
    static let spanishDoubled: Set<String> = [
        "no", "que", "muy", "casi", "sí", "si", "ya", "más", "mas", "tan",
        "cada", "poco", "nada",
    ]

    /// Whether `token` is a removable non-lexical filler.
    ///
    /// `following` is the next token, needed only for the contextual fillers:
    /// Spanish "este" is a filler standing alone and a determiner in front of a
    /// noun, and nothing but the next word distinguishes them.
    public static func isFiller(_ token: String,
                                in language: TranscriptLanguage,
                                following: String? = nil) -> Bool {
        let key = normalize(token)
        guard !key.isEmpty, !protectedTokens(for: language).contains(key) else { return false }
        if fillers(for: language).contains(key) { return true }
        guard contextualFillers(for: language).contains(key) else { return false }
        // A determiner governs what comes next, so only treat it as hesitation
        // when the phrase ends or another hesitation follows.
        guard let following, !following.isEmpty else { return true }
        let next = normalize(following)
        return next.isEmpty || fillers(for: language).contains(next)
    }

    /// Whether an immediate repetition of `token` may be collapsed.
    public static func mayCollapseRepetition(of token: String,
                                             in language: TranscriptLanguage) -> Bool {
        let key = normalize(token)
        guard !key.isEmpty, key.count <= 12 else { return false }
        return !legitimatelyDoubled(for: language).contains(key)
            && !protectedTokens(for: language).contains(key)
    }

    /// Lower-cased, stripped of surrounding punctuation, hyphens preserved.
    static func normalize(_ token: String) -> String {
        token.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}…—–"))
    }
}
