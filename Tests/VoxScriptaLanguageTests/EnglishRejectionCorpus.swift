import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// Whether POLISH is safe in English with the embedding gone.
///
/// On Apple, English has two independent defences against a reversed meaning:
/// the lexical polarity count and the semantic-distance check. Off Apple there
/// is no `NLEmbedding`, so only the first survives — which is the position
/// Spanish has always been in, and which the Spanish corpus measured as safe.
///
/// Reasoning from Spanish to English would be reasoning in the wrong
/// direction. Spanish negation is tidy: usually a `no` immediately before the
/// verb. English negation sprawls — *hardly*, *scarcely*, *fails to*,
/// *far from*, *no longer*, *neither … nor*, and prefixes like *un-* and
/// *dis-*. A word list that catches everything in Spanish could plausibly miss
/// things in English, so the easier case cannot stand in for the harder one.
///
/// This corpus is therefore written to be hard on purpose. If it were nothing
/// but deleted *not*s it would return a reassuring number that meant nothing.
enum EnglishRejectionCorpus {

    struct Case: Sendable {
        let original: String
        let revised: String
        let note: String
    }

    /// Plain negation, the form a word list is built for.
    static let plainNegation: [Case] = [
        .init(original: "We did not approve the budget on Monday.",
              revised: "We approved the budget on Monday.",
              note: "not deleted"),
        .init(original: "The server is not responding.",
              revised: "The server is responding.", note: "not deleted"),
        .init(original: "She never accepted the terms.",
              revised: "She accepted the terms.", note: "never deleted"),
        .init(original: "I can finish by Friday.",
              revised: "I cannot finish by Friday.", note: "negation added"),
        .init(original: "We saw nothing in the report.",
              revised: "We saw something in the report.",
              note: "nothing to something"),
        .init(original: "Nobody signed off on this.",
              revised: "Everybody signed off on this.",
              note: "nobody to everybody"),
        .init(original: "The second test did not pass either.",
              revised: "The second test passed.", note: "not and either deleted"),
    ]

    /// Negation that is not spelled with a negative word.
    ///
    /// This is the class the Spanish corpus never had to contain, and the
    /// reason that corpus cannot answer for English.
    static let obliqueNegation: [Case] = [
        .init(original: "We hardly finished on time.",
              revised: "We finished on time.", note: "hardly deleted"),
        .init(original: "They scarcely covered the costs.",
              revised: "They covered the costs.", note: "scarcely deleted"),
        .init(original: "The build fails to complete.",
              revised: "The build completes.", note: "fails to, verb flipped"),
        .init(original: "That is far from settled.",
              revised: "That is settled.", note: "far from deleted"),
        .init(original: "The licence is no longer valid.",
              revised: "The licence is valid.", note: "no longer deleted"),
        .init(original: "Few people agreed with the plan.",
              revised: "People agreed with the plan.", note: "few deleted"),
        .init(original: "Neither option was acceptable.",
              revised: "Both options were acceptable.",
              note: "neither to both"),
        .init(original: "The result was unlikely.",
              revised: "The result was likely.", note: "un- prefix dropped"),
        .init(original: "They disagreed about the schedule.",
              revised: "They agreed about the schedule.",
              note: "dis- prefix dropped"),
        .init(original: "We stopped short of approving it.",
              revised: "We approved it.", note: "stopped short of deleted"),
        .init(original: "It is anything but finished.",
              revised: "It is finished.", note: "anything but deleted"),
        .init(original: "He denied signing the contract.",
              revised: "He signed the contract.", note: "denied deleted"),
    ]

    /// Everything else §14 names: quantities, names, hedges, invention.
    static let otherCorruptions: [Case] = [
        .init(original: "We sold five hundred units last month.",
              revised: "We sold 900 units last month.", note: "quantity changed"),
        .init(original: "The report runs to thirty-two pages.",
              revised: "The report runs to about thirty pages.",
              note: "quantity rounded"),
        .init(original: "The meeting starts at half past nine.",
              revised: "The meeting starts at ten.", note: "time changed"),
        .init(original: "Maria reviewed the contract with Hernandez.",
              revised: "Maria reviewed the contract with Fernandez.",
              note: "surname altered"),
        .init(original: "We discussed it in the Madrid office.",
              revised: "We discussed it in the Barcelona office.",
              note: "place substituted"),
        .init(original: "We might finish before Friday.",
              revised: "We will finish before Friday.", note: "hedge removed"),
        .init(original: "I think the cost rises slightly.",
              revised: "The cost rises.", note: "hedge removed, detail lost"),
        .init(original: "We reviewed the report.",
              revised: "We reviewed the quarterly sales report with the finance "
                     + "team on Tuesday morning.", note: "detail invented"),
        .init(original: "We approved the budget on Monday.",
              revised: "The cat sat on the mat.", note: "unrelated text"),
        .init(original: "The team delivered the project on time and without "
                      + "incident.",
              revised: "Fine.", note: "meaning discarded"),
    ]

    /// Rewrites polish should be allowed to make. A gauntlet that refuses
    /// these is not safe, it is useless.
    static let legitimate: [Case] = [
        .init(original: "we approved the budget on monday",
              revised: "We approved the budget on Monday.",
              note: "capitalisation and full stop"),
        .init(original: "the server is not responding",
              revised: "The server is not responding.", note: "punctuation only"),
        .init(original: "so the the headcount plan is um forty two roles",
              revised: "The headcount plan is forty-two roles.",
              note: "disfluencies removed, quantity kept"),
        .init(original: "we might finish before friday",
              revised: "We might finish before Friday.", note: "hedge preserved"),
        .init(original: "she never accepted the terms",
              revised: "She never accepted the terms.", note: "negation preserved"),
        .init(original: "maria reviewed the contract with hernandez",
              revised: "Maria reviewed the contract with Hernandez.",
              note: "names preserved"),
        .init(original: "we hardly finished on time",
              revised: "We hardly finished on time.",
              note: "oblique negation preserved"),
        .init(original: "the build fails to complete",
              revised: "The build fails to complete.",
              note: "oblique negation preserved"),
    ]

    static var allCorruptions: [Case] {
        plainNegation + obliqueNegation + otherCorruptions
    }
}
