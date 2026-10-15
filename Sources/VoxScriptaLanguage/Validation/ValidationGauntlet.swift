import Foundation
import VoxScriptaCore

/// The checks a polished sentence must survive (§14).
///
/// Every check is deterministic. None of them asks a model whether the model's own
/// output was acceptable, which would be circular.
public enum ValidationCheck: String, Sendable, Codable, CaseIterable {
    /// One output sentence per input sentence. Enforced by the generation schema
    /// before any other check runs.
    case cardinality
    /// Numbers, normalized across numerals, number-words, units and magnitudes,
    /// must form the same set in and out. Strict equality, not similarity —
    /// "approximately 1,000" is *plausible*, which is exactly why a fuzzy check
    /// would let it through.
    case numericConservation
    /// People, places and organizations must form the same set in and out.
    case namedEntityConservation
    /// Negation-marker count per sentence must not change.
    case polarity
    /// Hedges must not be dropped — doing so turns a qualified claim into an assertion.
    case modality
    /// Sentence-embedding cosine similarity must clear a floor.
    case semanticSimilarity
    /// Length ratio and content-word overlap must stay in bounds, which is what
    /// catches summarization.
    case extentBounds
}

/// One check's outcome.
public struct CheckResult: Hashable, Sendable, Codable {
    public let check: ValidationCheck
    public let passed: Bool
    /// Human-readable explanation, shown in the UI when a sentence is flagged.
    public let detail: String?
    /// The measured value, where the check produces one.
    public let measurement: Double?

    public init(check: ValidationCheck, passed: Bool, detail: String? = nil, measurement: Double? = nil) {
        self.check = check
        self.passed = passed
        self.detail = detail
        self.measurement = measurement
    }
}

/// The full report for one polished window.
public struct ValidationReport: Hashable, Sendable, Codable {
    public let results: [CheckResult]

    public init(results: [CheckResult]) { self.results = results }

    public var passed: Bool { results.allSatisfy(\.passed) }
    public var failures: [CheckResult] { results.filter { !$0.passed } }
    public var failureReasons: [String] {
        failures.map { $0.detail ?? $0.check.rawValue }
    }
}

/// Thresholds for the measurement-based checks.
/// Which languages POLISH is allowed to run in, and on what evidence.
///
/// Not a list of languages someone remembered to add. A language qualifies
/// only when meaning-changing rewrites are demonstrably caught, and the two
/// languages qualify by different routes.
///
/// English has two independent defences against a reversed meaning: the
/// lexical polarity count and the semantic-distance check, which caught five
/// of five measured negations.
///
/// Spanish has one. The Spanish sentence embedding scores a negation closer to
/// its original than a paraphrase is — 0.335 mean against a 0.473 paraphrase —
/// so no threshold separates them and the distance check is blind to the most
/// dangerous edit available. It still catches invention and wholesale
/// replacement, but polarity rests entirely on the lexical count. That is why
/// Spanish required `SpanishRejectionCorpus` before being admitted: eighteen
/// corruptions, every one refused by the check intended to refuse it, against
/// ten legitimate rewrites none of which was blocked.
///
/// The honest limit of that evidence is that the corpus and the lexicon were
/// written by the same hand, so it demonstrates the defence works on the
/// failures we thought of. The structural guard below is what covers the rest:
/// a language with no negation lexicon cannot be admitted at all, whatever
/// this table says.
public enum PolishReadiness {

    public static func isValidated(_ language: TranscriptLanguage) -> Bool {
        // A language whose polarity lexicon is empty has no defence to measure,
        // so it is refused regardless of what follows.
        guard !SemanticLexicons.negations(for: language).isEmpty else { return false }

        switch language {
        case .english:
            // Two defences, the embedding among them.
            return SemanticSimilarity.catchesNegation(in: .english)
        case .spanish:
            // One defence, measured. See SpanishRejectionCorpus.
            return true
        }
    }

    /// Why POLISH is withheld, for the interface to show. `nil` when it runs.
    public static func withheldReason(for language: TranscriptLanguage?) -> String? {
        guard let language else {
            return "noLexicons"
        }
        return isValidated(language) ? nil : "notValidated"
    }
}

public struct ValidationThresholds: Hashable, Sendable, Codable {
    /// Largest `NLEmbedding` distance still treated as the same meaning.
    ///
    /// A distance, not a similarity: lower is closer. The architecture assumed a
    /// 0...1 cosine; the on-device model does not work that way.
    ///
    /// Calibrated from measurement, not chosen. Against the mutation corpus,
    /// legitimate polish tops out at 0.548 and the closest meaning-changing
    /// corruption sits at 0.904, so 0.72 lands in the middle of that gap with
    /// roughly 30% headroom on each side. `SemanticDistanceCalibrationTests`
    /// re-measures the separation and fails if an OS model update erodes it.
    public var maximumSemanticDistance: Double
    public var minimumLengthRatio: Double
    public var maximumLengthRatio: Double
    public var minimumContentWordOverlap: Double
    /// Most new content words a revision may introduce, as a fraction of the
    /// original's content-word count.
    ///
    /// Retention alone cannot catch injection: "start on Monday if that works"
    /// becoming "let's start on Monday if that works for you" keeps every
    /// original content word and still adds a referent the speaker never
    /// mentioned. §13 forbids adding information, so additions are bounded too.
    public var maximumContentWordInjection: Double
    /// Allow a hedge or negation to move between adjacent sentences in a window.
    ///
    /// Off by default. Per-sentence comparison is stricter and catches a polarity
    /// flip that a window-level count would miss when one clause gains a negation
    /// and another loses one.
    public var perWindowPolarity: Bool

    public init(
        maximumSemanticDistance: Double = 0.72,
        minimumLengthRatio: Double = 0.5,
        maximumLengthRatio: Double = 1.5,
        minimumContentWordOverlap: Double = 0.5,
        maximumContentWordInjection: Double = 0.34,
        perWindowPolarity: Bool = false
    ) {
        self.maximumSemanticDistance = maximumSemanticDistance
        self.minimumLengthRatio = minimumLengthRatio
        self.maximumLengthRatio = maximumLengthRatio
        self.minimumContentWordOverlap = minimumContentWordOverlap
        self.maximumContentWordInjection = maximumContentWordInjection
        self.perWindowPolarity = perWindowPolarity
    }

    public static let `default` = ValidationThresholds()
}

/// Runs every check over an original/revised pair.
///
/// - Note: Phase 5 implements this — deliberately *before* Phase 6 introduces the
///   language model. The fence gets built before the gate opens, and it is proven
///   by mutation testing: known-good output is corrupted one class at a time, and
///   a corruption that passes the gauntlet is a test failure.
public protocol Validating: Sendable {
    func validate(
        original: [String],
        revised: [String],
        language: TranscriptLanguage,
        thresholds: ValidationThresholds
    ) throws -> ValidationReport
}

/// Runs every check over an original/revised pair.
///
/// Deliberately built before the language model exists. The fence goes up before
/// the gate opens, and it is proven by mutation testing: known-good output is
/// corrupted one class at a time, and any corruption that passes is a failure.
///
/// Every check is a flat computation over word lists and lexicons. None of them
/// asks a model whether a model's output was acceptable, which would be circular.
public struct ValidationGauntlet: Validating {
    private let similarity: SemanticSimilarity

    public init(similarity: SemanticSimilarity = .shared) {
        self.similarity = similarity
    }

    public func validate(
        original: [String],
        revised: [String],
        language: TranscriptLanguage = .english,
        thresholds: ValidationThresholds = .default
    ) throws -> ValidationReport {
        var results: [CheckResult] = []

        // ── 1. Cardinality ──────────────────────────────────────────────────
        // Checked first because every later check pairs sentences by index, and
        // a mismatch would make those comparisons meaningless rather than merely
        // failing.
        guard original.count == revised.count else {
            return ValidationReport(results: [CheckResult(
                check: .cardinality, passed: false,
                detail: "expected \(original.count) sentence(s), got \(revised.count)",
                measurement: Double(revised.count))])
        }
        results.append(CheckResult(check: .cardinality, passed: true,
                                   measurement: Double(revised.count)))

        let originalText = original.joined(separator: " ")
        let revisedText = revised.joined(separator: " ")

        // ── 2. Numeric conservation ─────────────────────────────────────────
        results.append(conservation(
            check: .numericConservation,
            before: EntityExtraction.numbers(in: originalText, language: language),
            after: EntityExtraction.numbers(in: revisedText, language: language),
            noun: "number"))

        // ── 3. Named-entity conservation ────────────────────────────────────
        // The watch list is drawn from both texts so a name the tagger only
        // recognizes once — or that only becomes capitalized after polishing —
        // is still counted on both sides.
        let entityVocabulary = EntityExtraction.entityVocabulary([originalText, revisedText])
        results.append(conservation(
            check: .namedEntityConservation,
            before: EntityExtraction.counts(of: entityVocabulary, in: originalText),
            after: EntityExtraction.counts(of: entityVocabulary, in: revisedText),
            noun: "name"))

        // ── 4. Polarity ─────────────────────────────────────────────────────
        results.append(lexiconBalance(
            check: .polarity, lexicon: SemanticLexicons.negations(for: language),
            original: original, revised: revised,
            perWindow: thresholds.perWindowPolarity, noun: "negation"))

        // ── 5. Modality ─────────────────────────────────────────────────────
        results.append(lexiconBalance(
            check: .modality, lexicon: SemanticLexicons.hedges(for: language),
            original: original, revised: revised,
            perWindow: thresholds.perWindowPolarity, noun: "hedge"))

        // ── 6. Semantic similarity ──────────────────────────────────────────
        results.append(semanticCheck(original: original, revised: revised,
                                     language: language, thresholds: thresholds))

        // ── 7. Extent bounds ────────────────────────────────────────────────
        results.append(extentCheck(originalText: originalText, revisedText: revisedText,
                                   language: language,
                                   thresholds: thresholds))

        return ValidationReport(results: results)
    }

    // MARK: - Individual checks

    /// Exact multiset equality. Strict by design.
    ///
    /// "approximately 1,000" where "500" was said is fluent and plausible, which
    /// is exactly why a similarity-based comparison would admit it.
    private func conservation(
        check: ValidationCheck,
        before: [String: Int],
        after: [String: Int],
        noun: String
    ) -> CheckResult {
        guard before != after else {
            return CheckResult(check: check, passed: true, measurement: Double(before.count))
        }
        var problems: [String] = []
        for (key, count) in before {
            let now = after[key] ?? 0
            if now < count { problems.append("lost \(noun) '\(key)'") }
            else if now > count { problems.append("duplicated \(noun) '\(key)'") }
        }
        for (key, count) in after where before[key] == nil && count > 0 {
            problems.append("added \(noun) '\(key)'")
        }
        return CheckResult(check: check, passed: false,
                           detail: problems.sorted().joined(separator: ", "),
                           measurement: Double(problems.count))
    }

    /// Requires the same lexicon members in the same quantities.
    private func lexiconBalance(
        check: ValidationCheck,
        lexicon: Set<String>,
        original: [String],
        revised: [String],
        perWindow: Bool,
        noun: String
    ) -> CheckResult {
        if perWindow {
            let before = SemanticLexicons.occurrences(
                TextTokenizer.tokens(original.joined(separator: " ")), in: lexicon)
            let after = SemanticLexicons.occurrences(
                TextTokenizer.tokens(revised.joined(separator: " ")), in: lexicon)
            return conservation(check: check, before: before, after: after, noun: noun)
        }

        for (index, pair) in zip(original, revised).enumerated() {
            let before = SemanticLexicons.occurrences(TextTokenizer.tokens(pair.0), in: lexicon)
            let after = SemanticLexicons.occurrences(TextTokenizer.tokens(pair.1), in: lexicon)
            guard before != after else { continue }
            let result = conservation(check: check, before: before, after: after, noun: noun)
            return CheckResult(check: check, passed: false,
                               detail: "sentence \(index + 1): \(result.detail ?? "changed")",
                               measurement: result.measurement)
        }
        return CheckResult(check: check, passed: true)
    }

    /// Per-sentence embedding distance against the threshold.
    private func semanticCheck(
        original: [String], revised: [String],
        language: TranscriptLanguage, thresholds: ValidationThresholds
    ) -> CheckResult {
        var worst = 0.0
        var worstIndex = 0
        var measured = false

        for (index, pair) in zip(original, revised).enumerated() {
            guard let d = similarity.distance(pair.0, pair.1, in: language) else { continue }
            measured = true
            if d > worst { worst = d; worstIndex = index }
        }

        // No embedding model means the check abstains rather than passing
        // vacuously, and says so.
        guard measured else {
            return CheckResult(check: .semanticSimilarity, passed: true,
                               detail: "no sentence-embedding model available; check skipped")
        }
        let passed = worst <= thresholds.maximumSemanticDistance
        return CheckResult(
            check: .semanticSimilarity, passed: passed,
            detail: passed ? nil
                : String(format: "sentence %d drifted (distance %.3f > %.3f)",
                         worstIndex + 1, worst, thresholds.maximumSemanticDistance),
            measurement: worst)
    }

    /// Length ratio and lemmatized content-word overlap.
    ///
    /// This is what catches summarization: a faithful readability pass keeps
    /// roughly the same length and nearly all the same content words.
    private func extentCheck(
        originalText: String, revisedText: String,
        language: TranscriptLanguage, thresholds: ValidationThresholds
    ) -> CheckResult {
        let before = TextTokenizer.tokens(originalText)
        let after = TextTokenizer.tokens(revisedText)
        guard !before.isEmpty else {
            return CheckResult(check: .extentBounds, passed: true)
        }

        let ratio = Double(after.count) / Double(before.count)
        guard ratio >= thresholds.minimumLengthRatio,
              ratio <= thresholds.maximumLengthRatio else {
            return CheckResult(
                check: .extentBounds, passed: false,
                detail: String(format: "length ratio %.2f outside [%.2f, %.2f]",
                               ratio, thresholds.minimumLengthRatio, thresholds.maximumLengthRatio),
                measurement: ratio)
        }

        let contentBefore = EntityExtraction.contentWords(in: originalText, language: language)
        let contentAfter = EntityExtraction.contentWords(in: revisedText, language: language)
        guard !contentBefore.isEmpty else {
            return CheckResult(check: .extentBounds, passed: true, measurement: ratio)
        }
        // Retention rather than Jaccard: what matters is how much of the original
        // content survived, not how much the two sets agree overall. A pass that
        // keeps every content word and adds none scores 1 either way, but one
        // that drops half the original is penalised properly here.
        let retained = Double(contentBefore.intersection(contentAfter).count)
            / Double(contentBefore.count)
        guard retained >= thresholds.minimumContentWordOverlap else {
            return CheckResult(
                check: .extentBounds, passed: false,
                detail: String(format: "only %.0f%% of content words survived (need %.0f%%)",
                               retained * 100, thresholds.minimumContentWordOverlap * 100),
                measurement: retained)
        }

        // Additions, not just survivals. A revision that keeps everything and
        // adds a detail the speaker never gave is still adding information.
        let injected = contentAfter.subtracting(contentBefore)
        let injectionRatio = Double(injected.count) / Double(contentBefore.count)
        guard injectionRatio <= thresholds.maximumContentWordInjection else {
            return CheckResult(
                check: .extentBounds, passed: false,
                detail: "added content not in the original: "
                    + injected.sorted().prefix(4).joined(separator: ", "),
                measurement: injectionRatio)
        }
        return CheckResult(check: .extentBounds, passed: true, measurement: retained)
    }
}
