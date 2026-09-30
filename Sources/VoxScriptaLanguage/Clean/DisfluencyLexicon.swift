import Foundation

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
    public static let fillers: Set<String> = [
        "uh", "um", "erm", "er", "ah", "eh", "mm", "hm", "hmm", "mhm",
        "uhh", "umm", "ahh", "ehh", "mmm",
    ]

    /// Tokens that look like fillers but carry meaning, so are never removed.
    ///
    /// "uh-huh" and "mm-hmm" are affirmations — deleting one can invert the sense
    /// of an answer, which is exactly the failure CLEAN must not have.
    public static let protectedTokens: Set<String> = [
        "uh-huh", "uhhuh", "mm-hmm", "mmhmm", "uh-uh", "huh", "oh", "ah-ha", "aha",
    ]

    /// Words that legitimately appear twice in a row, so are never collapsed.
    ///
    /// "I had had enough" and "the thing that that man said" are grammatical.
    /// Collapsing them deletes a real word and changes the sentence.
    public static let legitimatelyDoubled: Set<String> = [
        "had", "that", "did", "do", "is", "who", "what", "no", "very", "long", "far", "many",
    ]

    /// Whether `token` is a removable non-lexical filler.
    public static func isFiller(_ token: String) -> Bool {
        let key = normalize(token)
        guard !key.isEmpty, !protectedTokens.contains(key) else { return false }
        return fillers.contains(key)
    }

    /// Whether an immediate repetition of `token` may be collapsed.
    public static func mayCollapseRepetition(of token: String) -> Bool {
        let key = normalize(token)
        guard !key.isEmpty, key.count <= 12 else { return false }
        return !legitimatelyDoubled.contains(key) && !protectedTokens.contains(key)
    }

    /// Lower-cased, stripped of surrounding punctuation, hyphens preserved.
    static func normalize(_ token: String) -> String {
        token.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}…—–"))
    }
}
