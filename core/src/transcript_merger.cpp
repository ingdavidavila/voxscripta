#include "voxscripta/transcript_merger.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>

#include "voxscripta/errors.hpp"

namespace voxscripta {

std::string TranscriptMerger::normalize(const std::string& text) {
    // Letters and digits only, ASCII lower-cased. Bytes of multi-byte UTF-8
    // characters are kept as they are, so non-Latin words still compare.
    std::string out;
    for (unsigned char c : text) {
        if (c >= 0x80) out += static_cast<char>(c);
        else if (std::isalnum(c)) out += static_cast<char>(std::tolower(c));
    }
    return out;
}

MediaTime TranscriptMerger::measured_pause(MediaTime previous_end, MediaTime current_start,
                                           const SilenceMap& map) {
    if (!(current_start > previous_end)) return MediaTime::zero();
    const TimeRange window(previous_end, current_start);

    MediaTime longest = MediaTime::zero();
    for (const SilenceGap& gap : map.gaps) {
        if (auto overlap = gap.range.intersection(window)) {
            longest = MediaTime::max(longest, overlap->duration());
        }
    }
    return longest > MediaTime::zero() ? longest : window.duration();
}

TranscriptMerger::Splice TranscriptMerger::find_splice(const std::vector<Word>& previous,
                                                       const std::vector<Word>& current,
                                                       int max_junk_words) const {
    Splice best;
    const int p_size = static_cast<int>(previous.size());
    const int c_size = static_cast<int>(current.size());

    // A hard cut can land mid-word, so the last word of the earlier chunk and
    // the first of the later one are often fragments ("save an" for "save
    // enough"). Allow a few junk words at each edge, but prefer the longest
    // agreement and, among equals, the least junk.
    for (int skip_prev = 0; skip_prev <= max_junk_words; ++skip_prev) {
        for (int skip_in = 0; skip_in <= max_junk_words; ++skip_in) {
            const int max_run = std::min(p_size - skip_prev, c_size - skip_in);
            // Longer runs are stronger evidence, so search downward and take the
            // first. A single matching word is a coincidence; two or more is a match.
            for (int run = max_run; run >= 2; --run) {
                bool match = true;
                for (int i = 0; i < run && match; ++i) {
                    const Word& tail = previous[static_cast<std::size_t>(p_size - skip_prev - run + i)];
                    const Word& head = current[static_cast<std::size_t>(skip_in + i)];
                    match = normalize(tail.text) == normalize(head.text) &&
                            std::abs((tail.original_start - head.original_start).seconds()) <=
                                timestamp_tolerance.seconds();
                }
                if (!match) continue;
                const bool better = run > best.run ||
                                    (run == best.run && skip_prev + skip_in < best.skip_previous + best.skip_incoming);
                if (better) best = {run, skip_prev, skip_in};
                break;
            }
        }
    }
    return best;
}

int TranscriptMerger::longest_overlap(const std::vector<Word>& previous,
                                      const std::vector<Word>& current) const {
    return find_splice(previous, current, 0).run;
}

namespace {

/// Removes words and segments that end at or before `time`.
std::vector<TranscriptSegment> trim_by_time(const std::vector<TranscriptSegment>& segments, MediaTime time) {
    std::vector<TranscriptSegment> out;
    for (TranscriptSegment segment : segments) {
        std::vector<Word> kept;
        for (const Word& w : segment.words) {
            if (w.original_end > time) kept.push_back(w);
        }
        if (kept.size() == segment.words.size()) {
            // Includes segments with no word timings at all: judge them whole.
            if (segment.words.empty() && segment.original_end <= time) continue;
            out.push_back(std::move(segment));
            continue;
        }
        if (kept.empty()) continue;
        segment.text.clear();
        for (const Word& w : kept) segment.text += (segment.text.empty() ? "" : " ") + w.text;
        segment.original_start = kept.front().original_start;
        segment.words = std::move(kept);
        out.push_back(std::move(segment));
    }
    return out;
}

/// Engines time the same words slightly differently in two chunks, so after the
/// duplicates are gone the first surviving segment can start a hair before the
/// previous one ended. Clamp starts forward to `floor`; a segment that has no
/// time left after clamping is dropped. Time only moves forward, and only by the
/// engine's own jitter.
std::vector<TranscriptSegment> clamp_starts(std::vector<TranscriptSegment> segments, MediaTime floor) {
    std::vector<TranscriptSegment> out;
    for (TranscriptSegment& s : segments) {
        if (s.original_start < floor) {
            s.original_start = floor;
            if (s.original_end < s.original_start) {
                if (s.words.empty() && !s.text.empty()) s.original_end = s.original_start;
                else continue;
            }
        }
        for (Word& w : s.words) {
            w.original_start = MediaTime::max(w.original_start, s.original_start);
            w.original_end = MediaTime::max(w.original_end, w.original_start);
        }
        floor = MediaTime::max(floor, s.original_end);
        out.push_back(std::move(s));
    }
    return out;
}

}  // namespace

namespace {

/// Removes the last `count` words from the end of `segments`, dropping segments
/// that become empty and re-deriving text and end time for the one that shrinks.
void drop_trailing_words(std::vector<TranscriptSegment>& segments, int count) {
    while (count > 0 && !segments.empty()) {
        TranscriptSegment& last = segments.back();
        if (last.words.empty()) break;  // a gap marker or untimed text: leave it alone
        const int take = std::min<int>(count, static_cast<int>(last.words.size()));
        last.words.resize(last.words.size() - static_cast<std::size_t>(take));
        count -= take;
        if (last.words.empty()) {
            segments.pop_back();
            continue;
        }
        last.text.clear();
        for (const Word& w : last.words) last.text += (last.text.empty() ? "" : " ") + w.text;
        last.original_end = last.words.back().original_end;
    }
}

}  // namespace

std::vector<TranscriptSegment> TranscriptMerger::deduplicate(std::vector<TranscriptSegment> incoming,
                                                             std::vector<TranscriptSegment>& existing,
                                                             MediaTime overlap_start) const {
    const MediaTime fallback_cut = existing.empty() ? overlap_start : existing.back().original_end;

    // Words the earlier chunk produced inside the overlap. Its timestamps for
    // them can drift earlier than the overlap's nominal start, so look back a
    // little further than the boundary itself.
    const MediaTime look_back = overlap_start - milliseconds(1500);
    std::vector<Word> previous_tail;
    for (const auto& s : existing) {
        for (const Word& w : s.words) {
            if (w.original_start >= look_back) previous_tail.push_back(w);
        }
    }
    const std::size_t keep = static_cast<std::size_t>(overlap_search_words);
    if (previous_tail.size() > keep) {
        previous_tail.erase(previous_tail.begin(), previous_tail.end() - static_cast<std::ptrdiff_t>(keep));
    }
    std::vector<Word> incoming_words;
    for (const auto& s : incoming) {
        for (const Word& w : s.words) {
            if (incoming_words.size() < keep) incoming_words.push_back(w);
        }
    }

    if (previous_tail.empty() || incoming_words.empty()) return trim_by_time(incoming, fallback_cut);

    if (const Splice splice = find_splice(previous_tail, incoming_words, 2); splice.run > 0) {
        // Fragments at the edge of the earlier chunk are removed; the later
        // chunk's version of the overlap takes over after the matched run.
        drop_trailing_words(existing, splice.skip_previous);
        const std::size_t last_matched = static_cast<std::size_t>(splice.skip_incoming + splice.run) - 1;
        return trim_by_time(incoming, incoming_words[last_matched].original_end);
    }

    // No confident splice point. Cut by time and mark it.
    auto trimmed = trim_by_time(incoming, existing.empty() ? overlap_start : existing.back().original_end);
    if (!trimmed.empty()) trimmed.front().warnings.push_back(SegmentWarning::merge_ambiguity);
    return trimmed;
}

Transcript TranscriptMerger::merge(const std::vector<ChunkTranscript>& chunks, const ChunkPlan& plan,
                                   const SilenceMap& silence_map, const std::string& engine_id) const {
    std::map<int, const ChunkTranscript*> by_sequence;
    for (const auto& c : chunks) by_sequence[c.sequence] = &c;

    std::vector<ChunkSpec> specs = plan.chunks;
    std::sort(specs.begin(), specs.end(),
              [](const ChunkSpec& a, const ChunkSpec& b) { return a.sequence < b.sequence; });

    std::vector<TranscriptSegment> segments;
    // Walk the plan rather than the results, so a chunk that failed leaves a
    // visible gap in the right place instead of silently closing up.
    for (const ChunkSpec& spec : specs) {
        const auto it = by_sequence.find(spec.sequence);
        if (it == by_sequence.end()) {
            TranscriptSegment gap;
            gap.chunk_sequence = spec.sequence;
            gap.original_start = spec.original_range.start_time();
            gap.original_end = spec.original_range.end_time();
            gap.warnings.push_back(SegmentWarning::transcription_gap);
            segments.push_back(std::move(gap));
            continue;
        }
        std::vector<TranscriptSegment> incoming = it->second->segments;
        std::stable_sort(incoming.begin(), incoming.end(), [](const auto& a, const auto& b) {
            return a.original_start < b.original_start;
        });
        if (incoming.empty()) continue;

        if (spec.overlap_lead > MediaTime::zero() && !segments.empty()) {
            incoming = deduplicate(std::move(incoming), segments, spec.original_range.start_time());
            incoming = clamp_starts(std::move(incoming), segments.back().original_end);
        }
        for (auto& s : incoming) segments.push_back(std::move(s));
    }

    // Pause durations drive paragraph and section breaks, and they come from the
    // silence map rather than from the engine's own segmentation: the map is
    // deterministic DSP output, so the transcript's shape stays stable even if a
    // different engine would have segmented differently.
    for (std::size_t i = 1; i < segments.size(); ++i) {
        segments[i].preceding_gap =
            measured_pause(segments[i - 1].original_end, segments[i].original_start, silence_map);
    }

    Transcript transcript{std::move(segments), engine_id};
    // Ordering is the merger's core contract; a violation would corrupt every
    // export, so it fails loudly rather than shipping.
    if (!transcript.is_monotonic()) {
        throw AnalysisFailed("transcript merge", "merged segments are not in ascending time order");
    }
    return transcript;
}

}  // namespace voxscripta
