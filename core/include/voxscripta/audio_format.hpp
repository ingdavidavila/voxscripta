#pragma once

#include <cstdint>

#include "voxscripta/media_time.hpp"

namespace voxscripta {

/// The format every source is canonicalized into before analysis: 16 kHz mono
/// 32-bit float, little-endian, headerless (`canonical.f32`).
struct CanonicalFormat {
    static constexpr int sample_rate = 16'000;
    static constexpr int channel_count = 1;
    static constexpr int bytes_per_sample = 4;

    static std::int64_t byte_count(MediaTime duration) {
        return duration.samples_at(sample_rate) * bytes_per_sample;
    }
};

}  // namespace voxscripta
