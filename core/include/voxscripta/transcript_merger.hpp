#pragma once

#include <string>
#include <vector>

#include "voxscripta/chunk_models.hpp"
#include "voxscripta/chunk_scheduler.hpp"
#include "voxscripta/silence_models.hpp"
#include "voxscripta/transcript_models.hpp"

namespace voxscripta {

/// Reassembles chunk transcripts into one continuous transcript.
///
/// Chunking is an internal detail; the user never sees it. The merger walks the
/// plan in sequence order, joins soft boundaries plainly, and de-duplicates
/// hard-cut overlaps by aligning word timestamps across the overlapping span.
/// Where alignment fails it cuts at the nominal boundary and records
/// SegmentWarning::merge_ambiguity rather than hiding the uncertainty.
///
/// Paragraph structure comes from the silence map's measured gaps, not from the
/// engine's own segmentation, so it is stable between identical runs.
struct TranscriptMerger {
    /// Words compared on each side of a hard cut when searching for the splice.
    int overlap_search_words = 40;
    /// How far apart matched words may sit before the match is rejected.
    MediaTime timestamp_tolerance = seconds(2);

    /// Throws AnalysisFailed if the result would not be in ascending time order.
    Transcript merge(const std::vector<ChunkTranscript>& chunks, const ChunkPlan& plan,
                     const SilenceMap& silence_map, const std::string& engine_id = {}) const;

    /// The longest detected silence lying between two segments, or the raw time
    /// difference when the map records no gap there.
    static MediaTime measured_pause(MediaTime previous_end, MediaTime current_start,
                                    const SilenceMap& map);

    /// Case- and punctuation-insensitive comparison key.
    static std::string normalize(const std::string& text);

    /// Drops the leading words of `incoming` that repeat the end of `existing`,
    /// and removes fragment words from the end of `existing` when the splice
    /// shows they were cut-edge noise. Falls back to a time cut flagged
    /// SegmentWarning::merge_ambiguity when no confident splice exists.
    std::vector<TranscriptSegment> deduplicate(std::vector<TranscriptSegment> incoming,
                                               std::vector<TranscriptSegment>& existing,
                                               MediaTime overlap_start) const;

    /// Where two chunks' words agree: `run` words match, after ignoring
    /// `skip_previous` fragment words at the end of the earlier chunk and
    /// `skip_incoming` at the start of the later one. run == 0 means no match.
    struct Splice {
        int run = 0;
        int skip_previous = 0;
        int skip_incoming = 0;
    };
    /// Longest agreeing run (at least two words, timestamps within tolerance),
    /// allowing up to `max_junk_words` of cut-edge fragments on either side.
    Splice find_splice(const std::vector<Word>& previous, const std::vector<Word>& current,
                       int max_junk_words) const;

    /// Length of the longest suffix of `previous` that is a prefix of `current`
    /// with no junk allowed, or 0.
    int longest_overlap(const std::vector<Word>& previous, const std::vector<Word>& current) const;
};

}  // namespace voxscripta
