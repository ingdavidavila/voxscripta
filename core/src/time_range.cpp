#include "voxscripta/time_range.hpp"

#include <stdexcept>

namespace voxscripta {

TimeRange::TimeRange(MediaTime start, MediaTime end) : start_(start), end_(end) {
    if (start > end) {
        throw std::invalid_argument("TimeRange requires start <= end (got " + start.to_string() +
                                    " > " + end.to_string() + ")");
    }
}

std::optional<TimeRange> TimeRange::intersection(const TimeRange& other) const {
    const MediaTime lo = MediaTime::max(start_, other.start_);
    const MediaTime hi = MediaTime::min(end_, other.end_);
    if (lo < hi) {
        return TimeRange(lo, hi);
    }
    return std::nullopt;
}

TimeRange TimeRange::padded(MediaTime lead, MediaTime trail, const TimeRange& limit) const {
    return TimeRange(MediaTime::max(start_ - lead, limit.start_time()),
                     MediaTime::min(end_ + trail, limit.end_time()));
}

std::string TimeRange::to_string() const {
    return "[" + start_.to_string() + " \xE2\x86\x92 " + end_.to_string() + "]";
}

SampleRange::SampleRange(std::int64_t start, std::int64_t count) : start_(start), count_(count) {
    if (start < 0) {
        throw std::invalid_argument("sample start must be non-negative");
    }
    if (count < 0) {
        throw std::invalid_argument("sample count must be non-negative");
    }
}

TimeRange SampleRange::time_range_at(int sample_rate) const {
    return TimeRange(MediaTime::from_samples(start_, sample_rate),
                     MediaTime::from_samples(end_index(), sample_rate));
}

}  // namespace voxscripta
