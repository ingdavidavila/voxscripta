import Foundation

/// Canonicalizes numbers written as words into digits.
///
/// Speech engines normalize aggressively: "five hundred" comes back as "500" and
/// "third" as "3rd". Two parts of VoxVerba have to see through that.
///
/// Word error rate would otherwise count a correct transcription as three errors
/// for writing the number the way people write numbers. And the polish
/// validator's numeric-conservation check (§14) has to recognize that "500" and
/// "five hundred" are the same quantity while "1,000" is not — which is exactly
/// the transformation that must be caught.
public enum SpokenNumbers {

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    /// Ordinal words mapped to their cardinal value.
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1_000,
    ]

    /// Rewrites runs of number words into a single digit token.
    ///
    /// - Parameter tokens: Lower-cased, punctuation-stripped words.
    public static func canonicalize(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]

            // A token already written in digits: strip separators and any
            // ordinal suffix so "3rd", "3" and "third" all land on "3".
            if let digits = numericValue(of: token) {
                out.append(digits)
                index += 1
                continue
            }

            if let (value, consumed) = parseNumberRun(tokens, from: index) {
                out.append(String(value))
                index += consumed
                continue
            }

            out.append(token)
            index += 1
        }
        return out
    }

    /// The canonical digit string for an already-numeric token, or `nil`.
    private static func numericValue(of token: String) -> String? {
        var body = token.replacingOccurrences(of: ",", with: "")
        for suffix in ["st", "nd", "rd", "th"] where body.hasSuffix(suffix) {
            let stem = String(body.dropLast(2))
            if !stem.isEmpty, stem.allSatisfy(\.isNumber) { body = stem }
        }
        guard !body.isEmpty, body.allSatisfy(\.isNumber) else { return nil }
        // Drop leading zeros without turning "0" into "".
        let trimmed = String(body.drop { $0 == "0" })
        return trimmed.isEmpty ? "0" : trimmed
    }

    /// Parses a run of number words starting at `start`.
    ///
    /// - Returns: The value and how many tokens it consumed, or `nil` when the
    ///   token at `start` does not begin a number.
    private static func parseNumberRun(_ tokens: [String], from start: Int) -> (Int, Int)? {
        var total = 0        // completed scale groups
        var current = 0      // the group being built
        var index = start
        var consumed = 0
        var sawNumber = false

        while index < tokens.count {
            let token = tokens[index]

            if let value = units[token] ?? tens[token] {
                current += value
                sawNumber = true
            } else if let value = ordinals[token] {
                // An ordinal terminates the run: "twenty third" is 23, and
                // whatever follows is not part of the number.
                if value >= 100 {
                    current = Swift.max(current, 1) * value
                } else {
                    current += value
                }
                sawNumber = true
                index += 1
                consumed += 1
                break
            } else if let scale = scales[token] {
                guard sawNumber else { return nil }
                if scale == 100 {
                    current = Swift.max(current, 1) * scale
                } else {
                    total += Swift.max(current, 1) * scale
                    current = 0
                }
            } else if token == "and" && sawNumber {
                // "three hundred and twelve" — only inside a run, and only when
                // a number actually follows.
                let next = index + 1
                guard next < tokens.count,
                      units[tokens[next]] != nil || tens[tokens[next]] != nil
                        || ordinals[tokens[next]] != nil
                else { break }
            } else {
                break
            }
            index += 1
            consumed += 1
        }

        guard sawNumber else { return nil }
        return (total + current, consumed)
    }
}
