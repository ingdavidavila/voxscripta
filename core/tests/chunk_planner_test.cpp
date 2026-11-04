// Ported from Tests/VoxScriptaDSPTests/ChunkPlannerTests.swift. The random
// silence maps use this repository's own seeded generator, so the exact maps
// differ from the Swift ones; the invariants asserted over them are the same.

#include <cmath>
#include <string>

#include "harness.hpp"
#include "synthesis.hpp"
#include "voxscripta/chunk_planner.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/silence_detector.hpp"

using namespace voxscripta;
using namespace voxscripta::testing;

namespace {

/// A random but well-formed silence map, for property testing.
SilenceMap random_silence_map(std::uint64_t seed, int region_count) {
    DeterministicRandom rng(seed);
    SilenceMap map;
    MediaTime t = seconds(rng.uniform() * 3);
    if (t > MediaTime::zero()) {
        map.gaps.push_back({TimeRange(MediaTime::zero(), t), -60});
    }
    for (int i = 0; i < region_count; ++i) {
        const MediaTime end = t + seconds(1 + rng.uniform() * 90);
        map.speech_regions.push_back({TimeRange(t, end), -20, -12});
        // Gap lengths straddle min_boundary_gap so usable and unusable
        // candidates both occur.
        const MediaTime gap = seconds(0.05 + rng.uniform() * 4);
        map.gaps.push_back({TimeRange(end, end + gap), -60});
        t = end + gap;
    }
    map.parameter_hash = "prop";
    map.source_duration = t;
    return map;
}

SilenceMap map_for(const CorpusCase& c) {
    const auto samples = c.render();
    const FrameFeatures f = FrameAnalyzer().analyze(samples.data(), samples.size(), FrameGeometry{});
    return SilenceDetector{}.detect(f, SilenceParameters{}, c.duration(), "test");
}

void assert_invariants(const ChunkPlan& plan, const SilenceMap& map, const ChunkParameters& params,
                       const std::string& label) {
    if (map.speech_regions.empty()) return;
    const auto& first_region = map.speech_regions.front();
    const auto& last_region = map.speech_regions.back();
    VS_EXPECT_MSG(!plan.chunks.empty(), label + ": produced no chunks");
    if (plan.chunks.empty()) return;

    for (std::size_t i = 0; i < plan.chunks.size(); ++i) {
        VS_EXPECT_MSG(plan.chunks[i].sequence == static_cast<int>(i), label + ": sequence");
    }
    VS_EXPECT_MSG(plan.chunks.front().original_range.start_time() == first_region.range.start_time(),
                  label + ": start");
    VS_EXPECT_MSG(plan.chunks.back().original_range.end_time() == last_region.range.end_time(),
                  label + ": end");

    for (std::size_t i = 1; i < plan.chunks.size(); ++i) {
        const ChunkSpec& a = plan.chunks[i - 1];
        const ChunkSpec& b = plan.chunks[i];
        if (b.overlap_lead > MediaTime::zero()) {
            VS_EXPECT_MSG(a.boundary_kind.requires_overlap(), label + ": overlap without a hard cut");
            VS_EXPECT_MSG(b.original_range.start_time() == a.original_range.end_time() - b.overlap_lead,
                          label + ": overlap amount");
        } else {
            VS_EXPECT_MSG(b.original_range.start_time() == a.original_range.end_time(),
                          label + ": contiguity");
        }
    }
    VS_EXPECT_MSG(plan.chunks.front().overlap_lead == MediaTime::zero(),
                  label + ": first chunk cannot have overlap");

    for (std::size_t i = 0; i + 1 < plan.chunks.size(); ++i) {
        VS_EXPECT_MSG(plan.chunks[i].duration() <= params.max_duration + milliseconds(1),
                      label + ": chunk " + std::to_string(i) + " exceeds max_duration");
    }
    for (const ChunkSpec& c : plan.chunks) {
        VS_EXPECT_MSG(c.processed_range.start_time() <= c.processed_range.end_time(),
                      label + ": processed order");
        VS_EXPECT_MSG(c.processed_range.end_time() <= map.speech_duration() + milliseconds(1),
                      label + ": processed overflow");
        VS_EXPECT_MSG(c.sample_range.start_index() ==
                          c.original_range.start_time().samples_at(CanonicalFormat::sample_rate),
                      label + ": sample start");
    }
}

}  // namespace

VS_TEST("Chunk planner", "Invariants hold across many random silence maps") {
    const ChunkParameters params;
    for (std::uint64_t seed = 1; seed <= 60; ++seed) {
        const SilenceMap map = random_silence_map(seed, static_cast<int>(seed % 40) + 1);
        assert_invariants(ChunkPlanner{}.plan(map, params, "p"), map, params,
                          "seed " + std::to_string(seed));
    }
}

VS_TEST("Chunk planner", "Invariants hold across varied chunk parameters") {
    const SilenceMap map = random_silence_map(99, 30);
    ChunkParameters a;
    a.min_duration = seconds(30); a.max_duration = seconds(60);
    a.target_duration = seconds(45); a.overlap_duration = seconds(2);
    ChunkParameters b;
    b.min_duration = seconds(5); b.max_duration = seconds(600);
    b.target_duration = seconds(300); b.overlap_duration = seconds(1);
    ChunkParameters c;
    c.min_duration = seconds(120); c.max_duration = seconds(120);
    c.target_duration = seconds(120); c.overlap_duration = seconds(5);
    int i = 0;
    for (const auto& params : {a, b, c}) {
        assert_invariants(ChunkPlanner{}.plan(map, params, "p"), map, params,
                          "variant " + std::to_string(i++));
    }
}

VS_TEST("Chunk planner", "Boundaries prefer silence when silence is available") {
    const SilenceMap map = random_silence_map(7, 25);
    const ChunkPlan plan = ChunkPlanner{}.plan(map, ChunkParameters{}, "p");
    VS_EXPECT_EQ(plan.hard_cut_count(), std::size_t{0});
    for (std::size_t i = 0; i + 1 < plan.chunks.size(); ++i) {
        VS_EXPECT(plan.chunks[i].boundary_kind.kind == BoundaryKind::Kind::silence);
    }
}

VS_TEST("Chunk planner", "Continuous speech forces hard cuts with overlap") {
    const SilenceMap map = map_for(corpus::continuous_speech());
    ChunkParameters params;
    params.min_duration = seconds(60); params.max_duration = seconds(120);
    params.target_duration = seconds(90); params.overlap_duration = seconds(3);
    const ChunkPlan plan = ChunkPlanner{}.plan(map, params, "p");

    VS_EXPECT(plan.chunks.size() >= 3);
    VS_EXPECT(plan.hard_cut_count() >= 2);
    for (std::size_t i = 1; i < plan.chunks.size(); ++i) {
        VS_EXPECT(plan.chunks[i].overlap_lead == seconds(3));
    }
    assert_invariants(plan, map, params, "continuous");
}

VS_TEST("Chunk planner", "A recording shorter than one chunk yields exactly one chunk") {
    const SilenceMap map = map_for(corpus::basic());  // 18 s
    const ChunkPlan plan = ChunkPlanner{}.plan(map, ChunkParameters{}, "p");
    VS_EXPECT_EQ(plan.chunks.size(), std::size_t{1});
    VS_EXPECT(plan.chunks[0].boundary_kind == BoundaryKind::end_of_media());
    VS_EXPECT(plan.chunks[0].overlap_lead == MediaTime::zero());
}

VS_TEST("Chunk planner", "Planning is deterministic") {
    const SilenceMap map = random_silence_map(42, 20);
    const ChunkPlan a = ChunkPlanner{}.plan(map, ChunkParameters{}, "p");
    const ChunkPlan b = ChunkPlanner{}.plan(map, ChunkParameters{}, "p");
    VS_EXPECT_EQ(a.chunks.size(), b.chunks.size());
    for (std::size_t i = 0; i < a.chunks.size() && i < b.chunks.size(); ++i) {
        VS_EXPECT(a.chunks[i].original_range == b.chunks[i].original_range);
        VS_EXPECT(a.chunks[i].boundary_kind == b.chunks[i].boundary_kind);
    }
}

VS_TEST("Chunk planner", "A map with no speech is rejected rather than planned") {
    SilenceMap empty;
    empty.source_duration = seconds(10);
    VS_EXPECT_THROWS(ChunkPlanner{}.plan(empty, ChunkParameters{}, "p"), NoSpeechDetected);
}

VS_TEST("Chunk planner", "Minimum above maximum is refused") {
    const SilenceMap map = random_silence_map(3, 5);
    ChunkParameters bad;
    bad.min_duration = seconds(400);
    VS_EXPECT_THROWS(ChunkPlanner{}.plan(map, bad, "p"), AnalysisFailed);
}

VS_TEST("Chunk planner", "Scoring prefers longer gaps and boundaries nearer the target") {
    const ChunkPlanner planner;
    const ChunkParameters params;
    const MediaTime start = MediaTime::zero();
    const MediaTime target = params.target_duration;

    auto score = [&](double gap_seconds, MediaTime at) {
        const SilenceGap gap{TimeRange::with_duration(at, seconds(gap_seconds)), -60};
        return planner.boundary_score(gap, at, start, params, -20);
    };
    VS_EXPECT(score(2.0, target) > score(0.5, target));
    VS_EXPECT(score(1.0, target) > score(1.0, params.max_duration));
}
