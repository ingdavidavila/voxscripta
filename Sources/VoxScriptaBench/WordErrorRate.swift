import Foundation
import VoxScriptaCore

/// The result of comparing a hypothesis transcript to a known reference.
public struct WERResult: Sendable, Codable, CustomStringConvertible {
    public let referenceWords: Int
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int

    public init(referenceWords: Int, substitutions: Int, deletions: Int, insertions: Int) {
        self.referenceWords = referenceWords
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
    }

    /// Word error rate. Can exceed 1 when the hypothesis invents words.
    public var rate: Double {
        referenceWords > 0
            ? Double(substitutions + deletions + insertions) / Double(referenceWords)
            : 0
    }

    public var accuracy: Double { Swift.max(0, 1 - rate) }

    public var description: String {
        String(format: "WER %.2f%%  (S %d  D %d  I %d  of %d words)",
               rate * 100, substitutions, deletions, insertions, referenceWords)
    }
}

/// Word error rate by Levenshtein alignment.
public enum WordErrorRate {

    /// Compares two transcripts.
    ///
    /// Both sides are tokenized with spoken numbers folded to digits, so a
    /// perfectly correct transcription that writes "500" where the speaker said
    /// "five hundred" is not counted as three errors. Notation differences are
    /// removed; content differences are not.
    public static func measure(reference: String, hypothesis: String) -> WERResult {
        measure(reference: TextTokenizer.comparableTokens(reference),
                hypothesis: TextTokenizer.comparableTokens(hypothesis))
    }

    public static func measure(reference: [String], hypothesis: [String]) -> WERResult {
        let n = reference.count, m = hypothesis.count
        guard n > 0 else {
            return WERResult(referenceWords: 0, substitutions: 0, deletions: 0, insertions: m)
        }
        guard m > 0 else {
            // Every reference word was dropped.
            return WERResult(referenceWords: n, substitutions: 0, deletions: n, insertions: 0)
        }

        // Full DP table, because the edit *types* are needed, not just the
        // distance — a caller wants to know whether the engine dropped words or
        // invented them.
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                if reference[i - 1] == hypothesis[j - 1] {
                    cost[i][j] = cost[i - 1][j - 1]
                } else {
                    cost[i][j] = 1 + Swift.min(cost[i - 1][j - 1],   // substitution
                                               cost[i - 1][j],       // deletion
                                               cost[i][j - 1])       // insertion
                }
            }
        }

        var substitutions = 0, deletions = 0, insertions = 0
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1], cost[i][j] == cost[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                substitutions += 1; i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                deletions += 1; i -= 1
            } else {
                insertions += 1; j -= 1
            }
        }

        return WERResult(referenceWords: n, substitutions: substitutions,
                         deletions: deletions, insertions: insertions)
    }
}
