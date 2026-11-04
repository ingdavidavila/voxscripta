#include "voxscripta/noise_floor.hpp"

#include <algorithm>

#include "voxscripta/errors.hpp"

namespace voxscripta {

std::vector<float> NoiseFloorTracker::track(const FrameFeatures& features) const {
    const int n = features.count();
    if (n <= 0) throw AnalysisFailed("noise floor", "no analysis frames");

    const MediaTime hop = features.geometry.hop_duration;
    if (hop.nanoseconds() <= 0) throw AnalysisFailed("noise floor", "hop duration is zero");
    const int window_frames =
        std::max<std::int64_t>(1, window_duration.nanoseconds() / hop.nanoseconds());

    // Global anchor: when the loudest content is harmonic, speech is present and
    // no local estimate may claim a floor within `minimum_speech_to_floor_db` of
    // it. This is what stops a pause-free lecture from pushing the thresholds
    // above its own speech.
    std::vector<float> sorted = features.rms_db;
    std::sort(sorted.begin(), sorted.end());
    const float global_high =
        sorted[std::min<std::size_t>(sorted.size() - 1,
                                     static_cast<std::size_t>(static_cast<float>(sorted.size() - 1) * 0.95f))];

    std::vector<float> loud_flatness;
    loud_flatness.reserve(static_cast<std::size_t>(n) / 8);
    for (int i = 0; i < n; ++i) {
        if (features.rms_db[i] >= global_high - 6) loud_flatness.push_back(features.spectral_flatness[i]);
    }
    std::sort(loud_flatness.begin(), loud_flatness.end());
    const float median_loud_flatness =
        loud_flatness.empty() ? 1.0f : loud_flatness[loud_flatness.size() / 2];

    const bool capped = median_loud_flatness < speech_flatness_ceiling;
    const float cap = global_high - minimum_speech_to_floor_db;

    // Per-block percentile.
    std::vector<int> centres;
    std::vector<float> values;
    for (int start = 0; start < n;) {
        const int end = std::min(start + window_frames, n);
        std::vector<float> block(features.rms_db.begin() + start, features.rms_db.begin() + end);
        std::sort(block.begin(), block.end());
        const int index = std::min<int>(
            static_cast<int>(block.size()) - 1,
            std::max(0, static_cast<int>(static_cast<float>(block.size() - 1) * percentile)));
        centres.push_back((start + end) / 2);
        values.push_back(capped ? std::min(block[index], cap) : block[index]);
        start = end;
    }

    // Interpolate between block centres.
    std::vector<float> raw(n, values[0]);
    if (values.size() > 1) {
        std::size_t b = 0;
        for (int i = 0; i < n; ++i) {
            if (i <= centres.front()) { raw[i] = values.front(); continue; }
            if (i >= centres.back()) { raw[i] = values.back(); continue; }
            while (b + 1 < centres.size() && centres[b + 1] < i) ++b;
            const int x0 = centres[b], x1 = centres[b + 1];
            const float span = static_cast<float>(x1 - x0);
            const float t = span > 0 ? static_cast<float>(i - x0) / span : 0.0f;
            raw[i] = values[b] + (values[b + 1] - values[b]) * t;
        }
    }

    // Asymmetric one-pole smoothing: rises slowly, falls quickly.
    std::vector<float> smoothed(n);
    float state = raw[0];
    for (int i = 0; i < n; ++i) {
        const float coefficient = raw[i] > state ? attack_coefficient : release_coefficient;
        state += (raw[i] - state) * coefficient;
        smoothed[i] = state;
    }
    return smoothed;
}

}  // namespace voxscripta
