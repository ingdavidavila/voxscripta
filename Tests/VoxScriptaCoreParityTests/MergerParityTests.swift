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

    /// Text both normalizers handle identically today.
    static let agreeing: [String] = [
        "hello", "Hello", "HELLO", "hello, world!", "it's",
        "caf\u{00E9}",   // café — already lower case, so the bytes survive
        "ni\u{00F1}o",
        "one two", "42", "",
    ]

    /// Text they do **not** agree on. See `normalizeDiverges` below.
    static let diverging: [String] = [
        "it\u{2019}s",
        "don\u{2019}t",
        "CAF\u{00C9}",
        "NI\u{00D1}O",
        "\u{00BF}Qu\u{00E9}?",
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

    /// A real defect, recorded rather than hidden.
    ///
    /// Swift normalizes with full Unicode: `lowercased()` then keep anything
    /// `isLetter || isNumber`. The C++ port works on bytes — it lower-cases
    /// ASCII, drops ASCII punctuation, and keeps every byte ≥ 0x80 exactly as
    /// it found it. So they part company in two ways:
    ///
    ///  * **Non-ASCII punctuation survives in C++.** U+2019, the typographic
    ///    apostrophe, is the one that matters: recognisers emit it constantly,
    ///    so "don’t" normalizes to "dont" on Apple and "don’t" everywhere
    ///    else. Spanish ¿ and ¡ and the em dash behave the same way.
    ///  * **Accented capitals are not lower-cased in C++.** "NIÑO" becomes
    ///    "niño" on Apple and "niÑo" elsewhere.
    ///
    /// Why it is not merely cosmetic: `normalize` is how the merger decides
    /// two chunks overlap. Within one platform the comparison is at least
    /// self-consistent, but the C++ rule **fails to match** a word that
    /// carries punctuation against the same word without it — a seam where
    /// one chunk ends "hola" and the next begins "¡hola" deduplicates on
    /// Apple and does not off it. The visible result is a duplicated word at
    /// a chunk boundary, on Windows and Android, in exactly the languages
    /// this app went to the trouble of measuring.
    ///
    /// Not fixed here. Exact parity with Swift's Unicode semantics is not
    /// reachable in plain C++ without a Unicode table, and `core/` is being
    /// worked on from the Windows machine — a conflict there would cost more
    /// than this test saves. `withKnownIssue` keeps the suite honest: it goes
    /// green while the defect stands and fails the moment it is fixed, which
    /// is when someone should delete this and move these cases above.
    @Test("normalize diverges on non-ASCII, which is a defect", arguments: diverging)
    func normalizeDiverges(text: String) {
        withKnownIssue("C++ normalize is byte-based; Swift is Unicode-aware") {
            let (swift, cxx) = normalized(text)
            #expect(swift == cxx,
                    "\(debugging(text)): Swift \(debugging(swift)), C++ \(debugging(cxx))")
        }
    }

    private func debugging(_ s: String) -> String {
        "\"\(s)\" [" + s.unicodeScalars.map { String(format: "U+%04X", $0.value) }
            .joined(separator: " ") + "]"
    }
}
