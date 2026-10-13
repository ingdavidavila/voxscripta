#pragma once

#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

#include "voxscripta/audio_format.hpp"
#include "voxscripta/media_time.hpp"

namespace voxscripta {

/// How the analyzer slices the signal: 25 ms windows at a 10 ms hop.
struct FrameGeometry {
    MediaTime window_duration = milliseconds(25);
    MediaTime hop_duration = milliseconds(10);
    int sample_rate = CanonicalFormat::sample_rate;

    int window_samples() const { return static_cast<int>(window_duration.samples_at(sample_rate)); }
    int hop_samples() const { return static_cast<int>(hop_duration.samples_at(sample_rate)); }

    int frame_count_for_samples(std::int64_t n) const;
    MediaTime time_of_frame(int index) const;
    /// The frame covering `time`, clamped to zero.
    int frame_at_time(MediaTime time) const;

    bool operator==(const FrameGeometry& o) const {
        return window_duration == o.window_duration && hop_duration == o.hop_duration &&
               sample_rate == o.sample_rate;
    }
};

/// Per-frame features, struct-of-arrays.
struct FrameFeatures {
    std::vector<float> rms_db;               // short-time RMS in dBFS
    std::vector<float> zero_crossing_rate;   // 0...1
    std::vector<float> spectral_flatness;    // Wiener entropy, 0...1
    FrameGeometry geometry;

    /// Throws std::invalid_argument when the arrays differ in length.
    FrameFeatures(std::vector<float> rms, std::vector<float> zcr, std::vector<float> flatness,
                  FrameGeometry g = {});

    int count() const { return static_cast<int>(rms_db.size()); }
    bool empty() const { return rms_db.empty(); }
    MediaTime duration() const { return geometry.time_of_frame(count()); }
};

/// Called with progress in 0...1. Return false to cancel; analysis then throws
/// AnalysisCancelled.
using ProgressFn = std::function<bool(double)>;

class AnalysisCancelled : public std::runtime_error {
public:
    AnalysisCancelled() : std::runtime_error("analysis cancelled") {}
};

/// Computes FrameFeatures from canonical PCM, with no dependency beyond the
/// standard library (the Swift version uses vDSP; frame_analysis.cpp notes the
/// points where the two are made to agree).
class FrameAnalyzer {
public:
    /// Frames quieter than this are reported at the floor rather than at -inf.
    static constexpr float minimum_db = -120;

    /// `fft_size` must be a power of two.
    explicit FrameAnalyzer(int fft_size = 512);

    /// Analyzes samples already in memory. Throws AnalysisFailed when shorter
    /// than one window.
    FrameFeatures analyze(const float* samples, std::int64_t count, const FrameGeometry& geometry,
                          const ProgressFn& progress = {}) const;

    /// Streams a headerless little-endian float32 file in blocks, so a
    /// six-hour recording never has to fit in memory. Produces results identical
    /// to analyze() on the same samples. Throws AnalysisFailed on I/O failure.
    FrameFeatures analyze_file(const std::string& path, const FrameGeometry& geometry,
                               const ProgressFn& progress = {}) const;

    static float root_mean_square(const float* s, int n);
    static float dbfs(float amplitude);
    static float zero_crossing_rate(const float* s, int n);
    static float spectral_flatness(const std::vector<double>& power);

private:
    int fft_size_;
};

}  // namespace voxscripta
