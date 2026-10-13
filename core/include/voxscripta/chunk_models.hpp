#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "voxscripta/media_time.hpp"
#include "voxscripta/time_range.hpp"

namespace voxscripta {

/// Why a chunk ends where it does.
struct BoundaryKind {
    enum class Kind { silence, hard_cut, end_of_media };

    Kind kind = Kind::end_of_media;
    /// Meaningful only for Kind::silence.
    MediaTime gap_duration;

    static BoundaryKind silence(MediaTime gap) { return {Kind::silence, gap}; }
    static BoundaryKind hard_cut() { return {Kind::hard_cut, MediaTime::zero()}; }
    static BoundaryKind end_of_media() { return {Kind::end_of_media, MediaTime::zero()}; }

    bool requires_overlap() const noexcept { return kind == Kind::hard_cut; }

    bool operator==(const BoundaryKind& o) const noexcept {
        return kind == o.kind && gap_duration == o.gap_duration;
    }
    bool operator!=(const BoundaryKind& o) const noexcept { return !(*this == o); }
};

struct ChunkParameters {
    MediaTime min_duration = seconds(120);
    MediaTime max_duration = seconds(300);
    MediaTime target_duration = seconds(240);
    MediaTime overlap_duration = seconds(3);
    MediaTime min_boundary_gap = milliseconds(400);
};

/// One unit of transcription work: a view into the canonical PCM file.
///
/// Unlike the Swift ChunkSpec this carries no random ChunkID. Identity is
/// assigned by whoever persists the plan; the planner stays a pure function.
struct ChunkSpec {
    int sequence;
    TimeRange original_range;
    TimeRange processed_range;
    SampleRange sample_range;
    BoundaryKind boundary_kind;
    MediaTime overlap_lead;

    MediaTime duration() const { return original_range.duration(); }
};

struct ChunkPlan {
    std::vector<ChunkSpec> chunks;
    ChunkParameters parameters;
    std::string parameter_hash;

    std::size_t count() const { return chunks.size(); }
    MediaTime total_duration() const;
    std::size_t hard_cut_count() const;
};

}  // namespace voxscripta
