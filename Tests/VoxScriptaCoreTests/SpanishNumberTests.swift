import Testing
import Foundation
@testable import VoxScriptaCore

/// Spanish number canonicalization.
///
/// The point of this, as in English, is that the numeric-conservation check
/// and the word error rate both have to see "quinientos" and "500" as the same
/// quantity. Spanish earns its own tests because it builds numbers differently
/// enough that the English parser would get several of these wrong.
@Suite("Spanish numbers")
struct SpanishNumberTests {

    private func canonical(_ text: String) -> String {
        TextTokenizer.comparableTokens(text, in: .spanish).joined(separator: " ")
    }

    @Test("Units, teens and the single-word twenties",
          arguments: [("cero", "0"), ("siete", "7"), ("quince", "15"),
                      ("dieciséis", "16"), ("dieciseis", "16"),
                      ("veinte", "20"), ("veintitrés", "23"), ("veintinueve", "29")])
    func units(spoken: String, expected: String) {
        #expect(canonical(spoken) == expected)
    }

    @Test("Tens joined to units by y",
          arguments: [("treinta y cuatro", "34"), ("noventa y nueve", "99"),
                      ("cincuenta", "50")])
    func tensWithConnector(spoken: String, expected: String) {
        #expect(canonical(spoken) == expected)
    }

    @Test("The hundreds are words in their own right",
          arguments: [("cien", "100"), ("ciento veintitrés", "123"),
                      ("quinientos", "500"), ("novecientos noventa y nueve", "999"),
                      ("doscientas cincuenta", "250")])
    func hundreds(spoken: String, expected: String) {
        // Not "two" plus "hundred": doscientos is 200 outright, which is why
        // the hundreds sit with the additive values rather than the scales.
        #expect(canonical(spoken) == expected)
    }

    @Test("Scales multiply",
          arguments: [("mil", "1000"), ("dos mil", "2000"),
                      ("veintiún mil", "21000"), ("un millón", "1000000"),
                      ("dos millones quinientos mil", "2500000")])
    func scales(spoken: String, expected: String) {
        #expect(canonical(spoken) == expected)
    }

    @Test("Spanish and digits agree, which is the whole purpose")
    func notationsAgree() {
        #expect(canonical("quinientos") == canonical("500"))
        #expect(canonical("mil") == canonical("1000"))
        #expect(canonical("ciento veintitrés") == canonical("123"))
        // And a different quantity still differs.
        #expect(canonical("quinientos") != canonical("900"))
    }

    // ── The two collisions English does not have ────────────────────────────

    @Test("The indefinite article is not the numeral one")
    func articleIsNotANumber() {
        // "un informe" must not become "1 informe". It counts as one only
        // directly before a scale, where the article cannot appear.
        #expect(canonical("un informe") == "un informe")
        #expect(canonical("una reunión") == "una reunión")
        #expect(canonical("un millón") == "1000000")
    }

    @Test("y stays a conjunction between two units")
    func conjunctionIsNotAConnector() {
        // "treinta y cuatro" is 34; "cinco y dos" is two numbers joined by the
        // ordinary conjunction, not seven.
        #expect(canonical("cinco y dos") == "5 y 2")
        #expect(canonical("pan y agua") == "pan y agua")
        #expect(canonical("treinta y cuatro") == "34")
    }

    @Test("segundo stays a unit of time")
    func secondsAreNotOrdinals() {
        // Folding "segundo" to 2 would turn a duration into a count, and
        // durations are far commoner in a transcript than ordinals.
        #expect(canonical("treinta segundos") == "30 segundos")
        #expect(canonical("un segundo") == "un segundo")
    }

    @Test("Other ordinals do fold")
    func ordinals() {
        #expect(canonical("el tercer punto") == "el 3 punto")
        #expect(canonical("la primera versión") == "la 1 versión")
        #expect(canonical("décimo") == "10")
    }

    @Test("Written ordinal markers are stripped",
          arguments: [("1.º", "1"), ("2.ª", "2"), ("3.er", "3"), ("15º", "15")])
    func writtenOrdinals(written: String, expected: String) {
        #expect(canonical(written) == expected)
    }

    @Test("English is unaffected")
    func englishUnchanged() {
        // The Spanish tables must not leak: these go through the English path.
        #expect(TextTokenizer.comparableTokens("five hundred").joined() == "500")
        #expect(TextTokenizer.comparableTokens("mil").joined() == "mil")
    }
}
