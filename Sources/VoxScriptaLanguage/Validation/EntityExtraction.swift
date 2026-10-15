import Foundation
import NaturalLanguage
import VoxScriptaCore

/// Extracts the things POLISHED must not alter.
///
/// Two deliberate choices here, both learned from measuring what the on-device
/// tagger actually does.
///
/// **Entities are compared as strings, never as types.** `NLTagger` classifies
/// "David" as a place and "Northwind" as a place on this system. That would make
/// a type-aware comparison fail on correct output while catching nothing extra —
/// what matters is that the token survived, not that the tagger understood it.
///
/// **NER is backed up by a capitalization heuristic.** The tagger misses entities
/// outright, and a missed name is a name the validator would let the model
/// change. Mid-sentence capitalized tokens are therefore treated as proper nouns
/// too. This over-collects, which is the safe direction: a false positive makes
/// the validator stricter, a false negative lets a renamed person through.
public enum EntityExtraction {

    /// The tokens worth watching across a pair of texts.
    ///
    /// Capitalization identifies *which* words to watch, but must not be part of
    /// the comparison itself: fixing "david" to "David" is exactly what POLISHED
    /// is for, and a case-sensitive comparison reads that as adding a name. So the
    /// vocabulary is collected from both sides and counted case-insensitively.
    public static func entityVocabulary(_ texts: [String]) -> Set<String> {
        var vocabulary: Set<String> = []
        for text in texts {
            vocabulary.formUnion(namedEntities(in: text))
            vocabulary.formUnion(capitalizedTokens(in: text))
        }
        return vocabulary
    }

    /// How often each watched token appears, ignoring case and punctuation.
    public static func counts(of vocabulary: Set<String>, in text: String) -> [String: Int] {
        guard !vocabulary.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for token in TextTokenizer.tokens(text) {
            let key = SemanticLexicons.normalize(token)
            if vocabulary.contains(key) { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// Proper nouns and named entities found in one text, for diagnostics.
    public static func entities(in text: String) -> [String: Int] {
        counts(of: entityVocabulary([text]), in: text)
    }

    /// Entities the tagger recognizes, joined across multi-word names.
    static func namedEntities(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var out: [String] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            guard let tag,
                  tag == .personalName || tag == .placeName || tag == .organizationName
            else { return true }
            // Split joined names so "Sarah Chen" and "Sarah" and "Chen" all
            // compare — a model that drops a surname must still be caught.
            for part in String(text[range]).split(separator: " ") {
                let key = SemanticLexicons.normalize(String(part))
                if !key.isEmpty { out.append(key) }
            }
            return true
        }
        return out
    }

    /// Words that are capitalized in English without being proper nouns.
    ///
    /// "I" is the whole of this set in practice, and leaving it in was expensive:
    /// every sentence containing the pronoun was rejected for a "duplicated name"
    /// whenever polish changed how often it appeared.
    static let capitalizedNonNouns: Set<String> = ["i"]

    /// Capitalized tokens that are not sentence-initial.
    ///
    /// Sentence-initial capitals are excluded because they carry no information
    /// about proper nouns — CLEAN and POLISHED both legitimately capitalize there.
    static func capitalizedTokens(in text: String) -> [String] {
        var out: [String] = []
        var expectingSentenceStart = true

        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(raw)
            let stripped = token.trimmingCharacters(
                in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}…—–"))
            defer {
                if let last = token.last(where: { !$0.isWhitespace }), ".!?…".contains(last) {
                    expectingSentenceStart = true
                } else if !stripped.isEmpty {
                    expectingSentenceStart = false
                }
            }
            guard !stripped.isEmpty, let first = stripped.first, first.isUppercase,
                  !expectingSentenceStart else { continue }
            // An all-caps acronym is a proper noun too.
            let key = SemanticLexicons.normalize(stripped)
            guard !key.isEmpty, !capitalizedNonNouns.contains(key) else { continue }
            out.append(key)
        }
        return out
    }

    /// Numbers present, canonicalized so "five hundred" and "500" agree.
    ///
    /// Strict equality on this set is what catches §14's example: "approximately
    /// 1,000" is *plausible* where "500" was said, which is precisely why a fuzzy
    /// comparison would let it through.
    public static func numbers(in text: String,
                               language: TranscriptLanguage = .english) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in TextTokenizer.comparableTokens(text, in: language)
        where token.allSatisfy(\.isNumber) && !token.isEmpty {
            counts[token, default: 0] += 1
        }
        return counts
    }

    /// Lemmatized content words, for overlap scoring.
    public static func contentWords(in text: String,
                                    language: TranscriptLanguage = .english) -> Set<String> {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        // Told rather than guessed. A short Spanish sentence is routinely
        // detected as Portuguese or Italian, and the wrong lemmatizer turns
        // real content words into unknowns.
        tagger.setLanguage(nlLanguage(for: language), range: text.startIndex..<text.endIndex)

        var out: Set<String> = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, range in
            // The tagger returns no lemma for unknown words; fall back to the
            // surface form so a rare proper noun still counts as content.
            let lemma = tag?.rawValue ?? String(text[range])
            let key = SemanticLexicons.normalize(lemma)
            if !key.isEmpty, !SemanticLexicons.stopWords(for: language).contains(key) {
                out.insert(key)
            }
            return true
        }
        return out
    }

    /// Maps to the tagger's language tag.
    static func nlLanguage(for language: TranscriptLanguage) -> NLLanguage {
        switch language {
        case .english: .english
        case .spanish: .spanish
        }
    }
}
