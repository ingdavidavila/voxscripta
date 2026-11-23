import Foundation
import VoxScriptaCore

/// Which words differed, and how.
///
/// ``WordErrorRate`` counts substitutions, deletions and insertions and throws
/// away which words they were. That is enough for synthesized audio, where the
/// speaker is a program and reads the script exactly. It is not enough for real
/// speech: when a person reads a passage aloud, some of the difference is the
/// recogniser mishearing and some is the reader misreading, and a rate alone
/// cannot tell those apart. Seeing the pairs can.
public enum Alignment {

    public enum Operation: Sendable, Hashable {
        case match(String)
        /// Heard as something else.
        case substitution(reference: String, hypothesis: String)
        /// Spoken but missing from the transcript.
        case deletion(String)
        /// In the transcript but not in the reference.
        case insertion(String)

        public var isMatch: Bool { if case .match = self { return true }; return false }
    }

    /// The edit path between two transcripts, in reference order.
    ///
    /// Same recurrence as the rate, kept separately rather than folded in: the
    /// rate runs on long references where holding the whole matrix would be
    /// wasteful, and this one needs the matrix to walk back through. Charging
    /// every rate measurement for a backtrace nobody reads would be the wrong
    /// trade.
    public static func align(reference: [String], hypothesis: [String]) -> [Operation] {
        let n = reference.count, m = hypothesis.count
        if n == 0 { return hypothesis.map { .insertion($0) } }
        if m == 0 { return reference.map { .deletion($0) } }

        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                if reference[i - 1] == hypothesis[j - 1] {
                    cost[i][j] = cost[i - 1][j - 1]
                } else {
                    cost[i][j] = 1 + Swift.min(cost[i - 1][j - 1],   // substitute
                                               cost[i - 1][j],       // delete
                                               cost[i][j - 1])       // insert
                }
            }
        }

        var operations: [Operation] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1] {
                operations.append(.match(reference[i - 1]))
                i -= 1; j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                operations.append(.substitution(reference: reference[i - 1],
                                                hypothesis: hypothesis[j - 1]))
                i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                operations.append(.deletion(reference[i - 1]))
                i -= 1
            } else {
                operations.append(.insertion(hypothesis[j - 1]))
                j -= 1
            }
        }
        return operations.reversed()
    }

    /// The alignment of two transcripts, normalized the way the rates are.
    public static func align(reference: String, hypothesis: String,
                             language: TranscriptLanguage = .english) -> [Operation] {
        align(reference: TextTokenizer.comparableTokens(reference, in: language),
              hypothesis: TextTokenizer.comparableTokens(hypothesis, in: language))
    }

    /// Every difference, with the reference words either side of it.
    ///
    /// Context is what makes the list usable. "quarter heard as courter" is
    /// ambiguous on its own; "in the third quarter → courter" is not, and the
    /// difference decides whether anyone needs to act.
    public static func differences(_ operations: [Operation],
                                   context: Int = 3) -> [(text: String, kind: String)] {
        var out: [(text: String, kind: String)] = []
        for (index, operation) in operations.enumerated() where !operation.isMatch {
            let before = operations[Swift.max(0, index - context)..<index]
                .compactMap { if case .match(let w) = $0 { return w } else { return nil } }
                .joined(separator: " ")
            switch operation {
            case .match:
                continue
            case .substitution(let reference, let hypothesis):
                out.append(("…\(before) [\(reference) → \(hypothesis)]", "substitution"))
            case .deletion(let word):
                out.append(("…\(before) [\(word) → —]", "deletion"))
            case .insertion(let word):
                out.append(("…\(before) [— → \(word)]", "insertion"))
            }
        }
        return out
    }
}
