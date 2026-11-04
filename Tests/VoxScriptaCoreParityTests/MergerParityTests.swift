import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaCoreCxx
import VoxScriptaCxxShim
@testable import VoxScriptaTranscription

/// Holds the C++ transcript merger to the Swift original.
///
/// `normalize` is the whole basis of overlap matching: two chunks are spliced
/// where their normalized words agree. If the two implementations normalize
/// differently, one platform splices where the other does not, and the
/// visible result is duplicated or dropped words at a chunk seam — the
/// hardest defect to notice and the worst to ship.
@Suite("Transcript merger parity")
struct MergerParityTests {

    /// The cases that used to diverge, now held.
    ///
    /// These were wrapped in `withKnownIssue` while the C++ port normalized
    /// bytes and Swift normalized Unicode. The port now decodes UTF-8 and
    /// applies a category test — letter or number, plus trailing combining
    /// marks — rather than a punctuation blocklist, so they agree and the
    /// wrapper is gone.
    static let agreeing: [String] = [
        "hello", "Hello", "HELLO", "hello, world!", "it's",
        "one two", "42", "",
        "caf\u{00E9}",
        "ni\u{00F1}o",
        "it\u{2019}s",
        "don\u{2019}t",
        "CAF\u{00C9}",
        "NI\u{00D1}O",
        "\u{00BF}Qu\u{00E9}?",
        "\u{00A1}Hola!",
        "a\u{2014}b",
    ]

    private func normalized(_ text: String) -> (swift: String, cxx: String) {
        (TranscriptMerger.normalize(text), String(voxscripta.shim.normalized(text)))
    }

    @Test("normalize agrees on text both can handle", arguments: agreeing)
    func normalizeAgrees(text: String) {
        let (swift, cxx) = normalized(text)
        #expect(swift == cxx,
                "\(debugging(text)): Swift \(debugging(swift)), C++ \(debugging(cxx))")
    }

    /// Scripts and cases beyond the six, to find where the tables end.
    ///
    /// The port's letter and number tables cover the common blocks and its
    /// case folding is explicit per range, so somewhere there is a letter it
    /// drops that Swift keeps. Better to know where than to meet it in a
    /// transcript. Reported as one list rather than one failure per case, so
    /// the gaps can be read together.
    static let probes: [String] = [
        "\u{039F}\u{0394}\u{039F}\u{03A3}",       // ΟΔΟΣ — final sigma context
        "\u{03A3}\u{03A3}",                         // ΣΣ
        "\u{041C}\u{041E}\u{0421}\u{041A}\u{0412}\u{0410}",  // МОСКВА
        "\u{1E9E}",                                  // ẞ capital sharp s
        "STRA\u{00DF}E",
        "\u{0130}stanbul",                           // İ Turkish dotted capital
        "VI\u{1EC6}T",                               // Vietnamese, Latin Extended Additional
        "\u{05E9}\u{05DC}\u{05D5}\u{05DD}",       // שלום Hebrew
        "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}", // مرحبا Arabic
        "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}", // สวัสดี Thai
        "\u{30AB}\u{30BF}\u{30AB}\u{30CA}",       // カタカナ
        "\u{3072}\u{3089}\u{304C}\u{306A}",       // ひらがな
        "\u{D55C}\u{AD6D}\u{C5B4}",                // 한국어
        "\u{4E2D}\u{6587}",                         // 中文
        "\u{FF21}\u{FF22}\u{FF23}",                      // ＡＢＣ fullwidth
        "e\u{0301}",                                 // e + combining acute
        "\u{0928}\u{092E}\u{0938}\u{094D}\u{0924}\u{0947}", // नमस्ते Devanagari
        "\u{10E5}\u{10D0}\u{10E0}\u{10D7}",       // ქართ Georgian
        "\u{00B2}",                                  // ² superscript two
        "\u{2460}",                                  // ① circled one
        "\u{2167}",                                  // Ⅷ roman numeral
        "\u{0661}\u{0662}",                         // ١٢ Arabic-Indic digits
        "caf\u{00E9} \u{1F44D}",                    // emoji, both should drop
    ]

    /// Latin Extended-B case pairs the port does not fold.
    ///
    /// The only two gaps found in 25 probes spanning Greek, Cyrillic,
    /// Turkish, Vietnamese, Hebrew, Arabic, Thai, kana, Hangul, CJK,
    /// fullwidth, Devanagari, Georgian, combining marks and the wider number
    /// categories. Everything else agrees.
    ///
    /// Ǆ is a Croatian and Serbian Latin digraph; Ʒ is IPA and Skolt Sami.
    /// Neither is likely in a transcript this app will see soon, which is why
    /// they are recorded rather than treated as urgent — but they are
    /// recorded, because "unlikely" is how the apostrophe got missed.
    @Test("Latin Extended-B digraphs are not folded", arguments: [
        "\u{01C4}",   // Ǆ → Swift ǆ U+01C6
        "\u{01B7}",   // Ʒ → Swift ʒ U+0292
    ])
    func latinExtendedBDiverges(text: String) {
        withKnownIssue("C++ case folding does not cover these Latin Extended-B pairs") {
            let (swift, cxx) = normalized(text)
            #expect(swift == cxx,
                    "\(debugging(text)): Swift \(debugging(swift)), C++ \(debugging(cxx))")
        }
    }

    @Test("probe: 23 scripts and number categories agree")
    func probeTheTables() {
        var gaps: [String] = []
        for text in Self.probes {
            let (swift, cxx) = normalized(text)
            if swift != cxx {
                gaps.append("\(debugging(text)) → Swift \(debugging(swift)) | C++ \(debugging(cxx))")
            }
        }
        let summary = gaps.isEmpty
            ? "no gaps"
            : "\(gaps.count) of \(Self.probes.count) diverge:\n" + gaps.joined(separator: "\n")
        #expect(gaps.isEmpty, "\(summary)")
    }

    private func debugging(_ s: String) -> String {
        "\"\(s)\" [" + s.unicodeScalars.map { String(format: "U+%04X", $0.value) }
            .joined(separator: " ") + "]"
    }
}
