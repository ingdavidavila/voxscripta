#pragma once

// A small, dependency-free slice of Unicode, enough for the merger's word
// comparison to agree with Swift's `text.lowercased().filter { $0.isLetter ||
// $0.isNumber }` on real transcripts.
//
// This is deliberately a category test ("is this a letter? a number?") rather
// than a list of punctuation to strip. A blocklist of punctuation ranges drifts
// from Swift the first time a transcript contains something outside it; a
// letter/number test only has to be right about what a letter is.
//
// It is NOT full Unicode. The letter and number tables cover the scripts
// recognisers emit in practice (Latin, Greek, Cyrillic, Armenian, Hebrew,
// Arabic, Indic and Southeast Asian main blocks, kana, Hangul, CJK ideographs,
// fullwidth forms). Case folding covers Basic Latin, Latin-1, Latin Extended-A
// and Additional, Greek, Cyrillic, Armenian and fullwidth Latin. Everything else
// is treated as caseless. Code points outside the tables count as neither
// letter nor number, so unknown scripts are dropped from comparison keys rather
// than compared byte for byte. The parity suite names the cases covered.

#include <string>
#include <vector>

namespace voxscripta::unicode {

/// Decodes UTF-8. A malformed byte becomes U+FFFD (as Swift does when it builds
/// a String from bad bytes) and decoding continues after it.
std::vector<char32_t> decode_utf8(const std::string& text);

/// Appends the UTF-8 encoding of `cp`.
void append_utf8(std::string& out, char32_t cp);

/// Roughly the Unicode Alphabetic property.
bool is_letter(char32_t cp);

/// Roughly "has a numeric type": decimal digits of the common scripts, digit
/// superscripts and subscripts, vulgar fractions, number forms.
bool is_number(char32_t cp);

/// Combining marks and variation selectors, which Swift keeps attached to the
/// letter before them as one Character.
bool is_combining_mark(char32_t cp);

/// Lower-case form of `cp`, or `cp` itself when it has none in the tables.
/// U+0130 expands to two code points, so this appends to `out`.
void append_lowercase(std::u32string& out, char32_t cp);

/// `text.lowercased()` followed by keeping only letters and numbers, each with
/// the combining marks that follow it. Comparison keys, not display text.
std::string letters_and_numbers_lowercased(const std::string& text);

}  // namespace voxscripta::unicode
