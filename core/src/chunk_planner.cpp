#include "voxscripta/chunk_planner.hpp"

#include <algorithm>
#include <cmath>
#include <optional>

#include "voxscripta/audio_format.hpp"
#include "voxscripta/errors.hpp"

namespace voxscripta {

namespace {

/// Total speech time before `time` on the original timeline.
MediaTime speech_duration_up_to(const SilenceMap& map, MediaTime time) {
    MediaTime total = MediaTime::zero();
    for (const SpeechRegion& region : map.speech_regions) {
        if (region.range.start_time() >= time) break;
        const TimeRange clipped(region.range.start_time(), MediaTime::min(region.range.end_time(), time));
        total = total + clipped.duration();
    }
    return total;
}

ChunkSpec make_chunk(int sequence, MediaTime start, MediaTime end, BoundaryKind boundary,
                     MediaTime overlap_lead, const SilenceMap& map) {
    const int rate = CanonicalFormat::sample_rate;
    const std::int64_t start_sample = start.samples_at(rate);
    const std::int64_t end_sample = end.samples_at(rate);
    return ChunkSpec{
        sequence,
        TimeRange(start, end),
        // A chunk boundary inside a gap still maps cleanly this way, which
        // SilenceMap::processed_time_for_original cannot do by design.
        TimeRange(speech_duration_up_to(map, start), speech_duration_up_to(map, end)),
        SampleRange(start_sample, end_sample - start_sample),
        boundary,
        overlap_lead,
    };
}

}  // namespace

double ChunkPlanner::boundary_score(const SilenceGap& gap, MediaTime midpoint, MediaTime chunk_start,
                                    const ChunkParameters& parameters, float speech_reference) const {
    const double saturation = weights.gap_saturation.seconds();
    const double gap_term = std::min(gap.duration().seconds(), saturation) / saturation;

    const MediaTime target = chunk_start + parameters.target_duration;
    const double span = std::max((parameters.max_duration - parameters.min_duration).seconds(), 0.001);
    const double deviation = std::abs((midpoint - target).seconds()) / span;
    const double proximity_term = std::max(0.0, 1 - deviation);

    const double depth = static_cast<double>(speech_reference - gap.mean_energy_db);
    const double depth_term = std::min(std::max(depth / 40, 0.0), 1.0);

    return weights.gap_duration * gap_term + weights.target_proximity * proximity_term +
           weights.silence_depth * depth_term;
}

ChunkPlan ChunkPlanner::plan(const SilenceMap& map, const ChunkParameters& parameters,
                             const std::string& parameter_hash) const {
    const auto& regions = map.speech_regions;
    if (regions.empty()) throw NoSpeechDetected();
    if (parameters.min_duration > parameters.max_duration) {
        throw AnalysisFailed("chunk planning", "minimum chunk duration exceeds the maximum");
    }

    // Chunks tile the span from the first speech instant to the last; leading
    // silence is never work.
    const MediaTime media_start = regions.front().range.start_time();

    // Trailing silence is not dropped entirely. A recogniser commits the final
    // word only once it has heard some quiet after it, and the last region's
    // own end can fall inside that word, because a recording with no quiet
    // passage measures a higher noise floor and the word's decay then scores
    // as silence. Measured on the Swift side: a Spanish sentence ending on its
    // last word lost it, and nearly 0.7 s of real audio was being withheld.
    //
    // Mirrors ChunkPlanner.swift, and must keep mirroring it — the parity
    // suite compares these two plans boundary for boundary and is what caught
    // the Swift change landing here first.
    const MediaTime tail = MediaTime::from_seconds(1.5);
    const MediaTime region_end = regions.back().range.end_time();
    const MediaTime padded_end = region_end + tail;
    const MediaTime media_end =
        padded_end < map.source_duration ? padded_end : map.source_duration;

    float speech_reference = 0;
    for (const auto& r : regions) speech_reference += r.mean_energy_db;
    speech_reference /= static_cast<float>(regions.size());

    ChunkPlan plan;
    plan.parameters = parameters;
    plan.parameter_hash = parameter_hash;

    MediaTime cursor = media_start;
    MediaTime pending_overlap = MediaTime::zero();
    int sequence = 0;

    while (cursor < media_end) {
        const MediaTime hard_limit = cursor + parameters.max_duration;
        const MediaTime earliest = cursor + parameters.min_duration;

        // The remainder fits in one chunk: take it and stop.
        if (hard_limit >= media_end) {
            plan.chunks.push_back(make_chunk(sequence, cursor, media_end, BoundaryKind::end_of_media(),
                                             pending_overlap, map));
            break;
        }

        struct Choice {
            MediaTime time;
            MediaTime gap;
            double score;
        };
        std::optional<Choice> best;
        for (const SilenceGap& gap : map.gaps) {
            if (gap.duration() < parameters.min_boundary_gap) continue;
            const MediaTime midpoint = gap.range.start_time() + gap.duration() * 0.5;
            if (!(midpoint > earliest && midpoint <= hard_limit)) continue;

            const double score = boundary_score(gap, midpoint, cursor, parameters, speech_reference);
            if (!best || score > best->score) best = Choice{midpoint, gap.duration(), score};
        }

        if (best) {
            plan.chunks.push_back(make_chunk(sequence, cursor, best->time,
                                             BoundaryKind::silence(best->gap), pending_overlap, map));
            cursor = best->time;
            pending_overlap = MediaTime::zero();
        } else {
            // Continuous speech across the whole window: cut through it, and
            // overlap the next chunk so the merger can re-join the split sentence.
            plan.chunks.push_back(make_chunk(sequence, cursor, hard_limit, BoundaryKind::hard_cut(),
                                             pending_overlap, map));
            const MediaTime overlap =
                MediaTime::min(parameters.overlap_duration, parameters.max_duration * 0.5);
            cursor = hard_limit - overlap;
            pending_overlap = overlap;
        }
        ++sequence;
    }
    return plan;
}

}  // namespace voxscripta
