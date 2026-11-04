// Ported in spirit from ExportTests.swift (text, Markdown, SubRip, WebVTT; DOCX
// is not ported yet).

#include <algorithm>
#include <sstream>

#include "harness.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/exporters.hpp"

using namespace voxscripta;

namespace {

Word word(const std::string& text, double a, double b) { return {text, seconds(a), seconds(b), {}}; }

TranscriptSegment segment(const std::vector<Word>& words, std::optional<double> gap = {}) {
    TranscriptSegment s;
    s.words = words;
    for (const auto& w : words) s.text += (s.text.empty() ? "" : " ") + w.text;
    s.original_start = words.front().original_start;
    s.original_end = words.back().original_end;
    if (gap) s.preceding_gap = seconds(*gap);
    return s;
}

Transcript sample() {
    Transcript t;
    t.segments = {segment({word("Hello", 1.0, 1.4), word("there.", 1.5, 2.0)}),
                  segment({word("How", 2.2, 2.4), word("are", 2.5, 2.7), word("you?", 2.8, 3.2)}, 0.2),
                  segment({word("New", 8.0, 8.3), word("paragraph.", 8.4, 9.0)}, 4.8)};
    return t;
}

bool contains(const std::string& haystack, const std::string& needle) {
    return haystack.find(needle) != std::string::npos;
}

}  // namespace

VS_TEST("Export", "SubRip and WebVTT differ only in the fraction separator") {
    VS_EXPECT(timecode_subrip(milliseconds(1234)) == "00:00:01,234");
    VS_EXPECT(timecode_webvtt(milliseconds(1234)) == "00:00:01.234");
}

VS_TEST("Export", "Millisecond precision is exact") {
    VS_EXPECT(timecode_subrip(milliseconds(59'999)) == "00:00:59,999");
    VS_EXPECT(timecode_subrip(milliseconds(60'000)) == "00:01:00,000");
    VS_EXPECT(timecode_subrip(MediaTime(-5)) == "00:00:00,000");  // clamped, never malformed
}

VS_TEST("Export", "A six-hour recording formats correctly") {
    VS_EXPECT(timecode_subrip(seconds(6 * 3600 + 59 * 60 + 59)) == "06:59:59,000");
}

VS_TEST("Export", "SubRip has the structure players expect") {
    const std::string srt = export_sub_rip(sample());
    VS_EXPECT(srt.rfind("1\n00:00:01,000 --> 00:00:02,000\nHello there.\n\n", 0) == 0);
    VS_EXPECT(contains(srt, "2\n00:00:02,200 --> 00:00:03,200\nHow are you?\n\n"));
    VS_EXPECT(contains(srt, "3\n00:00:08,000 --> 00:00:09,000\nNew paragraph.\n\n"));
}

VS_TEST("Export", "WebVTT starts with its required header") {
    const std::string vtt = export_web_vtt(sample());
    VS_EXPECT(vtt.rfind("WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\n", 0) == 0);
}

VS_TEST("Export", "Long segments are split into readable cues and lose no words") {
    std::vector<Word> words;
    std::string expected;
    for (int i = 0; i < 40; ++i) {
        words.push_back(word("word" + std::to_string(i), i * 0.5, i * 0.5 + 0.4));
        expected += (i ? " " : "") + words.back().text;
    }
    Transcript t;
    t.segments = {segment(words)};  // 20 s and ~280 characters in one segment
    const auto cues = CueBuilder{}.cues(t);
    VS_EXPECT(cues.size() > 3);

    std::string rebuilt;
    for (const auto& c : cues) {
        VS_EXPECT(c.range.duration() <= seconds(6) + milliseconds(1));
        VS_EXPECT(c.lines.size() <= 2);
        for (const auto& line : c.lines) rebuilt += (rebuilt.empty() ? "" : " ") + line;
    }
    VS_EXPECT(rebuilt == expected);
}

VS_TEST("Export", "Cue times match the transcript's word timings") {
    const auto cues = CueBuilder{}.cues(sample());
    VS_EXPECT_EQ(cues.size(), std::size_t{3});
    VS_EXPECT(cues[1].range.start_time() == seconds(2.2));
    VS_EXPECT(cues[1].range.end_time() == seconds(3.2));
}

VS_TEST("Export", "A transcript with no timed content is refused, not silently empty") {
    Transcript empty;
    VS_EXPECT_THROWS(export_sub_rip(empty), AnalysisFailed);
    VS_EXPECT_THROWS(export_web_vtt(empty), AnalysisFailed);
}

VS_TEST("Export", "A gap marker produces no empty caption") {
    Transcript t = sample();
    TranscriptSegment gap;
    gap.original_start = seconds(3.2);
    gap.original_end = seconds(8.0);
    gap.warnings.push_back(SegmentWarning::transcription_gap);
    t.segments.insert(t.segments.begin() + 2, gap);
    VS_EXPECT_EQ(CueBuilder{}.cues(t).size(), std::size_t{3});
}

VS_TEST("Export", "Plain text keeps paragraph structure") {
    const std::string text = export_plain_text(sample());
    VS_EXPECT(text == "Hello there. How are you?\n\nNew paragraph.");
}

VS_TEST("Export", "An untranscribed gap is shown in plain text, not closed up") {
    Transcript t = sample();
    TranscriptSegment gap;
    gap.original_start = seconds(3.2);
    gap.original_end = seconds(8.0);
    gap.warnings.push_back(SegmentWarning::transcription_gap);
    t.segments.insert(t.segments.begin() + 2, gap);
    VS_EXPECT(contains(export_plain_text(t), "[untranscribed: "));
}

VS_TEST("Export", "Timestamps appear when asked for") {
    ExportOptions o;
    o.include_timestamps = true;
    const std::string text = export_plain_text(sample(), o);
    VS_EXPECT(text.rfind("[0:01.000] Hello there.\n", 0) == 0);
}

VS_TEST("Export", "Markdown escapes syntax so a transcript is not reformatted") {
    Transcript t;
    t.segments = {segment({word("*bold*", 0, 1), word("#tag", 1, 2), word("[link]", 2, 3)})};
    const std::string md = export_markdown(t);
    VS_EXPECT(contains(md, "\\*bold\\* \\#tag \\[link\\]"));
    VS_EXPECT(md.rfind("# Transcript\n\n*Verbatim", 0) == 0);
}

VS_TEST("Export", "Formats are looked up by extension") {
    ExportFormat f;
    VS_EXPECT(format_from_extension(" SRT ", f) && f == ExportFormat::sub_rip);
    VS_EXPECT(format_from_extension("md", f) && f == ExportFormat::markdown);
    VS_EXPECT(!format_from_extension("pdf", f));
}
