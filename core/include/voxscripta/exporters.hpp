#pragma once

#include <string>
#include <vector>

#include "voxscripta/silence_models.hpp"
#include "voxscripta/transcript_models.hpp"

namespace voxscripta {

enum class ExportFormat { plain_text, markdown, sub_rip, web_vtt };

/// "txt", "md", "srt", "vtt".
const char* file_extension(ExportFormat format);
/// Looks a format up by extension (case-insensitive); false when unknown.
bool format_from_extension(const std::string& extension, ExportFormat& out);

struct ExportOptions {
    bool include_timestamps = false;
    /// Gaps at least this long start a new paragraph.
    MediaTime paragraph_pause_threshold = SilenceParameters{}.paragraph_pause_threshold;
};

/// `HH:MM:SS,mmm` (SubRip) and `HH:MM:SS.mmm` (WebVTT). The two differ only in
/// the separator, and getting it wrong yields a file that looks right and
/// silently fails to load, so both come from one place.
std::string timecode_subrip(MediaTime time);
std::string timecode_webvtt(MediaTime time);

struct SubtitleCue {
    int index;
    TimeRange range;
    std::vector<std::string> lines;
};

/// Turns a transcript into cues a player can display. A segment is not a
/// subtitle: long segments are split on word timings, which keeps the result
/// aligned with the audio rather than merely plausible.
struct CueBuilder {
    MediaTime maximum_duration = seconds(6);
    int maximum_characters = 84;
    MediaTime minimum_duration = milliseconds(800);

    std::vector<SubtitleCue> cues(const Transcript& transcript) const;
};

/// Each throws AnalysisFailed from the subtitle formats when nothing is timed.
std::string export_plain_text(const Transcript& transcript, const ExportOptions& options = {});
std::string export_markdown(const Transcript& transcript, const ExportOptions& options = {});
std::string export_sub_rip(const Transcript& transcript);
std::string export_web_vtt(const Transcript& transcript);

std::string export_transcript(const Transcript& transcript, ExportFormat format,
                              const ExportOptions& options = {});

}  // namespace voxscripta
