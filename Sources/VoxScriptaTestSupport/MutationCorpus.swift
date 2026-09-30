import Foundation

/// A legitimate readability improvement: meaning preserved, prose tidied.
///
/// These are the false-positive corpus. A validator that rejects them is useless
/// even if it catches every corruption, because every window would fall back to
/// CLEAN and POLISHED would do nothing.
public struct PolishPair: Sendable {
    public let name: String
    public let original: [String]
    public let revised: [String]

    public init(name: String, original: [String], revised: [String]) {
        self.name = name
        self.original = original
        self.revised = revised
    }
}

/// A deliberate corruption of good output, and the check expected to catch it.
public struct Mutation: Sendable {
    public let name: String
    /// What kind of damage this represents.
    public let category: String
    public let original: [String]
    public let corrupted: [String]
    /// The check that must reject this. Others may also fire.
    public let expectedCheck: String

    public init(name: String, category: String, original: [String],
                corrupted: [String], expectedCheck: String) {
        self.name = name
        self.category = category
        self.original = original
        self.corrupted = corrupted
        self.expectedCheck = expectedCheck
    }
}

/// The corpus the validation gauntlet is graded against.
///
/// Waiting for a model to produce bad output is neither reliable nor
/// reproducible, so known-good output is corrupted deliberately, one class at a
/// time. A corruption that survives the gauntlet is a test failure — which turns
/// "does it hallucinate?" into a deterministic assertion.
public enum MutationCorpus {

    /// Polish that must be accepted.
    public static let validPairs: [PolishPair] = [
        PolishPair(
            name: "disfluency and grammar",
            original: ["so basically what I wanted to say was that we should probably start on Monday"],
            revised: ["What I wanted to say is that we should probably start on Monday."]),
        PolishPair(
            name: "sentence structure",
            original: ["We sold 500 units in the third quarter and that was up from 312 in the second"],
            revised: ["We sold 500 units in the third quarter, up from 312 in the second."]),
        PolishPair(
            name: "punctuation and capitalization",
            original: ["david met with sarah chen and the team from northwind trading on tuesday"],
            revised: ["David met with Sarah Chen and the team from Northwind Trading on Tuesday."]),
        PolishPair(
            name: "negation preserved through rewording",
            original: ["we did not approve the revised budget and the committee has not scheduled a follow up"],
            revised: ["We did not approve the revised budget, and the committee has not scheduled a follow-up."]),
        PolishPair(
            name: "hedges preserved",
            original: ["it might be possible to finish by friday but I would probably plan for the following week"],
            revised: ["It might be possible to finish by Friday, but I would probably plan for the following week."]),
        PolishPair(
            name: "two sentences tidied",
            original: ["the numbers were wrong", "so we sent it back for review"],
            revised: ["The numbers were wrong.", "So we sent it back for review."]),
    ]

    /// Corruptions that must all be rejected.
    public static let mutations: [Mutation] = [
        // ── Numbers ─────────────────────────────────────────────────────────
        Mutation(name: "number changed", category: "numeric",
                 original: ["We sold 500 units last quarter."],
                 corrupted: ["We sold approximately 1,000 units last quarter."],
                 expectedCheck: "numericConservation"),
        Mutation(name: "number dropped", category: "numeric",
                 original: ["We sold 500 units, up from 312."],
                 corrupted: ["We sold 500 units, up from the previous quarter."],
                 expectedCheck: "numericConservation"),
        Mutation(name: "number invented", category: "numeric",
                 original: ["Revenue grew substantially this year."],
                 corrupted: ["Revenue grew 40 percent this year."],
                 expectedCheck: "numericConservation"),
        Mutation(name: "spoken number altered", category: "numeric",
                 original: ["We shipped five hundred orders."],
                 corrupted: ["We shipped six hundred orders."],
                 expectedCheck: "numericConservation"),

        // ── Names ───────────────────────────────────────────────────────────
        Mutation(name: "person renamed", category: "entity",
                 original: ["Sarah Chen approved the plan."],
                 corrupted: ["Rebecca Chen approved the plan."],
                 expectedCheck: "namedEntityConservation"),
        Mutation(name: "surname dropped", category: "entity",
                 original: ["David met Sarah Chen on Tuesday."],
                 corrupted: ["David met Sarah on Tuesday."],
                 expectedCheck: "namedEntityConservation"),
        Mutation(name: "organization invented", category: "entity",
                 original: ["The team reviewed the contract."],
                 corrupted: ["The Northwind team reviewed the contract."],
                 expectedCheck: "namedEntityConservation"),

        // ── Polarity ────────────────────────────────────────────────────────
        Mutation(name: "negation deleted", category: "polarity",
                 original: ["We did not approve the revised budget."],
                 corrupted: ["We approved the revised budget."],
                 expectedCheck: "polarity"),
        Mutation(name: "negation added", category: "polarity",
                 original: ["The committee scheduled a follow-up."],
                 corrupted: ["The committee has not scheduled a follow-up."],
                 expectedCheck: "polarity"),
        Mutation(name: "negation moved between clauses", category: "polarity",
                 original: ["We did not approve it.", "The committee met."],
                 corrupted: ["We approved it.", "The committee did not meet."],
                 expectedCheck: "polarity"),

        // ── Modality ────────────────────────────────────────────────────────
        Mutation(name: "hedge dropped", category: "modality",
                 original: ["It might be possible to finish by Friday."],
                 corrupted: ["It is possible to finish by Friday."],
                 expectedCheck: "modality"),
        Mutation(name: "qualified claim made absolute", category: "modality",
                 original: ["We would probably plan for the following week."],
                 corrupted: ["We will plan for the following week."],
                 expectedCheck: "modality"),
        Mutation(name: "certainty invented", category: "modality",
                 original: ["The build finishes in an hour."],
                 corrupted: ["The build probably finishes in about an hour."],
                 expectedCheck: "modality"),

        // ── Cardinality ─────────────────────────────────────────────────────
        Mutation(name: "sentences merged", category: "cardinality",
                 original: ["The numbers were wrong.", "We sent it back."],
                 corrupted: ["The numbers were wrong, so we sent it back."],
                 expectedCheck: "cardinality"),
        Mutation(name: "sentence dropped", category: "cardinality",
                 original: ["The numbers were wrong.", "We sent it back for review."],
                 corrupted: ["The numbers were wrong."],
                 expectedCheck: "cardinality"),
        Mutation(name: "sentence invented", category: "cardinality",
                 original: ["The numbers were wrong."],
                 corrupted: ["The numbers were wrong.", "We sent it back for review."],
                 expectedCheck: "cardinality"),

        // ── Extent ──────────────────────────────────────────────────────────
        Mutation(name: "summarized", category: "extent",
                 original: ["The committee reviewed the quarterly figures in detail and concluded that the reporting process needed substantial revision before the next cycle."],
                 corrupted: ["The committee wanted changes."],
                 expectedCheck: "extentBounds"),
        Mutation(name: "padded with invented detail", category: "extent",
                 original: ["We shipped it."],
                 corrupted: ["We shipped the completed product to the customer's warehouse in Boston on Thursday afternoon after the final inspection."],
                 expectedCheck: "extentBounds"),

        // ── Meaning ─────────────────────────────────────────────────────────
        Mutation(name: "meaning replaced with fluent unrelated text", category: "semantic",
                 original: ["The quarterly figures needed substantial revision."],
                 corrupted: ["The weather in Boston was pleasant that afternoon."],
                 expectedCheck: "semanticSimilarity"),
        Mutation(name: "opinion reversed", category: "semantic",
                 original: ["I thought the proposal was weak and poorly argued."],
                 corrupted: ["I thought the proposal was strong and well argued."],
                 expectedCheck: "semanticSimilarity"),
    ]

    /// Every category the corpus exercises.
    public static var categories: Set<String> { Set(mutations.map(\.category)) }
}
