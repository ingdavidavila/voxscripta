#include "voxscripta/media_time.hpp"

#include <cmath>
#include <cstdio>
#include <stdexcept>

namespace voxscripta {

MediaTime MediaTime::from_seconds(double value) {
    if (!std::isfinite(value)) {
        throw std::invalid_argument("MediaTime requires a finite value");
    }
    // std::round and Swift's .rounded() both round half away from zero, so the
    // two implementations agree on every tie.
    return MediaTime(static_cast<std::int64_t>(std::round(value * 1'000'000'000.0)));
}

MediaTime MediaTime::from_samples(std::int64_t samples, int sample_rate) {
    if (sample_rate <= 0) {
        throw std::invalid_argument("sampleRate must be positive");
    }
    std::int64_t scaled = 0;
    if (__builtin_mul_overflow(samples, std::int64_t{1'000'000'000}, &scaled)) {
        throw std::overflow_error("sample index too large to express in nanoseconds");
    }
    return MediaTime(scaled / static_cast<std::int64_t>(sample_rate));
}

std::int64_t MediaTime::samples_at(int sample_rate) const {
    if (sample_rate <= 0) {
        throw std::invalid_argument("sampleRate must be positive");
    }
    std::int64_t scaled = 0;
    if (__builtin_mul_overflow(nanoseconds_, static_cast<std::int64_t>(sample_rate), &scaled)) {
        throw std::overflow_error("duration too long to express as samples at this rate");
    }
    return scaled / 1'000'000'000;
}

MediaTime MediaTime::operator*(double factor) const {
    return MediaTime(
        static_cast<std::int64_t>(std::round(static_cast<double>(nanoseconds_) * factor)));
}

std::string MediaTime::to_string() const {
    const bool negative = nanoseconds_ < 0;
    // Negating in unsigned space so the most negative int64_t does not overflow.
    const std::uint64_t magnitude =
        negative ? (~static_cast<std::uint64_t>(nanoseconds_) + 1u)
                 : static_cast<std::uint64_t>(nanoseconds_);

    const std::uint64_t ms = magnitude / 1'000'000u % 1000u;
    const std::uint64_t s = magnitude / 1'000'000'000u % 60u;
    const std::uint64_t m = magnitude / 60'000'000'000u % 60u;
    const std::uint64_t h = magnitude / 3'600'000'000'000u;
    const char* sign = negative ? "-" : "";

    char buffer[64];
    if (h > 0) {
        std::snprintf(buffer, sizeof buffer, "%s%llu:%02llu:%02llu.%03llu", sign,
                      static_cast<unsigned long long>(h), static_cast<unsigned long long>(m),
                      static_cast<unsigned long long>(s), static_cast<unsigned long long>(ms));
    } else {
        std::snprintf(buffer, sizeof buffer, "%s%llu:%02llu.%03llu", sign,
                      static_cast<unsigned long long>(m), static_cast<unsigned long long>(s),
                      static_cast<unsigned long long>(ms));
    }
    return std::string(buffer);
}

}  // namespace voxscripta
