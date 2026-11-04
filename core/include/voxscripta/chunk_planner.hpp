#pragma once

#include <string>

#include "voxscripta/chunk_models.hpp"
#include "voxscripta/silence_models.hpp"

namespace voxscripta {

struct BoundaryScoreWeights {
    double gap_duration = 0.5;
    double target_proximity = 0.3;
    double silence_depth = 0.2;
    MediaTime gap_saturation = seconds(2);
};

/// Greedy boundary search with a hard-cut fallback (see ChunkPlanner.swift).
struct ChunkPlanner {
    BoundaryScoreWeights weights;

    /// Throws NoSpeechDetected for a map without speech, AnalysisFailed when
    /// min_duration exceeds max_duration.
    ChunkPlan plan(const SilenceMap& map, const ChunkParameters& parameters,
                   const std::string& parameter_hash) const;

    /// Higher is a better place to cut.
    double boundary_score(const SilenceGap& gap, MediaTime midpoint, MediaTime chunk_start,
                          const ChunkParameters& parameters, float speech_reference) const;
};

}  // namespace voxscripta
