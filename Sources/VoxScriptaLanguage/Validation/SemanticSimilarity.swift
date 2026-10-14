import Foundation
import NaturalLanguage
import VoxScriptaCore

/// Sentence-level semantic distance, on device.
///
/// `NLEmbedding` reports a *distance* rather than a similarity — lower means
/// closer — and its scale is not the 0...1 cosine the architecture assumed. The
/// threshold is therefore calibrated against measured pairs rather than picked.
///
/// A class because loading the model costs real time and it is reused across
/// every window of a transcript.
///
/// The model is per language, and the languages do not behave alike. See
/// ``catchesNegation(in:)`` — this is not a detail that can be papered over
/// with a different threshold.
public final class SemanticSimilarity: @unchecked Sendable {
    private let lock = NSLock()
    private var embeddings: [TranscriptLanguage: NLEmbedding?] = [:]

    public init() {}

    public static let shared = SemanticSimilarity()

    /// Whether this language's embedding separates a negated sentence from its
    /// original well enough for distance alone to catch a meaning inversion.
    ///
    /// English: yes, and decisively. Measured over five negation pairs, the
    /// distances ran 0.727 to 1.020 against a 0.72 rejection threshold — five
    /// of five caught.
    ///
    /// Spanish: no. The same five pairs translated ran 0.274 to 0.479, none
    /// caught. They score *closer* than Spanish paraphrases do (0.473), so the
    /// model barely encodes negation at all and no threshold separates the two
    /// populations. Lowering the threshold would reject every legitimate
    /// rewrite before it caught a single inversion.
    ///
    /// The consequence is structural rather than numeric: in Spanish the
    /// lexical polarity check is the only defence against a flipped sentence,
    /// where in English it is one of two. ``ValidationGauntlet`` must not treat
    /// a passing distance as evidence of preserved polarity in a language where
    /// this returns false.
    public static func catchesNegation(in language: TranscriptLanguage) -> Bool {
        switch language {
        case .english: true
        case .spanish: false
        }
    }

    private static func nlLanguage(for language: TranscriptLanguage) -> NLLanguage {
        switch language {
        case .english: .english
        case .spanish: .spanish
        }
    }

    /// Loads on first use per language. Caller must hold `lock`.
    private func model(for language: TranscriptLanguage) -> NLEmbedding? {
        if let cached = embeddings[language] { return cached }
        let loaded = NLEmbedding.sentenceEmbedding(for: Self.nlLanguage(for: language))
        embeddings[language] = loaded
        return loaded
    }

    /// Distance between two sentences, or `nil` when no model is available.
    ///
    /// Returning `nil` rather than a default matters: a missing model must make
    /// the check abstain visibly, not silently pass everything.
    public func distance(_ a: String, _ b: String,
                         in language: TranscriptLanguage = .english) -> Double? {
        // The lock is held across the query, not merely across loading.
        // `NLEmbedding` is not documented as thread-safe, and calling it
        // concurrently from parallel tests aborts the process — which presents as
        // a signal 6 with no failing assertion, so it is worth being explicit.
        lock.lock()
        defer { lock.unlock() }

        guard let model = model(for: language) else { return nil }
        // Case-folded before embedding. Capitalization moves this model's
        // distance almost as far as a meaning inversion does — measured at 0.86
        // for "david met sarah chen" against "David met Sarah Chen" — and fixing
        // capitalization is precisely what POLISHED is meant to do. Comparing raw
        // text would spend the entire error budget on an artifact.
        let trimmedA = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedB = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedA.isEmpty, !trimmedB.isEmpty else { return nil }
        if trimmedA == trimmedB { return 0 }

        let d = model.distance(between: trimmedA, and: trimmedB)
        return d.isFinite ? d : nil
    }

    /// Whether this language's embedding model is present on this system.
    public func isAvailable(for language: TranscriptLanguage = .english) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return model(for: language) != nil
    }

    /// Kept for call sites that predate multi-language support.
    public var isAvailable: Bool { isAvailable(for: .english) }
}
