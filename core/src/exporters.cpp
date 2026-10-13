#include "voxscripta/exporters.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>

#include "voxscripta/errors.hpp"

namespace voxscripta {

const char* file_extension(ExportFormat format) {
    switch (format) {
        case ExportFormat::plain_text: return "txt";
        case ExportFormat::markdown: return "md";
        case ExportFormat::sub_rip: return "srt";
        case ExportFormat::web_vtt: return "vtt";
    }
    return "txt";
}

bool format_from_extension(const std::string& extension, ExportFormat& out) {
    std::string key;
    for (unsigned char c : extension) {
        if (!std::isspace(c)) key += static_cast<char>(std::tolower(c));
    }
    for (ExportFormat f : {ExportFormat::plain_text, ExportFormat::markdown, ExportFormat::sub_rip,
                           ExportFormat::web_vtt}) {
        if (key == file_extension(f)) {
            out = f;
            return true;
        }
    }
    return false;
}

namespace {

std::string timecode(MediaTime time, char separator) {
    // Negative times cannot occur on a media timeline; clamping is cheaper than a
    // malformed file if one ever does.
    const std::int64_t total = std::max<std::int64_t>(time.nanoseconds(), 0);
    char buffer[40];
    std::snprintf(buffer, sizeof buffer, "%02lld:%02lld:%02lld%c%03lld",
                  static_cast<long long>(total / 3'600'000'000'000LL),
                  static_cast<long long>(total / 60'000'000'000LL % 60),
                  static_cast<long long>(total / 1'000'000'000LL % 60), separator,
                  static_cast<long long>(total / 1'000'000LL % 1000));
    return buffer;
}

/// Characters, not bytes: a UTF-8 continuation byte does not count.
int char_count(const std::string& s) {
    return static_cast<int>(std::count_if(s.begin(), s.end(),
                                          [](unsigned char c) { return (c & 0xC0) != 0x80; }));
}

std::string trimmed(const std::string& s) {
    const auto first = s.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    return s.substr(first, s.find_last_not_of(" \t\r\n") - first + 1);
}

bool has_gap(const TranscriptSegment& s) {
    return std::find(s.warnings.begin(), s.warnings.end(), SegmentWarning::transcription_gap) !=
           s.warnings.end();
}

std::string join(const std::vector<std::string>& parts, const std::string& separator) {
    std::string out;
    for (std::size_t i = 0; i < parts.size(); ++i) out += (i ? separator : std::string()) + parts[i];
    return out;
}

}  // namespace

std::string timecode_subrip(MediaTime time) { return timecode(time, ','); }
std::string timecode_webvtt(MediaTime time) { return timecode(time, '.'); }

// ── Cues ────────────────────────────────────────────────────────────────────

namespace {

struct Piece {
    TimeRange range;
    std::string text;
};

std::vector<std::string> wrap(const std::string& text, int maximum_characters) {
    if (char_count(text) <= maximum_characters / 2) return {text};
    std::vector<std::string> words;
    for (std::size_t i = 0; i < text.size();) {
        const auto start = text.find_first_not_of(' ', i);
        if (start == std::string::npos) break;
        const auto end = text.find(' ', start);
        words.push_back(text.substr(start, end == std::string::npos ? end : end - start));
        i = end == std::string::npos ? text.size() : end;
    }
    if (words.size() <= 1) return {text};

    // Balance the two lines rather than filling the first: a long line above a
    // two-word line reads badly.
    const int target = char_count(text) / 2;
    std::vector<std::string> first;
    int length = 0;
    for (const auto& word : words) {
        if (length >= target) break;
        first.push_back(word);
        length += char_count(word) + 1;
    }
    std::vector<std::string> second(words.begin() + static_cast<std::ptrdiff_t>(first.size()), words.end());
    if (first.empty() || second.empty()) return {text};
    return {join(first, " "), join(second, " ")};
}

}  // namespace

std::vector<SubtitleCue> CueBuilder::cues(const Transcript& transcript) const {
    std::vector<SubtitleCue> out;
    int index = 1;

    for (const TranscriptSegment& segment : transcript.segments) {
        const std::string text = trimmed(segment.text);
        // A gap marker has no text; an empty cue would show a blank caption box.
        if (text.empty()) continue;

        std::vector<Piece> pieces;
        const Piece whole{segment.range(), segment.text};
        const bool needs_split = segment.range().duration() > maximum_duration ||
                                 char_count(segment.text) > maximum_characters;
        if (!needs_split || segment.words.empty()) {
            // Without word timings there is nothing to split on that would stay
            // aligned, so the segment is left whole rather than guessed at.
            pieces.push_back(whole);
        } else {
            std::vector<Word> current;
            auto flush = [&] {
                if (current.empty()) return;
                const MediaTime end =
                    MediaTime::max(current.back().original_end, current.front().original_start + minimum_duration);
                std::vector<std::string> texts;
                for (const Word& w : current) texts.push_back(w.text);
                pieces.push_back({TimeRange(current.front().original_start,
                                            MediaTime::max(MediaTime::min(end, segment.original_end),
                                                           current.front().original_start)),
                                  join(texts, " ")});
                current.clear();
            };
            for (const Word& word : segment.words) {
                int candidate_length = char_count(word.text);
                for (const Word& w : current) candidate_length += char_count(w.text) + 1;
                const MediaTime candidate_duration =
                    current.empty() ? MediaTime::zero() : word.original_end - current.front().original_start;
                if (!current.empty() &&
                    (candidate_length > maximum_characters || candidate_duration > maximum_duration)) {
                    flush();
                }
                current.push_back(word);
            }
            flush();
            if (pieces.empty()) pieces.push_back(whole);
        }

        for (const Piece& piece : pieces) {
            out.push_back({index++, piece.range, wrap(piece.text, maximum_characters)});
        }
    }
    return out;
}

// ── Exporters ───────────────────────────────────────────────────────────────

std::string export_plain_text(const Transcript& transcript, const ExportOptions& options) {
    std::vector<std::string> lines;
    for (std::size_t index = 0; index < transcript.segments.size(); ++index) {
        const TranscriptSegment& segment = transcript.segments[index];
        if (segment.text.empty() && !has_gap(segment)) continue;

        std::string line;
        if (options.include_timestamps) line += "[" + segment.original_start.to_string() + "] ";
        // A gap is shown rather than silently closed up, so a reader knows where
        // the recording could not be transcribed.
        line += has_gap(segment) ? "[untranscribed: " + segment.original_start.to_string() + " \xE2\x80\x93 " +
                                       segment.original_end.to_string() + "]"
                                 : segment.text;

        const bool breaks_paragraph =
            index > 0 && segment.preceding_gap.value_or(MediaTime::zero()) >= options.paragraph_pause_threshold;
        if (breaks_paragraph || options.include_timestamps) {
            lines.push_back(breaks_paragraph && !lines.empty() ? "\n" + line : line);
        } else if (!lines.empty()) {
            lines.back() += " " + line;
        } else {
            lines.push_back(line);
        }
    }
    return join(lines, "\n");
}

std::string export_markdown(const Transcript& transcript, const ExportOptions& options) {
    std::string out = "# Transcript\n\n*Verbatim";
    if (auto range = transcript.time_range()) out += " \xC2\xB7 " + range->duration().to_string();
    out += " \xC2\xB7 " + std::to_string(transcript.word_count()) + " words*\n\n";

    // Escaped so a transcript containing Markdown syntax reads as text.
    for (char c : export_plain_text(transcript, options)) {
        if (std::string("*_`#[]<>").find(c) != std::string::npos) out += '\\';
        out += c;
    }
    return out + "\n";
}

std::string export_sub_rip(const Transcript& transcript) {
    const auto cues = CueBuilder{}.cues(transcript);
    if (cues.empty()) throw AnalysisFailed("export", "this transcript has no timed content");
    std::string out;
    for (const SubtitleCue& cue : cues) {
        out += std::to_string(cue.index) + "\n";
        out += timecode_subrip(cue.range.start_time()) + " --> " + timecode_subrip(cue.range.end_time()) + "\n";
        out += join(cue.lines, "\n") + "\n\n";
    }
    return out;
}

std::string export_web_vtt(const Transcript& transcript) {
    const auto cues = CueBuilder{}.cues(transcript);
    if (cues.empty()) throw AnalysisFailed("export", "this transcript has no timed content");
    std::string out = "WEBVTT\n\n";
    for (const SubtitleCue& cue : cues) {
        out += std::to_string(cue.index) + "\n";
        out += timecode_webvtt(cue.range.start_time()) + " --> " + timecode_webvtt(cue.range.end_time()) + "\n";
        out += join(cue.lines, "\n") + "\n\n";
    }
    return out;
}

std::string export_transcript(const Transcript& transcript, ExportFormat format, const ExportOptions& options) {
    switch (format) {
        case ExportFormat::plain_text: return export_plain_text(transcript, options);
        case ExportFormat::markdown: return export_markdown(transcript, options);
        case ExportFormat::sub_rip: return export_sub_rip(transcript);
        case ExportFormat::web_vtt: return export_web_vtt(transcript);
    }
    return {};
}

}  // namespace voxscripta
