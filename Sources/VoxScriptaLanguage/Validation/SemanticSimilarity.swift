import Foundation
import NaturalLanguage

/// Sentence-level semantic distance, on device.
///
/// `NLEmbedding` reports a *distance* rather than a similarity — lower means
/// closer — and its scale is not the 0...1 cosine the architecture assumed. The
/// threshold is therefore calibrated against measured pairs rather than picked.
///
/// A class because loading the model costs real time and it is reused across
/// every window of a transcript.
public final class SemanticSimilarity: @unchecked Sendable {
    private let lock = NSLock()
    private var embedding: NLEmbedding?
    private var loaded = false

    public init() {}

    public static let shared = SemanticSimilarity()

    /// Distance between two sentences, or `nil` when no model is available.
    ///
    /// Returning `nil` rather than a default matters: a missing model must make
    /// the check abstain visibly, not silently pass everything.
    public func distance(_ a: String, _ b: String) -> Double? {
        // The lock is held across the query, not merely across loading.
        // `NLEmbedding` is not documented as thread-safe, and calling it
        // concurrently from parallel tests aborts the process — which presents as
        // a signal 6 with no failing assertion, so it is worth being explicit.
        lock.lock()
        defer { lock.unlock() }

        if !loaded {
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
            loaded = true
        }
        guard let model = embedding else { return nil }
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

    /// Whether the embedding model is present on this system.
    public var isAvailable: Bool {
        lock.lock()
        if !loaded {
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
            loaded = true
        }
        let available = embedding != nil
        lock.unlock()
        return available
    }
}
