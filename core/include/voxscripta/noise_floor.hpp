#pragma once

#include <vector>

#include "voxscripta/frame_analysis.hpp"

namespace voxscripta {

/// Minimum-statistics noise floor tracker: a low percentile of block energies,
/// interpolated between block centres and smoothed asymmetrically (rises slowly,
/// falls quickly). See NoiseFloorTracker.swift for the rationale behind each
/// parameter; the values here are identical.
struct NoiseFloorTracker {
    MediaTime window_duration = seconds(3);
    float percentile = 0.10f;
    float attack_coefficient = 0.002f;
    float release_coefficient = 0.050f;
    float minimum_speech_to_floor_db = 20;
    float speech_flatness_ceiling = 0.20f;

    /// One estimate in dBFS per frame. Throws AnalysisFailed on empty input.
    std::vector<float> track(const FrameFeatures& features) const;
};

}  // namespace voxscripta
