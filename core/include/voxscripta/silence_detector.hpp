#pragma once

#include <string>

#include "voxscripta/frame_analysis.hpp"
#include "voxscripta/noise_floor.hpp"
#include "voxscripta/silence_models.hpp"

namespace voxscripta {

/// The five-stage deterministic silence detector: noise floor, adaptive dual
/// thresholds, fricative protection, duration gating, asymmetric padding. No
/// model participates. Stage order is load-bearing; see SilenceDetector.swift.
struct SilenceDetector {
    NoiseFloorTracker noise_floor_tracker;
    float fricative_zcr_threshold = 0.15f;
    float fricative_flatness_threshold = 0.22f;
    float fricative_margin_db = 2;

    /// Throws AnalysisFailed for empty features and NoSpeechDetected when no
    /// speech survives gating.
    SilenceMap detect(const FrameFeatures& features, const SilenceParameters& parameters,
                      MediaTime source_duration, const std::string& parameter_hash) const;
};

}  // namespace voxscripta
