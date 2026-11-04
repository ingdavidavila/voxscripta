#include "voxscripta/unicode_lite.hpp"

#include <algorithm>
#include <iterator>

namespace voxscripta::unicode {

namespace {

struct Range {
    char32_t first;
    char32_t last;
};

bool in(char32_t cp, const Range* begin, const Range* end) {
    // The tables are sorted and non-overlapping.
    const Range* it = std::upper_bound(begin, end, cp, [](char32_t value, const Range& r) { return value < r.first; });
    return it != begin && cp <= (it - 1)->last;
}

template <std::size_t N>
bool in(char32_t cp, const Range (&table)[N]) {
    return in(cp, std::begin(table), std::end(table));
}

// Letters (Alphabetic, approximately). Sorted.
constexpr Range kLetters[] = {
    {0x41, 0x5A},     {0x61, 0x7A},     {0xAA, 0xAA},     {0xB5, 0xB5},     {0xBA, 0xBA},
    {0xC0, 0xD6},     {0xD8, 0xF6},     {0xF8, 0x2C1},    {0x2C6, 0x2D1},   {0x2E0, 0x2E4},
    {0x370, 0x374},   {0x376, 0x377},   {0x37A, 0x37D},   {0x37F, 0x37F},   {0x386, 0x386},
    {0x388, 0x3F5},   {0x3F7, 0x481},   {0x48A, 0x52F},   {0x531, 0x556},   {0x561, 0x587},
    {0x5D0, 0x5EA},   {0x5EF, 0x5F2},   {0x620, 0x64A},   {0x66E, 0x66F},   {0x671, 0x6D3},
    {0x6D5, 0x6D5},   {0x6FA, 0x6FC},   {0x904, 0x939},   {0x958, 0x961},   {0x985, 0x9B9},
    {0xA05, 0xA39},   {0xA85, 0xAB9},   {0xB05, 0xB39},   {0xB85, 0xBB9},   {0xC05, 0xC39},
    {0xC85, 0xCB9},   {0xD05, 0xD3A},   {0xD85, 0xDC6},   {0xE01, 0xE30},   {0xE32, 0xE33},
    {0xE40, 0xE46},   {0xE81, 0xEB0},   {0xF40, 0xF6C},   {0x1000, 0x102A}, {0x10A0, 0x10C5},
    {0x10D0, 0x10FA}, {0x10FC, 0x1248}, {0x1250, 0x135A}, {0x13A0, 0x13F5}, {0x1401, 0x166C},
    {0x1780, 0x17B3}, {0x1820, 0x1878}, {0x1D00, 0x1DBF}, {0x1E00, 0x1FBC}, {0x1FBE, 0x1FBE},
    {0x1FC2, 0x1FCC}, {0x1FD0, 0x1FDB}, {0x1FE0, 0x1FEC}, {0x1FF2, 0x1FFC}, {0x2071, 0x2071},
    {0x207F, 0x207F}, {0x2090, 0x209C}, {0x2102, 0x2102}, {0x2107, 0x2107}, {0x210A, 0x2113},
    {0x2115, 0x2115}, {0x2119, 0x211D}, {0x2124, 0x2124}, {0x2126, 0x2126}, {0x2128, 0x2128},
    {0x212A, 0x212D}, {0x212F, 0x2139}, {0x2160, 0x2188}, {0x2C00, 0x2CE4}, {0x2D00, 0x2D25},
    {0x2D30, 0x2D67}, {0x3005, 0x3007}, {0x3021, 0x3029}, {0x3031, 0x3035}, {0x3041, 0x3096},
    {0x309D, 0x309F}, {0x30A1, 0x30FA}, {0x30FC, 0x30FF}, {0x3105, 0x312F}, {0x3131, 0x318E},
    {0x31A0, 0x31BF}, {0x31F0, 0x31FF}, {0x3400, 0x4DBF}, {0x4E00, 0x9FFF}, {0xA000, 0xA48C},
    {0xA640, 0xA66E}, {0xA680, 0xA69D}, {0xA722, 0xA788}, {0xA78B, 0xA7FF}, {0xAC00, 0xD7A3},
    {0xF900, 0xFAFF}, {0xFB00, 0xFB06}, {0xFB13, 0xFB17}, {0xFB1D, 0xFB1D}, {0xFB1F, 0xFB28},
    {0xFB2A, 0xFB4F}, {0xFB50, 0xFBB1}, {0xFBD3, 0xFD3D}, {0xFD50, 0xFDFB}, {0xFE70, 0xFEFC},
    {0xFF21, 0xFF3A}, {0xFF41, 0xFF5A}, {0xFF66, 0xFFDC}, {0x1D400, 0x1D6A5}, {0x1D6A8, 0x1D7CB},
    {0x20000, 0x2FA1F},
};

// Numbers (a numeric type). Sorted.
constexpr Range kNumbers[] = {
    {0x30, 0x39},     {0xB2, 0xB3},     {0xB9, 0xB9},     {0xBC, 0xBE},     {0x660, 0x669},
    {0x6F0, 0x6F9},   {0x966, 0x96F},   {0x9E6, 0x9EF},   {0xA66, 0xA6F},   {0xAE6, 0xAEF},
    {0xB66, 0xB6F},   {0xBE6, 0xBF2},   {0xC66, 0xC6F},   {0xCE6, 0xCEF},   {0xD66, 0xD78},
    {0xE50, 0xE59},   {0xED0, 0xED9},   {0xF20, 0xF33},   {0x1040, 0x1049}, {0x2070, 0x2070},
    {0x2074, 0x2079}, {0x2080, 0x2089}, {0x2150, 0x2182}, {0x2185, 0x2189}, {0x2460, 0x249B},
    {0x24EA, 0x24FF}, {0x2776, 0x2793}, {0x3007, 0x3007}, {0x3021, 0x3029}, {0x3038, 0x303A},
    {0x3220, 0x3229}, {0xFF10, 0xFF19}, {0x1D7CE, 0x1D7FF},
};

constexpr Range kMarks[] = {
    {0x300, 0x36F},   {0x483, 0x489},   {0x591, 0x5BD},   {0x5BF, 0x5BF},   {0x5C1, 0x5C2},
    {0x610, 0x61A},   {0x64B, 0x65F},   {0x670, 0x670},   {0x6D6, 0x6DC},   {0x900, 0x903},
    {0x93A, 0x94F},   {0x951, 0x957},   {0xE31, 0xE31},   {0xE34, 0xE3A},   {0xE47, 0xE4E},
    {0x1AB0, 0x1AFF}, {0x1DC0, 0x1DFF}, {0x20D0, 0x20FF}, {0x3099, 0x309A}, {0xFE00, 0xFE0F},
    {0xFE20, 0xFE2F},
};

}  // namespace

std::vector<char32_t> decode_utf8(const std::string& text) {
    std::vector<char32_t> out;
    out.reserve(text.size());
    const auto n = text.size();
    std::size_t i = 0;
    while (i < n) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        int length = 0;
        char32_t cp = 0;
        if (c < 0x80) { cp = c; length = 1; }
        else if (c >= 0xC2 && c <= 0xDF) { cp = c & 0x1Fu; length = 2; }
        else if (c >= 0xE0 && c <= 0xEF) { cp = c & 0x0Fu; length = 3; }
        else if (c >= 0xF0 && c <= 0xF4) { cp = c & 0x07u; length = 4; }
        else { out.push_back(0xFFFD); ++i; continue; }

        bool ok = i + static_cast<std::size_t>(length) <= n;
        for (int k = 1; ok && k < length; ++k) {
            const unsigned char cc = static_cast<unsigned char>(text[i + static_cast<std::size_t>(k)]);
            if ((cc & 0xC0) != 0x80) { ok = false; break; }
            cp = (cp << 6) | (cc & 0x3Fu);
        }
        // Reject overlong forms, surrogates and out-of-range values.
        if (ok) {
            if ((length == 3 && cp < 0x800) || (length == 4 && cp < 0x10000) || cp > 0x10FFFF ||
                (cp >= 0xD800 && cp <= 0xDFFF)) ok = false;
        }
        if (!ok) { out.push_back(0xFFFD); ++i; continue; }
        out.push_back(cp);
        i += static_cast<std::size_t>(length);
    }
    return out;
}

void append_utf8(std::string& out, char32_t cp) {
    if (cp < 0x80) {
        out += static_cast<char>(cp);
    } else if (cp < 0x800) {
        out += static_cast<char>(0xC0 | (cp >> 6));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += static_cast<char>(0xE0 | (cp >> 12));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
        out += static_cast<char>(0xF0 | (cp >> 18));
        out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        out += static_cast<char>(0x80 | (cp & 0x3F));
    }
}

bool is_letter(char32_t cp) { return in(cp, kLetters); }
bool is_number(char32_t cp) { return in(cp, kNumbers); }
bool is_combining_mark(char32_t cp) { return in(cp, kMarks); }

void append_lowercase(std::u32string& out, char32_t cp) {
    auto put = [&](char32_t v) { out.push_back(v); };

    if (cp < 0x80) { put(cp >= 'A' && cp <= 'Z' ? cp + 32 : cp); return; }
    if (cp >= 0xC0 && cp <= 0xDE && cp != 0xD7) { put(cp + 32); return; }          // Latin-1
    if (cp == 0x130) { put('i'); put(0x307); return; }                             // full lowercasing of İ
    if (cp >= 0x100 && cp <= 0x137) { put(cp % 2 == 0 ? cp + 1 : cp); return; }    // Latin Extended-A
    if (cp >= 0x139 && cp <= 0x148) { put(cp % 2 == 1 ? cp + 1 : cp); return; }
    if (cp >= 0x14A && cp <= 0x177) { put(cp % 2 == 0 ? cp + 1 : cp); return; }
    if (cp == 0x178) { put(0xFF); return; }
    if (cp >= 0x179 && cp <= 0x17E) { put(cp % 2 == 1 ? cp + 1 : cp); return; }
    if (cp == 0x386) { put(0x3AC); return; }                                       // Greek
    if (cp >= 0x388 && cp <= 0x38A) { put(cp + 37); return; }
    if (cp == 0x38C) { put(0x3CC); return; }
    if (cp == 0x38E || cp == 0x38F) { put(cp + 63); return; }
    if (cp >= 0x391 && cp <= 0x3AB && cp != 0x3A2) { put(cp + 32); return; }
    if (cp >= 0x400 && cp <= 0x40F) { put(cp + 80); return; }                      // Cyrillic
    if (cp >= 0x410 && cp <= 0x42F) { put(cp + 32); return; }
    if ((cp >= 0x460 && cp <= 0x481) || (cp >= 0x48A && cp <= 0x4BF) || (cp >= 0x4D0 && cp <= 0x52F)) {
        put(cp % 2 == 0 ? cp + 1 : cp);
        return;
    }
    if (cp == 0x4C0) { put(0x4CF); return; }
    if (cp >= 0x4C1 && cp <= 0x4CE) { put(cp % 2 == 1 ? cp + 1 : cp); return; }
    if (cp >= 0x531 && cp <= 0x556) { put(cp + 48); return; }                      // Armenian
    if (cp == 0x1E9E) { put(0xDF); return; }                                       // capital sharp s
    if (cp >= 0x1E00 && cp <= 0x1EFF && !(cp >= 0x1E96 && cp <= 0x1E9F)) {         // Latin Extended Additional
        put(cp % 2 == 0 ? cp + 1 : cp);
        return;
    }
    if (cp >= 0x2160 && cp <= 0x216F) { put(cp + 16); return; }                    // Roman numerals
    if (cp >= 0xFF21 && cp <= 0xFF3A) { put(cp + 32); return; }                    // fullwidth Latin
    put(cp);
}

std::string letters_and_numbers_lowercased(const std::string& text) {
    std::string out;
    bool previous_kept = false;  // a combining mark rides on the character before it
    for (char32_t cp : decode_utf8(text)) {
        if (is_letter(cp) || is_number(cp)) {
            std::u32string lowered;
            append_lowercase(lowered, cp);
            for (char32_t l : lowered) append_utf8(out, l);
            previous_kept = true;
        } else if (is_combining_mark(cp)) {
            if (previous_kept) append_utf8(out, cp);
        } else {
            previous_kept = false;
        }
    }
    return out;
}

}  // namespace voxscripta::unicode
