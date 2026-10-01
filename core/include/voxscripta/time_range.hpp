#pragma once

#include <cstdint>
#include <optional>
#include <string>

#include "voxscripta/media_time.hpp"

namespace voxscripta {

/// A half-open span [start, end) on an audio timeline.
///
/// Half-open is deliberate: adjacent ranges that share an endpoint do not
/// overlap, so a chunk plan can tile a recording exactly with no double-counted
/// sample and no gap.
class TimeRange {
public:
    /// Throws std::invalid_argument when start is after end.
    TimeRange(MediaTime start, MediaTime end);

    static TimeRange with_duration(MediaTime start, MediaTime duration) {
        return TimeRange(start, start + duration);
    }

    // Named start_time/end_time rather than start/end: Swift's C++ interop
    // does not import a member called `end` (it reserves the name for its
    // sequence bridging), and this core is consumed from Swift, Kotlin and C++
    // alike. An accessor that only some callers can see is worse than a longer
    // name.
    constexpr MediaTime start_time() const noexcept { return start_; }
    constexpr MediaTime end_time() const noexcept { return end_; }
    constexpr MediaTime duration() const noexcept { return end_ - start_; }
    constexpr bool is_empty() const noexcept { return start_ == end_; }

    constexpr bool contains(MediaTime t) const noexcept { return t >= start_ && t < end_; }
    constexpr bool overlaps(const TimeRange& other) const noexcept {
        return start_ < other.end_ && other.start_ < end_;
    }

    /// The overlapping span, or nullopt when the ranges are disjoint or merely touch.
    std::optional<TimeRange> intersection(const TimeRange& other) const;

    /// Expanded by `lead` before the start and `trail` after the end, clamped
    /// to `limit`.
    ///
    /// Used for the asymmetric speech padding in the silence detector, where
    /// trailing padding is larger than leading because word-final decay
    /// outlasts word-initial onset.
    TimeRange padded(MediaTime lead, MediaTime trail, const TimeRange& limit) const;

    constexpr bool operator==(const TimeRange& other) const noexcept {
        return start_ == other.start_ && end_ == other.end_;
    }
    constexpr bool operator!=(const TimeRange& other) const noexcept { return !(*this == other); }

    std::string to_string() const;

private:
    MediaTime start_;
    MediaTime end_;
};

/// A half-open span of sample indices into a canonical PCM buffer.
///
/// This is what a "chunk" actually is at the storage layer: a view into the
/// single memory-mapped canonical.f32, not a separate audio file.
class SampleRange {
public:
    /// Throws std::invalid_argument when start or count is negative.
    SampleRange(std::int64_t start, std::int64_t count);

    constexpr std::int64_t start_index() const noexcept { return start_; }
    constexpr std::int64_t count() const noexcept { return count_; }
    constexpr std::int64_t end_index() const noexcept { return start_ + count_; }
    constexpr bool is_empty() const noexcept { return count_ == 0; }

    /// The byte span this range occupies in a 32-bit float PCM file.
    constexpr std::int64_t byte_begin() const noexcept { return start_ * 4; }
    constexpr std::int64_t byte_end() const noexcept { return end_index() * 4; }

    TimeRange time_range_at(int sample_rate) const;

    constexpr bool operator==(const SampleRange& other) const noexcept {
        return start_ == other.start_ && count_ == other.count_;
    }
    constexpr bool operator!=(const SampleRange& other) const noexcept { return !(*this == other); }

private:
    std::int64_t start_;
    std::int64_t count_;
};

}  // namespace voxscripta
