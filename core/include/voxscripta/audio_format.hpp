#pragma once

#include <cstdint>
#include <optional>
#include <string>

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

/// What the source file actually is, as probed at import.
struct AudioFormatDescription {
    double sample_rate = 0;
    int channel_count = 0;
    std::optional<int> bit_depth;
    /// Container/codec as reported by the platform decoder, for display only.
    std::string format_description;
};

}  // namespace voxscripta
