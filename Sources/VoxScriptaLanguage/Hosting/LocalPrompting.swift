import Foundation
import VoxScriptaCore

/// What every locally hosted model needs around it: the prompt, how much room
/// to give the answer, and how to strip what a small model adds to it.
///
/// Shared rather than copied. There are two local backends now — MLX on Apple
/// Silicon and llama.cpp everywhere else — and the whole point of the port is
/// that the rules live in one place. Two copies of this prompt would be two
/// behaviours, and the difference would show up as a transcript that reads
/// differently on a phone than on a PC for no reason anyone chose.
public enum LocalPrompting {

    /// Written in the language of the work, for the same reason the system
    /// backend's prompt is: English scaffolding around Spanish content makes a
    /// model answer in English, and a translated sentence fails every
    /// validation check there is.
    public static func prompt(for sentence: String, context: PolishContext,
                       language: TranscriptLanguage = .english) -> String {
        var parts: [String] = []
        let english = language == .english
        if !context.preceding.isEmpty {
            parts.append((english ? "Earlier context (do not rewrite, do not repeat):"
                                  : "Contexto anterior (no lo reescribas, no lo repitas):")
                         + "\n" + context.preceding.joined(separator: " "))
        }
        if !context.following.isEmpty {
            parts.append((english ? "Later context (do not rewrite, do not repeat):"
                                  : "Contexto posterior (no lo reescribas, no lo repitas):")
                         + "\n" + context.following.joined(separator: " "))
        }
        // The output contract is stated last, because a small model weights the
        // end of a prompt heavily.
        if english {
            parts.append("""
                Rewrite this one sentence:
                \(sentence)

                Reply with the rewritten sentence and nothing else. No preamble, no \
                quotation marks, no explanation.
                """)
        } else {
            parts.append("""
                Reescribe esta única frase, en español:
                \(sentence)

                Responde solo con la frase reescrita, en español. Sin preámbulo, sin \
                comillas, sin explicación.
                """)
        }
        return parts.joined(separator: "\n\n")
    }

    public static func tokenBudget(for sentence: String) -> Int {
        let words = sentence.split(separator: " ").count
        return Swift.max(64, Swift.min(512, words * 4))
    }

    /// Strips the scaffolding a small instruct model tends to add.
    ///
    /// Larger models follow "reply with the sentence and nothing else"; smaller
    /// ones often wrap the answer in quotes or a preamble. Rather than let the
    /// validator reject those as content changes, the obvious wrappers are removed
    /// here. Anything still unrecognizable falls back to the original sentence,
    /// which the validator then passes trivially.
    public static func clean(_ raw: String, fallingBackTo original: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Some models emit a reasoning block; keep only what follows it.
        if let range = text.range(of: "</think>") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A leading "Sure, here is the rewritten sentence:" and similar.
        if let colon = text.firstIndex(of: ":"),
           text.distance(from: text.startIndex, to: colon) < 60,
           text[text.startIndex..<colon].lowercased().contains("sentence") {
            text = String(text[text.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Surrounding quotation marks.
        for quote in ["\"", "'", "“", "”"] where text.hasPrefix(quote) && text.hasSuffix(quote) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        // Only the first line: a model that explains itself does so afterwards.
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
        }

        return text.isEmpty ? original : text
    }
}
