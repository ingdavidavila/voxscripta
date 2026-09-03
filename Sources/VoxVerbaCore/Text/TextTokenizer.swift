import Foundation

/// Shared tokenization for comparison and measurement.
public enum TextTokenizer {

    /// Splits text into lower-cased word tokens, discarding punctuation.
    ///
    /// Digit-group separators are removed before splitting, so "1,000" stays one
    /// token rather than becoming "1" and "000" — which would otherwise compare
    /// unequal to "one thousand" and defeat the whole point of canonicalization.
    public static func tokens(_ text: String) -> [String] {
        stripDigitSeparators(text.lowercased())
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// Removes commas sitting between two digits.
    private static func stripDigitSeparators(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == ",",
               index > 0, characters[index - 1].isNumber,
               index + 1 < characters.count, characters[index + 1].isNumber {
                continue
            }
            out.append(character)
        }
        return out
    }

    /// Tokens with spoken numbers folded to digits.
    ///
    /// This is the form in which a transcript should be compared to another
    /// transcript — it removes differences of notation without removing
    /// differences of content.
    public static func comparableTokens(_ text: String) -> [String] {
        SpokenNumbers.canonicalize(tokens(text))
    }
}
