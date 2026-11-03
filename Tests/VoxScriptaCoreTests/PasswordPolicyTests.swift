import Testing
import Foundation
@testable import VoxScriptaCore

/// The sign-up password rules.
///
/// Pinned here rather than in an interface because both interfaces read them:
/// a password that passed on a phone and failed on a desktop would be a bug
/// the user is right to report, and the only way to prevent it is one
/// definition.
@Suite("Password policy")
struct PasswordPolicyTests {

    private func failing(_ password: String) -> [String] {
        PasswordPolicy.evaluate(password).filter { !$0.satisfied }.map(\.id)
    }

    @Test("A password meeting every rule is accepted")
    func acceptsAGoodOne() {
        #expect(PasswordPolicy.accepts("Harbour7!"))
        #expect(failing("Harbour7!").isEmpty)
    }

    @Test("Each rule fails on its own, and says which")
    func eachRuleFailsAlone() {
        // Short, but otherwise complete.
        #expect(failing("Ab1!") == ["length"])
        // Long enough, a number and a symbol, no capital.
        #expect(failing("harbour7!") == ["uppercase"])
        // No digit.
        #expect(failing("Harbourrr!") == ["number"])
        // No symbol.
        #expect(failing("Harbour77") == ["special"])
    }

    @Test("Every rule is reported every time, met or not")
    func reportsTheWholeChecklist() {
        // So a form can show the full list filling in. Revealing one rule at a
        // time makes someone fail repeatedly at a test they were never shown.
        #expect(PasswordPolicy.evaluate("").count == 4)
        #expect(PasswordPolicy.evaluate("Harbour7!").count == 4)
        #expect(failing("").sorted() == ["length", "number", "special", "uppercase"])
    }

    @Test("A space does not count as a symbol")
    func spaceIsNotASymbol() {
        // Otherwise "Password 1" satisfies the rule, which is not what it is
        // for.
        #expect(!PasswordPolicy.accepts("Password 1"))
        #expect(failing("Password 1") == ["special"])
    }

    @Test("Symbols from any keyboard layout count")
    func symbolsAreNotAsciiOnly() {
        // Defined by exclusion rather than as a list of ASCII punctuation, so
        // a password typed on a Spanish or Japanese keyboard is judged the
        // same way as one typed on a US layout.
        #expect(PasswordPolicy.accepts("Harbour7¿"))
        #expect(PasswordPolicy.accepts("Harbour7€"))
        #expect(PasswordPolicy.accepts("Harbour7、"))
    }

    @Test("Accented letters are letters, not symbols")
    func accentsAreLetters() {
        #expect(failing("Habanero7") == ["special"])
        #expect(failing("Habañero7") == ["special"])
    }

    @Test("Length counts characters a person typed, not bytes")
    func lengthIsCharacters() {
        // An emoji is one character to the person choosing it. Counting UTF-8
        // bytes would call a four-character password long enough.
        #expect(failing("Aa1!🎧") == ["length"])
    }
}

@Suite("Email address shape")
struct EmailAddressTests {

    @Test("Obvious non-addresses are refused")
    func refusesNonsense() {
        #expect(!EmailAddress.looksValid(""))
        #expect(!EmailAddress.looksValid("david"))
        #expect(!EmailAddress.looksValid("@example.com"))
        #expect(!EmailAddress.looksValid("david@"))
        #expect(!EmailAddress.looksValid("david@example"))
        #expect(!EmailAddress.looksValid("david @example.com"))
        #expect(!EmailAddress.looksValid("david@.com"))
    }

    @Test("Real addresses are allowed through, including awkward ones")
    func allowsRealOnes() {
        // Permissive on purpose: the only authority on whether an address
        // works is whether mail to it arrives. Rejecting a valid address is a
        // worse failure than accepting a typo the confirmation step catches.
        #expect(EmailAddress.looksValid("david@example.com"))
        #expect(EmailAddress.looksValid("d.avila+voxscripta@example.co.uk"))
        #expect(EmailAddress.looksValid("david_avila@mail.example.museum"))
        #expect(EmailAddress.looksValid("用户@例子.广告"))
    }
}
