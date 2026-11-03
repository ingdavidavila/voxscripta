import Foundation

/// What makes a password acceptable when someone signs up.
///
/// In the engine rather than in an interface because both interfaces have to
/// agree. A rule that lived in one of them would let a password pass on a
/// phone and fail on a desktop, and the user would be right to call that a
/// bug. `Docs/PARITY.md` is the contract this serves, and it is the same
/// reasoning that moved the recording level curve and the library location
/// here.
///
/// - Important: This checks *composition*, which is a weak measure of strength
///   and a strong one of annoyance. `Passw0rd!` satisfies every rule here and
///   is among the first guesses any attacker makes. It is implemented because
///   it was asked for; what actually protects an account is rate limiting,
///   breach-list rejection and a second factor, none of which lives on this
///   side of the boundary. Whatever service ends up holding these credentials
///   should enforce its own rules too — this one exists to give the person
///   typing immediate, specific feedback, not to be the last line.
public enum PasswordPolicy {

    /// One requirement, and whether this password meets it.
    public struct Rule: Hashable, Sendable, Codable {
        /// Stable identifier, so an interface can key off it rather than off
        /// the wording.
        public let id: String
        /// What the person needs to do, phrased as the requirement.
        public let demand: String
        public let satisfied: Bool

        public init(id: String, demand: String, satisfied: Bool) {
            self.id = id
            self.demand = demand
            self.satisfied = satisfied
        }
    }

    public static let minimumLength = 8

    /// Every rule, each marked met or not.
    ///
    /// All of them are returned every time rather than only the failures, so
    /// an interface can show the whole checklist filling in as someone types.
    /// A form that reveals one rule at a time makes a person fail repeatedly
    /// at a test whose terms they were never shown.
    public static func evaluate(_ password: String) -> [Rule] {
        [
            Rule(id: "length",
                 demand: String(localized: "At least \(minimumLength) characters"),
                 satisfied: password.count >= minimumLength),
            Rule(id: "uppercase",
                 demand: String(localized: "One capital letter"),
                 satisfied: password.contains { $0.isUppercase }),
            Rule(id: "number",
                 demand: String(localized: "One number"),
                 satisfied: password.contains { $0.isNumber }),
            Rule(id: "special",
                 demand: String(localized: "One symbol, such as ! ? # or &"),
                 satisfied: password.contains(where: isSpecial)),
        ]
    }

    public static func accepts(_ password: String) -> Bool {
        evaluate(password).allSatisfy(\.satisfied)
    }

    /// A symbol: anything that is not a letter, a digit or whitespace.
    ///
    /// Defined by exclusion rather than as a list, so that a password typed on
    /// a Spanish, German or Japanese keyboard is judged the same way as one
    /// typed on a US layout. A fixed list of ASCII punctuation would quietly
    /// refuse characters people actually use.
    ///
    /// Whitespace is excluded deliberately: a space satisfying the symbol rule
    /// would make "Password 1" acceptable, which is not what the rule is for.
    private static func isSpecial(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber && !character.isWhitespace
    }
}

/// Whether a string could be an email address.
///
/// Deliberately permissive. The only authority on whether an address works is
/// whether mail sent to it arrives, so this rejects what is obviously not an
/// address — no `@`, nothing before or after it, no dot in the domain, spaces
/// — and lets everything else through to be confirmed by a real message. A
/// stricter pattern would reject valid addresses, which is a worse failure
/// than accepting a typo the confirmation step catches anyway.
public enum EmailAddress {
    public static func looksValid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), trimmed.count >= 5 else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".")
        else { return false }
        return true
    }
}
