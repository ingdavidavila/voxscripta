#pragma once

#include <cstdint>
#include <string>

namespace voxscripta {

/// A position or span on an audio timeline, stored exactly.
///
/// Audio timing is stored in integer nanoseconds rather than `double` seconds.
/// A six-hour recording is roughly 2.16 x 10^13 ns, comfortably inside int64_t,
/// and integer storage means accumulating thousands of chunk offsets introduces
/// no drift. Floating-point seconds are available via `seconds()` for display
/// and for interop with platform frameworks, but they are never the stored form.
///
/// A MediaTime carries no indication of *which* timeline it sits on. Vox Scripta
/// maintains two — original and processed — and the invariant is that persisted
/// artifacts store original time only. See SilenceMap for the mapping.
class MediaTime {
public:
    constexpr MediaTime() noexcept : nanoseconds_(0) {}
    constexpr explicit MediaTime(std::int64_t nanoseconds) noexcept
        : nanoseconds_(nanoseconds) {}

    /// From floating-point seconds, rounding to the nearest nanosecond.
    /// Throws std::invalid_argument when the value is not finite.
    static MediaTime from_seconds(double seconds);

    /// From a sample index at a given rate.
    ///
    /// The multiplication happens in int64_t before the division so the result
    /// is exact for every rate that divides evenly into a nanosecond count,
    /// which includes every rate Vox Scripta canonicalizes to.
    ///
    /// Throws std::invalid_argument when the rate is not positive, or
    /// std::overflow_error when the sample index is too large to express in
    /// nanoseconds (beyond roughly 9.2e9 samples, about 160 hours at 16 kHz).
    static MediaTime from_samples(std::int64_t samples, int sample_rate);

    static MediaTime milliseconds(double value) { return from_seconds(value / 1000.0); }
    static constexpr MediaTime zero() noexcept { return MediaTime(0); }

    constexpr std::int64_t nanoseconds() const noexcept { return nanoseconds_; }

    /// For display and framework interop only.
    constexpr double seconds() const noexcept {
        return static_cast<double>(nanoseconds_) / 1'000'000'000.0;
    }

    /// The sample index at `sample_rate`, truncated toward zero.
    ///
    /// Throws std::invalid_argument when the rate is not positive, or
    /// std::overflow_error past the representable duration — about 53 hours at
    /// 48 kHz, 160 hours at 16 kHz. Well beyond the six-hour recordings the app
    /// is built for, but signed overflow is undefined behaviour in C++, so the
    /// limit is enforced rather than left to the optimiser. The Swift
    /// implementation traps on the same input instead of throwing.
    std::int64_t samples_at(int sample_rate) const;

    /// Formats as `h:mm:ss.mmm`, or `m:ss.mmm` under an hour. Negative times
    /// keep a leading sign.
    std::string to_string() const;

    constexpr MediaTime operator+(MediaTime other) const noexcept {
        return MediaTime(nanoseconds_ + other.nanoseconds_);
    }
    constexpr MediaTime operator-(MediaTime other) const noexcept {
        return MediaTime(nanoseconds_ - other.nanoseconds_);
    }
    MediaTime operator*(double factor) const;

    constexpr bool operator==(MediaTime other) const noexcept {
        return nanoseconds_ == other.nanoseconds_;
    }
    constexpr bool operator!=(MediaTime other) const noexcept { return !(*this == other); }
    constexpr bool operator<(MediaTime other) const noexcept {
        return nanoseconds_ < other.nanoseconds_;
    }
    constexpr bool operator>(MediaTime other) const noexcept { return other < *this; }
    constexpr bool operator<=(MediaTime other) const noexcept { return !(other < *this); }
    constexpr bool operator>=(MediaTime other) const noexcept { return !(*this < other); }

    static constexpr MediaTime max(MediaTime a, MediaTime b) noexcept { return a > b ? a : b; }
    static constexpr MediaTime min(MediaTime a, MediaTime b) noexcept { return a < b ? a : b; }

    /// Clamped to a closed range.
    constexpr MediaTime clamped(MediaTime lower, MediaTime upper) const noexcept {
        return *this < lower ? lower : (*this > upper ? upper : *this);
    }

private:
    std::int64_t nanoseconds_;
};

/// Convenience matching the Swift call sites, which read `.seconds(1.5)`.
inline MediaTime seconds(double value) { return MediaTime::from_seconds(value); }
inline MediaTime milliseconds(double value) { return MediaTime::milliseconds(value); }

}  // namespace voxscripta
