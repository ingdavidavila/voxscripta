// Ported from Tests/VoxScriptaDSPTests/FrameGeometryTests.swift, plus a check
// that the streaming file path agrees with the in-memory path.

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <stdexcept>

#include "harness.hpp"
#include "synthesis.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/frame_analysis.hpp"

using namespace voxscripta;

VS_TEST("Frame geometry", "Default geometry is 25 ms windows at a 10 ms hop") {
    FrameGeometry g;
    VS_EXPECT_EQ(g.sample_rate, CanonicalFormat::sample_rate);
    VS_EXPECT_EQ(g.window_samples(), 400);
    VS_EXPECT_EQ(g.hop_samples(), 160);
}

VS_TEST("Frame geometry", "Frame count for a known sample count") {
    FrameGeometry g;
    VS_EXPECT_EQ(g.frame_count_for_samples(0), 0);
    VS_EXPECT_EQ(g.frame_count_for_samples(399), 0);
    VS_EXPECT_EQ(g.frame_count_for_samples(400), 1);
    VS_EXPECT_EQ(g.frame_count_for_samples(560), 2);
    VS_EXPECT_EQ(g.frame_count_for_samples(16'000), 98);
}

VS_TEST("Frame geometry", "Frame index and time round-trip") {
    FrameGeometry g;
    for (int index : {0, 1, 100, 99'999}) {
        VS_EXPECT_EQ(g.frame_at_time(g.time_of_frame(index)), index);
    }
    VS_EXPECT_EQ(g.time_of_frame(100), seconds(1));
}

VS_TEST("Frame geometry", "Negative times clamp to frame zero") {
    VS_EXPECT_EQ(FrameGeometry{}.frame_at_time(seconds(-5)), 0);
}

VS_TEST("Frame geometry", "Feature storage stays about 8 MB for a six-hour recording") {
    FrameGeometry g;
    const std::int64_t samples = seconds(6 * 3600).samples_at(g.sample_rate);
    const std::int64_t frames = g.frame_count_for_samples(samples);
    VS_EXPECT(frames * 3 * static_cast<std::int64_t>(sizeof(float)) < 30'000'000);
    VS_EXPECT(frames > 2'000'000);
}

VS_TEST("Frame features", "Feature arrays report a consistent count") {
    FrameFeatures f({-20, -30, -40}, {0.1f, 0.2f, 0.3f}, {0.5f, 0.6f, 0.7f});
    VS_EXPECT_EQ(f.count(), 3);
    VS_EXPECT(!f.empty());
}

VS_TEST("Frame features", "An empty feature set is well-formed") {
    FrameFeatures f({}, {}, {});
    VS_EXPECT(f.empty());
    VS_EXPECT_EQ(f.count(), 0);
    VS_EXPECT_EQ(f.duration(), MediaTime::zero());
}

VS_TEST("Frame features", "Mismatched array lengths are refused") {
    VS_EXPECT_THROWS(FrameFeatures({-20, -30}, {0.1f}, {0.5f, 0.6f}), std::invalid_argument);
}

VS_TEST("Frame analysis", "A recording shorter than one window is refused") {
    const float samples[100] = {};
    VS_EXPECT_THROWS(FrameAnalyzer().analyze(samples, 100, FrameGeometry{}), AnalysisFailed);
}

VS_TEST("Frame analysis", "A full-scale sine measures about -3 dBFS and a flat spectrum is not tonal") {
    std::vector<float> tone(16'000);
    for (std::size_t i = 0; i < tone.size(); ++i) {
        tone[i] = static_cast<float>(std::sin(2 * 3.14159265358979 * 440.0 * i / 16'000.0));
    }
    const FrameFeatures f = FrameAnalyzer().analyze(tone.data(), tone.size(), FrameGeometry{});
    VS_EXPECT(std::abs(f.rms_db[10] - (-3.01f)) < 0.1f);
    VS_EXPECT(f.spectral_flatness[10] < 0.05f);   // a pure tone is as un-flat as it gets
    VS_EXPECT(f.zero_crossing_rate[10] < 0.1f);   // 880 crossings/s out of 16000
}

VS_TEST("Frame analysis", "Streaming a file gives the same features as analyzing memory") {
    const auto samples = testing::corpus::basic().render();
    const auto path = std::filesystem::temp_directory_path() / "voxscripta_stream_test.f32";
    {
        std::ofstream out(path, std::ios::binary);
        out.write(reinterpret_cast<const char*>(samples.data()),
                  static_cast<std::streamsize>(samples.size() * sizeof(float)));
    }
    const FrameAnalyzer analyzer;
    const FrameFeatures memory = analyzer.analyze(samples.data(), samples.size(), FrameGeometry{});
    const FrameFeatures streamed = analyzer.analyze_file(path.string(), FrameGeometry{});
    std::filesystem::remove(path);

    VS_EXPECT_EQ(memory.count(), streamed.count());
    VS_EXPECT(memory.rms_db == streamed.rms_db);
    VS_EXPECT(memory.zero_crossing_rate == streamed.zero_crossing_rate);
    VS_EXPECT(memory.spectral_flatness == streamed.spectral_flatness);
}

VS_TEST("Frame analysis", "Cancellation from the progress callback is honoured") {
    const auto samples = testing::corpus::basic().render();
    bool cancelled = false;
    try {
        FrameAnalyzer().analyze(samples.data(), samples.size(), FrameGeometry{},
                                [](double) { return false; });
    } catch (const AnalysisCancelled&) {
        cancelled = true;
    }
    VS_EXPECT(cancelled);
}
