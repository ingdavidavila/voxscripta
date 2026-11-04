// The word-comparison key must agree with Swift's
// `text.lowercased().filter { $0.isLetter || $0.isNumber }`. The first six cases
// are the ones the Swift-vs-C++ parity suite found disagreeing; the rest cover
// what the category test has to get right to keep agreeing.

#include <string>

#include "harness.hpp"
#include "voxscripta/transcript_merger.hpp"
#include "voxscripta/unicode_lite.hpp"

using namespace voxscripta;

namespace {
std::string key(const std::string& s) { return TranscriptMerger::normalize(s); }
}  // namespace

// ── The six cases from the parity suite ─────────────────────────────────────

VS_TEST("Comparison key", "A typographic apostrophe is dropped, as punctuation") {
    VS_EXPECT(key("it\xE2\x80\x99s") == "its");        // U+2019
    VS_EXPECT(key("don\xE2\x80\x99t") == "dont");
}

VS_TEST("Comparison key", "Accented capitals fold to accented lower case") {
    VS_EXPECT(key("CAF\xC3\x89") == "caf\xC3\xA9");    // CAFÉ -> café
    VS_EXPECT(key("NI\xC3\x91O") == "ni\xC3\xB1o");    // NIÑO -> niño
}

VS_TEST("Comparison key", "Spanish inverted marks are dropped") {
    VS_EXPECT(key("\xC2\xBFQu\xC3\xA9?") == "qu\xC3\xA9");  // ¿Qué? -> qué
    VS_EXPECT(key("\xC2\xA1hola") == "hola");
}

VS_TEST("Comparison key", "An em dash between letters is dropped, not kept") {
    VS_EXPECT(key("a\xE2\x80\x94" "b") == "ab");       // U+2014
}

// ── What the category test has to get right ─────────────────────────────────

VS_TEST("Comparison key", "ASCII behaves as before") {
    VS_EXPECT(key("Hello, World!") == "helloworld");
    VS_EXPECT(key("1,000") == "1000");
    VS_EXPECT(key("") == "");
    VS_EXPECT(key("...") == "");
}

VS_TEST("Comparison key", "Punctuation of any kind never separates two spellings of a word") {
    // The reason this matters: a seam where one chunk ends "hola" and the next
    // begins "¡hola" must still be recognised as the same word.
    VS_EXPECT(key("hola") == key("\xC2\xA1hola"));
    VS_EXPECT(key("hola") == key("\xC2\xA1Hola!"));
    VS_EXPECT(key("it's") == key("it\xE2\x80\x99s"));
    VS_EXPECT(key("\xE2\x80\x9Cquote\xE2\x80\x9D") == "quote");  // curly double quotes
    VS_EXPECT(key("wait\xE2\x80\xA6") == "wait");                // ellipsis
    VS_EXPECT(key("\xC2\xAB" "bonjour\xC2\xBB") == "bonjour");   // guillemets
}

VS_TEST("Comparison key", "Greek and Cyrillic fold case") {
    VS_EXPECT(key("\xCE\x91\xCE\x98\xCE\x97\xCE\x9D\xCE\x91") == "\xCE\xB1\xCE\xB8\xCE\xB7\xCE\xBD\xCE\xB1");  // ΑΘΗΝΑ -> αθηνα
    VS_EXPECT(key("\xD0\x9F\xD0\xA0\xD0\x98\xD0\x92\xD0\x95\xD0\xA2, \xD0\x9C\xD0\x98\xD0\xA0") ==
              "\xD0\xBF\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82\xD0\xBC\xD0\xB8\xD1\x80");  // ПРИВЕТ, МИР -> приветмир
}

VS_TEST("Comparison key", "CJK text is kept and fullwidth punctuation dropped") {
    VS_EXPECT(key("\xE4\xBD\xA0\xE5\xA5\xBD\xEF\xBC\x8C\xE4\xB8\x96\xE7\x95\x8C") ==
              "\xE4\xBD\xA0\xE5\xA5\xBD\xE4\xB8\x96\xE7\x95\x8C");  // 你好，世界 -> 你好世界
}

VS_TEST("Comparison key", "Digits of other scripts count as numbers") {
    VS_EXPECT(key("\xEF\xBC\x91\xEF\xBC\x92") == "\xEF\xBC\x91\xEF\xBC\x92");  // fullwidth 12 stays
    VS_EXPECT(key("\xD9\xA1\xD9\xA2") == "\xD9\xA1\xD9\xA2");                    // Arabic-Indic 12 stays
    VS_EXPECT(key("\xC2\xBD") == "\xC2\xBD");                                     // ½ is a number
}

VS_TEST("Comparison key", "A combining accent stays with its letter, and is dropped without one") {
    // "é" written as e + U+0301 is one Character in Swift, and a letter.
    VS_EXPECT(key("cafe\xCC\x81") == "cafe\xCC\x81");
    // A lone combining mark has no letter to ride on.
    VS_EXPECT(key("\xCC\x81") == "");
    VS_EXPECT(key("-\xCC\x81") == "");
}

VS_TEST("Comparison key", "Symbols and emoji are not words") {
    VS_EXPECT(key("\xF0\x9F\x98\x80") == "");          // grinning face
    VS_EXPECT(key("\xE2\x82\xAC" "5") == "5");          // € is a symbol, 5 is a number
    VS_EXPECT(key("a\xC2\xA0" "b") == "ab");            // no-break space
}

VS_TEST("Comparison key", "Malformed UTF-8 never throws and never leaks stray bytes") {
    VS_EXPECT(key("a\xFF" "b") == "ab");                // U+FFFD is a symbol
    VS_EXPECT(key("caf\xC3") == "caf");                 // truncated sequence
    VS_EXPECT(key("\xC0\x80") == "");                   // overlong NUL
}

VS_TEST("Comparison key", "The key is idempotent") {
    for (const char* s : {"CAF\xC3\x89", "\xC2\xBFQu\xC3\xA9?", "it\xE2\x80\x99s", "\xD0\x9F\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82", "x1,2"}) {
        VS_EXPECT(key(key(s)) == key(s));
    }
}

VS_TEST("Comparison key", "UTF-8 round-trips through the decoder") {
    const std::string text = "a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80";
    std::string again;
    for (char32_t cp : unicode::decode_utf8(text)) unicode::append_utf8(again, cp);
    VS_EXPECT(again == text);
}

// ── The merger itself ───────────────────────────────────────────────────────

VS_TEST("Transcript merger", "A seam with punctuation on one side still de-duplicates") {
    // One chunk ends "... hola amigos" and the next begins "¡Hola, amigos!".
    TranscriptMerger merger;
    auto w = [](const char* t, double a) { return Word{t, seconds(a), seconds(a + 0.4), {}}; };
    const std::vector<Word> previous = {w("dijo", 1.0), w("hola", 2.0), w("amigos", 3.0)};
    const std::vector<Word> current = {w("\xC2\xA1Hola,", 2.05), w("amigos!", 3.05), w("hoy", 4.0)};
    VS_EXPECT_EQ(merger.longest_overlap(previous, current), 2);
}
