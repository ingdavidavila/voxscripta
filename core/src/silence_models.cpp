#include "voxscripta/chunk_models.hpp"
#include "voxscripta/silence_models.hpp"

namespace voxscripta {

MediaTime SilenceMap::speech_duration() const {
    MediaTime total = MediaTime::zero();
    for (const auto& region : speech_regions) total = total + region.range.duration();
    return total;
}

double SilenceMap::speech_fraction() const {
    return source_duration.nanoseconds() > 0
               ? static_cast<double>(speech_duration().nanoseconds()) /
                     static_cast<double>(source_duration.nanoseconds())
               : 0.0;
}

MediaTime SilenceMap::original_time_for_processed(MediaTime processed) const {
    MediaTime remaining = processed;
    for (const auto& region : speech_regions) {
        const MediaTime d = region.range.duration();
        if (remaining < d) return region.range.start_time() + remaining;
        remaining = remaining - d;
    }
    return speech_regions.empty() ? MediaTime::zero() : speech_regions.back().range.end_time();
}

std::optional<MediaTime> SilenceMap::processed_time_for_original(MediaTime original) const {
    MediaTime accumulated = MediaTime::zero();
    for (const auto& region : speech_regions) {
        if (region.range.contains(original)) {
            return accumulated + (original - region.range.start_time());
        }
        if (original < region.range.start_time()) return std::nullopt;
        accumulated = accumulated + region.range.duration();
    }
    return std::nullopt;
}

MediaTime ChunkPlan::total_duration() const {
    MediaTime total = MediaTime::zero();
    for (const auto& chunk : chunks) total = total + chunk.duration();
    return total;
}

std::size_t ChunkPlan::hard_cut_count() const {
    std::size_t n = 0;
    for (const auto& chunk : chunks) n += chunk.boundary_kind.requires_overlap() ? 1 : 0;
    return n;
}

}  // namespace voxscripta
