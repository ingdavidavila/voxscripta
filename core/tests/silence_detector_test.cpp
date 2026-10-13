// Ported from Tests/VoxScriptaDSPTests/SilenceDetectorTests.swift. The synthetic
// corpus is regenerated here rather than shared, so the C++ detector is graded
// against the same ground-truth structure the Swift one is.

#include <algorithm>
#include <cmath>

#include "harness.hpp"
#include "synthesis.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/silence_detector.hpp"

using namespace voxscripta;
using namespace voxscripta::testing;

namespace {

struct DetectionRun {
    CorpusCase test_case;
    SilenceMap map;

    explicit DetectionRun(const CorpusCase& c, const SilenceParameters& p = {})
        : test_case(c), map(detect(c, p)) {}

    static SilenceMap detect(const CorpusCase& c, const SilenceParameters& p) {
        const auto samples = c.render();
        const FrameFeatures features =
            FrameAnalyzer().analyze(samples.data(), samples.size(), FrameGeometry{});
        return SilenceDetector{}.detect(features, p, c.duration(), "test");
    }

    /// Fraction of ground-truth speech time the detector covered. Recall is the
    /// metric that matters most: missing speech loses words permanently.
    double speech_recall() const {
        double total = 0, covered = 0;
        const auto truth = test_case.expected_speech_regions();
        for (const auto& t : truth) total += t.duration().seconds();
        if (total <= 0) return 1;
        for (const auto& t : truth) {
            for (const auto& d : map.speech_regions) {
                if (auto overlap = t.intersection(d.range)) covered += overlap->duration().seconds();
            }
        }
        return covered / total;
    }

    double silence_rejection() const {
        std::vector<TimeRange> silence;
        MediaTime cursor = MediaTime::zero();
        for (const auto& r : test_case.expected_speech_regions()) {
            if (r.start_time() > cursor) silence.emplace_back(cursor, r.start_time());
            cursor = r.end_time();
        }
        if (cursor < test_case.duration()) silence.emplace_back(cursor, test_case.duration());
        double total = 0, kept = 0;
        for (const auto& s : silence) total += s.duration().seconds();
        if (total <= 0) return 1;
        for (const auto& s : silence) {
            for (const auto& d : map.speech_regions) {
                if (auto overlap = s.intersection(d.range)) kept += overlap->duration().seconds();
            }
        }
        return 1 - kept / total;
    }
};

std::vector<TimeRange> ranges(const SilenceMap& m) {
    std::vector<TimeRange> out;
    for (const auto& r : m.speech_regions) out.push_back(r.range);
    return out;
}

}  // namespace

VS_TEST("Silence detection", "Baseline: speech is found and silence is rejected") {
    DetectionRun run(corpus::basic());
    VS_EXPECT_EQ(run.map.speech_regions.size(), std::size_t{2});
    VS_EXPECT(run.speech_recall() > 0.99);
    VS_EXPECT(run.silence_rejection() > 0.70);
}

VS_TEST("Silence detection", "A quiet speaker at -38 dBFS is not gated out") {
    DetectionRun run(corpus::quiet_speaker());
    VS_EXPECT(run.speech_recall() > 0.98);
    VS_EXPECT_EQ(run.map.speech_regions.size(), std::size_t{2});
}

VS_TEST("Silence detection", "Trailing fricatives are not truncated") {
    DetectionRun with_protection(corpus::fricatives());
    VS_EXPECT(with_protection.speech_recall() > 0.97);

    // Control: with stage 3 off the same audio must do measurably worse, which
    // shows the stage does the work rather than padding masking the problem.
    SilenceParameters off;
    off.fricative_protection = false;
    off.pad_trail = MediaTime::zero();
    SilenceParameters on;
    on.pad_trail = MediaTime::zero();

    DetectionRun with_stage(corpus::fricatives(), on);
    DetectionRun without_stage(corpus::fricatives(), off);
    VS_EXPECT(with_stage.speech_recall() > without_stage.speech_recall());
}

VS_TEST("Silence detection", "Stop closures do not fragment a word") {
    DetectionRun run(corpus::stop_closures());
    VS_EXPECT_EQ(run.map.speech_regions.size(), std::size_t{1});
    VS_EXPECT(run.speech_recall() > 0.99);
}

VS_TEST("Silence detection", "A five-second pause is preserved as a boundary") {
    DetectionRun run(corpus::long_pause());
    VS_EXPECT_EQ(run.map.speech_regions.size(), std::size_t{2});
    const auto it = std::find_if(run.map.gaps.begin(), run.map.gaps.end(),
                                 [](const SilenceGap& g) { return g.duration() > seconds(3); });
    VS_EXPECT(it != run.map.gaps.end());
    if (it != run.map.gaps.end()) {
        VS_EXPECT(it->duration() > seconds(4));
        VS_EXPECT(it->duration() < seconds(5));  // padding eats into it from both sides
    }
}

VS_TEST("Silence detection", "A rising noise floor is tracked rather than fixed") {
    DetectionRun run(corpus::rising_noise_floor());
    VS_EXPECT(run.speech_recall() > 0.97);
    VS_EXPECT_EQ(run.map.speech_regions.size(), std::size_t{2});
}

VS_TEST("Silence detection", "Speech survives a loud room") {
    DetectionRun run(corpus::noisy_room());
    VS_EXPECT(run.speech_recall() > 0.95);
}

VS_TEST("Silence detection", "Continuous speech yields one region covering the recording") {
    DetectionRun run(corpus::continuous_speech());
    VS_EXPECT_EQ(run.map.speech_regions.size(), std::size_t{1});
    VS_EXPECT(run.map.speech_fraction() > 0.98);
}

VS_TEST("Silence detection", "Detection is deterministic") {
    DetectionRun a(corpus::basic());
    DetectionRun b(corpus::basic());
    VS_EXPECT(ranges(a.map) == ranges(b.map));
}

VS_TEST("Silence detection", "The conservative preset never keeps less speech than the default") {
    for (const auto& c : {corpus::quiet_speaker(), corpus::noisy_room()}) {
        DetectionRun d(c, SilenceParameters{});
        DetectionRun k(c, SilenceParameters::conservative());
        VS_EXPECT(k.speech_recall() >= d.speech_recall() - 0.001);
    }
}

VS_TEST("Silence detection", "Boundary error stays within tolerance on clean material") {
    // Padding moves boundaries outward, so compare against truth expanded by the
    // same padding; otherwise the metric would just measure the padding constants.
    const SilenceParameters params;
    std::vector<double> errors;
    for (const auto& c : {corpus::basic(), corpus::long_pause(), corpus::quiet_speaker()}) {
        DetectionRun run(c, params);
        const TimeRange media(MediaTime::zero(), c.duration());
        std::vector<TimeRange> truth;
        for (const auto& t : c.expected_speech_regions()) {
            truth.push_back(t.padded(params.pad_lead, params.pad_trail, media));
        }
        VS_EXPECT_MSG(run.map.speech_regions.size() == truth.size(), c.name + ": region count");
        if (run.map.speech_regions.size() != truth.size()) continue;
        for (std::size_t i = 0; i < truth.size(); ++i) {
            const auto& d = run.map.speech_regions[i].range;
            errors.push_back(std::abs((d.start_time() - truth[i].start_time()).seconds()));
            errors.push_back(std::abs((d.end_time() - truth[i].end_time()).seconds()));
        }
    }
    double sum = 0, worst = 0;
    for (double e : errors) { sum += e; worst = std::max(worst, e); }
    const double mae = errors.empty() ? 0 : sum / static_cast<double>(errors.size());
    VS_EXPECT_MSG(mae < 0.050, "mean boundary error " + std::to_string(mae) + " s exceeds 50 ms");
    VS_EXPECT_MSG(worst < 0.150, "worst boundary error " + std::to_string(worst) + " s exceeds 150 ms");
}

VS_TEST("Silence detection", "A recording with no speech reports no speech") {
    // The regression the flatness gate exists to prevent: loud room tone is
    // homogeneous in level exactly like pause-free speech.
    VS_EXPECT_THROWS(DetectionRun(corpus::room_tone_only()), NoSpeechDetected);
}

VS_TEST("Silence detection", "Every speech region carries plausible energy measurements") {
    DetectionRun run(corpus::basic());
    for (const auto& r : run.map.speech_regions) {
        VS_EXPECT(r.peak_energy_db >= r.mean_energy_db);
        VS_EXPECT(r.mean_energy_db > -60);
        VS_EXPECT(r.peak_energy_db < 0);
    }
}

VS_TEST("Silence detection", "Regions are ordered, disjoint, and inside the recording") {
    for (const auto& c : corpus::all()) {
        if (c.name == "room_tone_only") continue;
        DetectionRun run(c);
        const auto& regions = run.map.speech_regions;
        for (const auto& r : regions) {
            VS_EXPECT(r.range.start_time() >= MediaTime::zero());
            VS_EXPECT(r.range.end_time() <= c.duration());
        }
        for (std::size_t i = 1; i < regions.size(); ++i) {
            VS_EXPECT(regions[i - 1].range.end_time() <= regions[i].range.start_time());
        }
        VS_EXPECT(run.map.speech_duration() <= c.duration());
    }
}

VS_TEST("Silence map", "Processed and original time map through the gaps") {
    DetectionRun run(corpus::long_pause());
    const auto& m = run.map;
    const MediaTime first_start = m.speech_regions[0].range.start_time();
    VS_EXPECT_EQ(m.original_time_for_processed(MediaTime::zero()), first_start);
    VS_EXPECT(m.processed_time_for_original(first_start).has_value());
    // The middle of the 5 s pause has no processed counterpart.
    VS_EXPECT(!m.processed_time_for_original(seconds(6.5)).has_value());
}
