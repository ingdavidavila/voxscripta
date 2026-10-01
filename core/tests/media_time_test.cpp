// Ported from Tests/VoxScriptaCoreTests/MediaTimeTests.swift.
//
// The Swift tests are the specification during the migration, so these keep
// their names and their assertions. Where a case checks something the C++ type
// does differently on purpose — Codable has no counterpart, invalid input
// throws rather than trapping — the difference is noted at the case.

#include <stdexcept>

#include "harness.hpp"
#include "voxscripta/media_time.hpp"
#include "voxscripta/time_range.hpp"

using voxscripta::MediaTime;
using voxscripta::SampleRange;
using voxscripta::TimeRange;
using voxscripta::milliseconds;
using voxscripta::seconds;

VS_TEST("MediaTime", "Sample conversion is exact at the canonical rate") {
    for (std::int64_t samples : {std::int64_t{0}, std::int64_t{1}, std::int64_t{160},
                                 std::int64_t{16'000}, std::int64_t{345'600'000}}) {
        const auto t = MediaTime::from_samples(samples, 16'000);
        VS_EXPECT_EQ(t.samples_at(16'000), samples);
    }
}

VS_TEST("MediaTime", "Six hours of accumulation introduces no drift") {
    // The whole reason timing is stored as integer nanoseconds: adding
    // thousands of chunk offsets must not wander.
    const auto hop = MediaTime::milliseconds(10);
    auto sum = MediaTime::zero();
    for (int i = 0; i < 2'160'000; ++i) {
        sum = sum + hop;
    }
    VS_EXPECT(sum == seconds(21'600));
    VS_EXPECT_EQ(sum.nanoseconds(), std::int64_t{21'600'000'000'000});
}

VS_TEST("MediaTime", "Ordering and arithmetic") {
    const auto a = seconds(1.5);
    const auto b = milliseconds(500);
    VS_EXPECT(a + b == seconds(2));
    VS_EXPECT(a - b == seconds(1));
    VS_EXPECT(b < a);
    VS_EXPECT(MediaTime::max(a, b) == a);
    VS_EXPECT(MediaTime::min(a, b) == b);
}

VS_TEST("MediaTime", "Clamping to a range") {
    const auto lower = MediaTime::zero();
    const auto upper = seconds(10);
    VS_EXPECT(seconds(-5).clamped(lower, upper) == MediaTime::zero());
    VS_EXPECT(seconds(50).clamped(lower, upper) == seconds(10));
    VS_EXPECT(seconds(5).clamped(lower, upper) == seconds(5));
}

VS_TEST("MediaTime", "Description formats for display") {
    VS_EXPECT_EQ(seconds(0).to_string(), std::string("0:00.000"));
    VS_EXPECT_EQ(seconds(65.25).to_string(), std::string("1:05.250"));
    VS_EXPECT_EQ(seconds(3725.5).to_string(), std::string("1:02:05.500"));
    VS_EXPECT_EQ(seconds(-1.5).to_string(), std::string("-0:01.500"));
}

VS_TEST("MediaTime", "Invalid input throws rather than trapping") {
    // Swift uses precondition here, which traps. A core called across a bridge
    // has to be able to report the problem instead of killing the process.
    VS_EXPECT_THROWS(MediaTime::from_seconds(std::nan("")), std::invalid_argument);
    VS_EXPECT_THROWS(MediaTime::from_samples(100, 0), std::invalid_argument);
    VS_EXPECT_THROWS(seconds(1).samples_at(-1), std::invalid_argument);
}

VS_TEST("TimeRange", "Half-open ranges tile without overlap") {
    const TimeRange a(seconds(0), seconds(10));
    const TimeRange b(seconds(10), seconds(20));
    VS_EXPECT(!a.overlaps(b));
    VS_EXPECT(!a.intersection(b).has_value());
    VS_EXPECT(!a.contains(seconds(10)));
    VS_EXPECT(b.contains(seconds(10)));
}

VS_TEST("TimeRange", "Intersection") {
    const TimeRange a(seconds(0), seconds(10));
    const TimeRange b(seconds(5), seconds(15));
    const auto overlap = a.intersection(b);
    VS_EXPECT(overlap.has_value());
    VS_EXPECT(overlap.value() == TimeRange(seconds(5), seconds(10)));
    VS_EXPECT(a.overlaps(b));
}

VS_TEST("TimeRange", "Padding expands outward only and clamps to the media") {
    const TimeRange media(MediaTime::zero(), seconds(60));
    const TimeRange r(seconds(0.1), seconds(59.9));
    const auto padded = r.padded(milliseconds(200), milliseconds(350), media);
    // Clamped at both ends rather than running off the recording.
    VS_EXPECT(padded.start_time() == MediaTime::zero());
    VS_EXPECT(padded.end_time() == seconds(60));

    const TimeRange inner(seconds(10), seconds(20));
    const auto p2 = inner.padded(milliseconds(200), milliseconds(350), media);
    VS_EXPECT(p2.start_time() == milliseconds(9800));
    VS_EXPECT(p2.end_time() == milliseconds(20350));
    VS_EXPECT(p2.duration() > inner.duration());
}

VS_TEST("TimeRange", "An inverted range is refused") {
    VS_EXPECT_THROWS(TimeRange(seconds(10), seconds(5)), std::invalid_argument);
}

VS_TEST("TimeRange", "SampleRange maps to bytes and time") {
    const SampleRange r(16'000, 32'000);
    VS_EXPECT_EQ(r.end_index(), std::int64_t{48'000});
    VS_EXPECT_EQ(r.byte_begin(), std::int64_t{64'000});
    VS_EXPECT_EQ(r.byte_end(), std::int64_t{192'000});
    const auto t = r.time_range_at(16'000);
    VS_EXPECT(t.start_time() == seconds(1));
    VS_EXPECT(t.end_time() == seconds(3));
    VS_EXPECT(t.duration() == seconds(2));
}

VS_TEST("TimeRange", "A negative sample range is refused") {
    VS_EXPECT_THROWS(SampleRange(-1, 10), std::invalid_argument);
    VS_EXPECT_THROWS(SampleRange(0, -10), std::invalid_argument);
}

VS_TEST("MediaTime", "Conversion past the representable duration throws") {
    // Six hours is 2.16e13 ns, so the app's own working range is nowhere near
    // this. The guard exists because signed overflow is undefined behaviour in
    // C++ and the optimiser is entitled to assume it never happens.
    const auto beyond = MediaTime(4'611'686'018'427'387);  // ~53 days
    VS_EXPECT_THROWS(beyond.samples_at(48'000), std::overflow_error);
    VS_EXPECT_THROWS(MediaTime::from_samples(std::int64_t{1} << 40, 16'000),
                     std::overflow_error);

    // The durations the app actually handles stay exact.
    const auto six_hours = seconds(21'600);
    VS_EXPECT_EQ(six_hours.samples_at(48'000), std::int64_t{1'036'800'000});
}
