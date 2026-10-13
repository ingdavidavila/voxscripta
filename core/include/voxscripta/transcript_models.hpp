#pragma once

#include <optional>
#include <string>
#include <vector>

#include "voxscripta/media_time.hpp"
#include "voxscripta/time_range.hpp"

namespace voxscripta {

/// A single recognized word with its timing on the original timeline.
struct Word {
    std::string text;
    MediaTime original_start;
    MediaTime original_end;
    std::optional<float> confidence;
};

/// Something the pipeline noticed about a segment that the user should see.
enum class SegmentWarning {
    /// Overlap de-duplication could not find a confident splice point.
    merge_ambiguity,
    /// The engine reported low confidence across the segment.
    low_confidence,
    /// The span could not be transcribed after all retries; text is a placeholder.
    transcription_gap,
};

/// The unit of the transcript data model. Transcripts are never stored as one
/// string; this structure is what makes timestamps, subtitle export and
/// per-sentence provenance possible without re-deriving anything.
///
/// Unlike the Swift TranscriptSegment there is no random SegmentID/ChunkID here:
/// identity belongs to whoever persists the transcript. `chunk_sequence` records
/// which work unit produced the segment, or -1 for segments made during merge.
struct TranscriptSegment {
    int chunk_sequence = -1;
    MediaTime original_start;
    MediaTime original_end;
    std::string text;  // UTF-8
    std::vector<Word> words;
    std::optional<float> confidence;
    /// Silence immediately before this segment. Drives paragraph breaks.
    std::optional<MediaTime> preceding_gap;
    std::vector<SegmentWarning> warnings;

    TimeRange range() const { return TimeRange(original_start, original_end); }
};

}  // namespace voxscripta
