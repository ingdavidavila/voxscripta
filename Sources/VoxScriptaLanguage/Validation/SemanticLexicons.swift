import Foundation

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
    public static let negations: Set<String> = [
        "not", "no", "never", "none", "nobody", "nothing", "nowhere", "neither",
        "nor", "cannot", "cant", "wont", "dont", "doesnt", "didnt", "isnt",
        "arent", "wasnt", "werent", "hasnt", "havent", "hadnt", "shouldnt",
        "wouldnt", "couldnt", "wont", "aint", "without", "lack", "lacks",
        "lacking", "absent", "fail", "fails", "failed", "unable",
    ]

    /// Hedges and epistemic qualifiers.
    ///
    /// Removing one promotes a qualified statement to a flat assertion. "It might
    /// be possible to finish by Friday" is not "We will finish by Friday", and a
    /// readability pass has no business making that change.
    public static let hedges: Set<String> = [
        "might", "may", "could", "would", "should", "possibly", "perhaps",
        "maybe", "probably", "likely", "unlikely", "roughly", "approximately",
        "about", "around", "nearly", "almost", "somewhat", "fairly", "rather",
        "seems", "seem", "appears", "appear", "suggests", "suggest", "think",
        "believe", "guess", "suppose", "presumably", "apparently", "potentially",
        "generally", "usually", "often", "sometimes", "occasionally", "tends",
    ]

    /// Function words excluded from content-word overlap.
    public static let stopWords: Set<String> = [
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

    /// Lower-cased with apostrophes and punctuation removed, so "didn't" and
    /// "didnt" compare equal.
    static func normalize(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
