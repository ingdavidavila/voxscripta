#pragma once

// Named specializations, so Swift can see the C++ core's containers.
//
// Swift's C++ interop cannot instantiate a class template itself: writing
// std::vector<float> from Swift fails with "un-specialized class templates
// are not currently supported". It can only use a specialization that has
// been given a name on the C++ side.
//
// These aliases exist for the Swift↔C++ parity tests and for nothing else.
// They live here, outside core/, because they are a property of the bridge
// rather than of the port — core/ should not grow declarations whose only
// reader is a test in another language.

#include <string>
#include <vector>

#include "voxscripta/chunk_models.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/chunk_planner.hpp"
#include "voxscripta/transcript_merger.hpp"
#include "voxscripta/silence_detector.hpp"
#include "voxscripta/frame_analysis.hpp"
#include "voxscripta/silence_models.hpp"
#include "voxscripta/transcript_models.hpp"

namespace voxscripta::shim {

using FloatVector = std::vector<float>;
using SpeechRegionVector = std::vector<SpeechRegion>;
using SilenceGapVector = std::vector<SilenceGap>;

/// Builds a float vector from a Swift array, which arrives as a pointer.
///
/// push_back in a loop across the language boundary works but is slow enough
/// to matter when a property test runs it thousands of times.
inline FloatVector floats(const float* values, int count) {
    return FloatVector(values, values + count);
}

/// FrameFeatures from three Swift arrays, without three round trips.
inline FrameFeatures features(const float* rms, const float* zcr, const float* flatness,
                              int count, FrameGeometry geometry) {
    return FrameFeatures(floats(rms, count), floats(zcr, count), floats(flatness, count),
                         geometry);
}

// ── Reading results out ─────────────────────────────────────────────────
//
// SilenceMap holds std::vector<SpeechRegion> and std::vector<SilenceGap>.
// Swift cannot name those specializations either, so results come out one
// element at a time through these. Tedious, but it keeps the bridge's
// awkwardness in one file instead of spread through the tests.

inline int speech_count(const SilenceMap& map) {
    return static_cast<int>(map.speech_regions.size());
}
inline TimeRange speech_range(const SilenceMap& map, int i) {
    return map.speech_regions[static_cast<std::size_t>(i)].range;
}
inline float speech_mean_db(const SilenceMap& map, int i) {
    return map.speech_regions[static_cast<std::size_t>(i)].mean_energy_db;
}
inline float speech_peak_db(const SilenceMap& map, int i) {
    return map.speech_regions[static_cast<std::size_t>(i)].peak_energy_db;
}

inline int gap_count(const SilenceMap& map) {
    return static_cast<int>(map.gaps.size());
}
inline TimeRange gap_range(const SilenceMap& map, int i) {
    return map.gaps[static_cast<std::size_t>(i)].range;
}
inline float gap_mean_db(const SilenceMap& map, int i) {
    return map.gaps[static_cast<std::size_t>(i)].mean_energy_db;
}

inline int floor_count(const SilenceMap& map) {
    return static_cast<int>(map.noise_floor_profile.size());
}
inline float floor_at(const SilenceMap& map, int i) {
    return map.noise_floor_profile[static_cast<std::size_t>(i)];
}

/// Runs the detector and reports how it ended, instead of throwing.
///
/// Swift cannot catch a C++ exception — the interop traps instead — so a
/// no-speech input would take the test process down rather than fail a test.
/// Converting the outcome to a code also makes the refusal itself comparable:
/// Swift throws `noSpeechDetected` where C++ throws `NoSpeechDetected`, and
/// that they refuse the *same* inputs is as much a parity property as the
/// boundaries they produce when they do not.
///
/// 0 produced a map · 1 no speech · 2 some other failure
inline int detect_status(const SilenceDetector& detector, const FrameFeatures& features,
                         const SilenceParameters& parameters, MediaTime duration) {
    try {
        (void)detector.detect(features, parameters, duration, "parity");
        return 0;
    } catch (const NoSpeechDetected&) {
        return 1;
    } catch (...) {
        return 2;
    }
}

// ── Chunk plans ─────────────────────────────────────────────────────────

/// 0 planned · 1 no speech · 2 some other failure. Same reason as
/// `detect_status`: Swift cannot catch what C++ throws.
inline int plan_status(const ChunkPlanner& planner, const SilenceMap& map,
                       const ChunkParameters& parameters) {
    try {
        (void)planner.plan(map, parameters, "parity");
        return 0;
    } catch (...) {
        return 2;
    }
}

inline int chunk_count(const ChunkPlan& plan) {
    return static_cast<int>(plan.chunks.size());
}
inline int chunk_sequence(const ChunkPlan& plan, int i) {
    return plan.chunks[static_cast<std::size_t>(i)].sequence;
}
inline TimeRange chunk_original(const ChunkPlan& plan, int i) {
    return plan.chunks[static_cast<std::size_t>(i)].original_range;
}
inline TimeRange chunk_processed(const ChunkPlan& plan, int i) {
    return plan.chunks[static_cast<std::size_t>(i)].processed_range;
}
inline std::int64_t chunk_overlap_lead_ns(const ChunkPlan& plan, int i) {
    return plan.chunks[static_cast<std::size_t>(i)].overlap_lead.nanoseconds();
}
/// 0 silence · 1 hard cut · 2 end of media
inline int chunk_boundary(const ChunkPlan& plan, int i) {
    switch (plan.chunks[static_cast<std::size_t>(i)].boundary_kind.kind) {
        case BoundaryKind::Kind::silence: return 0;
        case BoundaryKind::Kind::hard_cut: return 1;
        case BoundaryKind::Kind::end_of_media: return 2;
    }
    return -1;
}
inline std::int64_t chunk_boundary_gap_ns(const ChunkPlan& plan, int i) {
    return plan.chunks[static_cast<std::size_t>(i)].boundary_kind.gap_duration.nanoseconds();
}
inline std::int64_t chunk_sample_start(const ChunkPlan& plan, int i) {
    return plan.chunks[static_cast<std::size_t>(i)].sample_range.start_index();
}
inline std::int64_t chunk_sample_count(const ChunkPlan& plan, int i) {
    return plan.chunks[static_cast<std::size_t>(i)].sample_range.count();
}
inline int hard_cuts(const ChunkPlan& plan) {
    return static_cast<int>(plan.hard_cut_count());
}

// ── Transcript merging ──────────────────────────────────────────────────

/// `normalize` as a C string, so Swift can compare it without owning a
/// std::string specialization.
inline std::string normalized(const char* text) {
    return TranscriptMerger::normalize(std::string(text));
}

inline int size_of(const FloatVector& v) { return static_cast<int>(v.size()); }
inline float at(const FloatVector& v, int i) {
    return v[static_cast<std::size_t>(i)];
}

}  // namespace voxscripta::shim
