import Foundation
import VoxScriptaCore

/// The outcome of a character-level comparison.
public struct CERResult: Sendable, Codable, CustomStringConvertible {
    public let referenceCharacters: Int
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int

    public init(referenceCharacters: Int, substitutions: Int, deletions: Int, insertions: Int) {
        self.referenceCharacters = referenceCharacters
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
    }

    public var rate: Double {
        guard referenceCharacters > 0 else {
            return insertions > 0 ? 1 : 0
        }
        return Double(substitutions + deletions + insertions) / Double(referenceCharacters)
    }

    public var accuracy: Double { Swift.max(0, 1 - rate) }

    public var description: String {
        String(format: "CER %.1f%% (S%d D%d I%d of %d chars)",
               rate * 100, substitutions, deletions, insertions, referenceCharacters)
    }
}

/// Character-level error rate.
///
/// This exists alongside ``WordErrorRate`` because the two answer different
/// questions and word error rate alone is misleading in both directions.
///
/// A one-letter slip — "trimestre" for "trimestré", a dropped plural — costs a
/// whole word at the word level, so word error rate reports it as the same
/// severity as a word invented from nothing. Spanish and other inflected
/// languages take that penalty constantly, which is part of why a Spanish
/// figure looks worse than an English one for the same quality of hearing.
/// Character error rate separates "nearly right" from "wrong", and the gap
/// between the two numbers is itself the signal: a high word rate with a low
/// character rate is an orthography problem, and the reverse is a hearing
/// problem.
public enum CharacterErrorRate {

    /// Compares two transcripts character by character.
    ///
    /// Normalized the same way word error rate normalizes: spoken numbers fold
    /// to digits under the given language's rules, so notation is not counted
    /// as error. Case and runs of whitespace are also folded, because neither
    /// is something the engine is being graded on here.
    public static func measure(reference: String, hypothesis: String,
                               language: TranscriptLanguage = .english) -> CERResult {
        let r = Array(normalize(reference, in: language))
        let h = Array(normalize(hypothesis, in: language))
        return measure(reference: r, hypothesis: h)
    }

    /// The exact text the comparison runs on.
    ///
    /// Public because a reported rate is hard to argue with unless the caller
    /// can see what was actually compared.
    public static func normalize(_ text: String, in language: TranscriptLanguage) -> String {
        // Reuse the word tokenizer so the two metrics agree about what the text
        // says. Scoring them on differently-normalized text would make the
        // comparison between the two rates meaningless, which is the one thing
        // this metric is for.
        TextTokenizer.comparableTokens(text, in: language).joined(separator: " ")
    }

    public static func measure(reference: [Character], hypothesis: [Character]) -> CERResult {
        let n = reference.count, m = hypothesis.count
        guard n > 0 else {
            return CERResult(referenceCharacters: 0, substitutions: 0,
                             deletions: 0, insertions: m)
        }
        guard m > 0 else {
            return CERResult(referenceCharacters: n, substitutions: 0,
                             deletions: n, insertions: 0)
        }

        // Levenshtein with operation counts, two rows at a time. Characters
        // make the matrix far larger than the word version, so holding the
        // whole thing would be wasteful on the long cases — a six-minute
        // reference runs to thousands of characters.
        struct Cell { var cost = 0; var sub = 0; var del = 0; var ins = 0 }

        var previous = (0...m).map { j in Cell(cost: j, sub: 0, del: 0, ins: j) }
        var current = [Cell](repeating: Cell(), count: m + 1)

        for i in 1...n {
            current[0] = Cell(cost: i, sub: 0, del: i, ins: 0)
            for j in 1...m {
                if reference[i - 1] == hypothesis[j - 1] {
                    current[j] = previous[j - 1]
                    current[j].cost = previous[j - 1].cost
                    continue
                }
                let substitution = previous[j - 1].cost
                let deletion = previous[j].cost
                let insertion = current[j - 1].cost
                let best = Swift.min(substitution, deletion, insertion)

                if best == substitution {
                    var cell = previous[j - 1]
                    cell.cost = best + 1
                    cell.sub += 1
                    current[j] = cell
                } else if best == deletion {
                    var cell = previous[j]
                    cell.cost = best + 1
                    cell.del += 1
                    current[j] = cell
                } else {
                    var cell = current[j - 1]
                    cell.cost = best + 1
                    cell.ins += 1
                    current[j] = cell
                }
            }
            swap(&previous, &current)
        }

        let final = previous[m]
        return CERResult(referenceCharacters: n, substitutions: final.sub,
                         deletions: final.del, insertions: final.ins)
    }
}
