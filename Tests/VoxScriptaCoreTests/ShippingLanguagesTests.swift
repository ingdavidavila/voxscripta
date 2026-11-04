import Testing
import Foundation
@testable import VoxScriptaCore

/// What this version offers, and why the list is short.
@Suite("Shipping languages")
struct ShippingLanguagesTests {

    @Test("English and Spanish, English first")
    func englishAndSpanish() {
        #expect(ShippingLanguages.languageCodes == ["en", "es"])
        // Order matters in a picker, and English is the primary language.
        #expect(ShippingLanguages.locales.first?.hasPrefix("en") == true)
    }

    @Test("A Spanish region not on the list is still Spanish")
    func unlistedSpanishRegionsAccepted() {
        // Refusing es-AR because the list spells three other regions would be
        // pedantry; the recogniser treats them alike.
        for locale in ["es-AR", "es-CO", "es-CL", "es-US"] {
            #expect(ShippingLanguages.includes(locale), "\(locale) is Spanish")
        }
        for locale in ["en-AU", "en-CA", "en-IE"] {
            #expect(ShippingLanguages.includes(locale), "\(locale) is English")
        }
    }

    @Test("Everything else is refused")
    func othersRefused() {
        for locale in ["fr-FR", "de-DE", "pt-BR", "ca-ES", "el-GR", "ja-JP", ""] {
            #expect(!ShippingLanguages.includes(locale), "\(locale) is not offered")
        }
    }

    @Test("Portuguese is not Spanish and Catalan is not either")
    func neighboursRefused() {
        // Both are plausible mistakes in a list keyed on region: pt-PT and
        // ca-ES sit beside es-ES geographically and in most pickers.
        #expect(!ShippingLanguages.includes("pt-PT"))
        #expect(!ShippingLanguages.includes("ca-ES"))
    }

    @Test("Filtering a recogniser's own list keeps only what is offered")
    func filteringNarrows() {
        let reported = ["en-US", "fr-FR", "es-MX", "de-DE", "ja-JP", "es-AR"]
        #expect(ShippingLanguages.filter(reported) == ["en-US", "es-MX", "es-AR"])
    }

    @Test("The list matches what POLISH has actually been measured in")
    func matchesTheMeasuredLanguages() {
        // The boundary is the gauntlet, not the recogniser. English and
        // Spanish are the two languages with a rejection corpus behind them —
        // 29 of 29 and 20 of 20. If a third language is ever added here
        // without a corpus, this test is the place that should have stopped
        // it.
        #expect(ShippingLanguages.languageCodes.count == 2)
    }
}
