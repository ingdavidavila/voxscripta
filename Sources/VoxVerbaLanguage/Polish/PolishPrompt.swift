import Foundation

/// The frozen instructions given to the model.
///
/// Versioned and recorded in `Provenance`. Changing the wording changes the
/// output, so a transcript has to say which prompt produced it — otherwise two
/// runs of "the same" pipeline are not comparable.
public enum PolishPrompt {
    public static let version = "polish-v1"

    /// The standing instructions for every window.
    ///
    /// Written as prohibitions rather than goals. "Improve readability" invites
    /// the model to demonstrate improvement, which is how numbers get rounded and
    /// hedges get tidied away; an explicit list of things it must not touch
    /// measurably reduces the rejection rate.
    public static let instructions = """
        You rewrite spoken transcript sentences so they read well in print.

        Rewrite for grammar, sentence structure, punctuation and clarity.

        Keep the speaker's own words. Do not replace a word with a synonym: if
        they said "wrong", do not write "inaccurate"; if they said "approve", do
        not write "endorse". You are tidying how the sentence is built, not
        choosing better vocabulary than the speaker did.

        You must never:
        - change, round, or reformat any number, quantity, date, or amount
        - change, add, or remove any person, place, company, or product name
        - add or remove a negation; "did not approve" must never become "approved"
        - remove a hedge; "might", "probably", "roughly" and "seems" must survive
        - add any fact, detail, example, or explanation that is not already present
        - remove information, summarize, or shorten the meaning
        - merge two sentences into one, or split one into two
        - change an opinion, judgement, or how strongly something is claimed
        - substitute a synonym for a word the speaker actually used

        Return exactly as many sentences as you were given, in the same order.
        If a sentence already reads well, return it unchanged.
        """

    /// A stricter retry after a window has failed validation.
    ///
    /// Names the specific violations, because a generic "try harder" produces the
    /// same output. Reminding the model what it broke is what makes the retry
    /// worth doing at all.
    public static func retryInstructions(violations: [String]) -> String {
        """
        \(instructions)

        Your previous attempt was rejected for these reasons:
        \(violations.map { "- \($0)" }.joined(separator: "\n"))

        Fix only those problems. Stay as close to the original wording as you can.
        When in doubt, return the sentence unchanged.
        """
    }
}
