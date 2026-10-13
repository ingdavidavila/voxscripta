#include "synthesis.hpp"

#include <algorithm>
#include <cmath>

namespace voxscripta::testing {

namespace {

constexpr double kPi = 3.14159265358979323846;

void add_voiced(std::vector<float>& out, int start, int end, double amplitude,
                DeterministicRandom& rng, int rate) {
    const double f0 = 120.0;
    const double weights[6] = {1.0, 0.6, 0.42, 0.22, 0.13, 0.07};
    for (int i = start; i < end; ++i) {
        const double t = static_cast<double>(i - start) / rate;
        // ~12 dB variation within a syllable at ~4 Hz; never reaches zero.
        const double raised = 0.5 + 0.5 * std::sin(2 * kPi * 4.0 * t);
        const double syllable = 0.25 + 0.75 * std::pow(raised, 1.4);
        double sample = 0;
        for (int h = 0; h < 6; ++h) sample += weights[h] * std::sin(2 * kPi * f0 * (h + 1) * t);
        sample /= 2.44;
        const double jitter = 1 + rng.bipolar() * 0.02;
        out[i] += static_cast<float>(sample * syllable * amplitude * jitter);
    }
}

void add_fricative(std::vector<float>& out, int start, int end, double amplitude,
                   DeterministicRandom& rng) {
    double previous = 0;
    for (int i = start; i < end; ++i) {
        const double white = rng.gaussian();
        const double high_passed = white - previous * 0.85;
        previous = white;
        out[i] += static_cast<float>(high_passed * amplitude * 0.5);
    }
}

void add_voiced_with_closures(std::vector<float>& out, int start, int end, double amplitude,
                              DeterministicRandom& rng, int rate) {
    add_voiced(out, start, end, amplitude, rng, rate);
    const int closure = static_cast<int>(0.060 * rate);
    const int period = static_cast<int>(0.400 * rate);
    for (int position = start + period; position + closure < end; position += period) {
        for (int i = position; i < position + closure; ++i) out[i] *= 0.02f;
    }
}

SignalSpan span(SignalKind kind, double from, double to, double db) {
    return {kind, TimeRange(seconds(from), seconds(to)), db};
}

}  // namespace

std::vector<TimeRange> CorpusCase::expected_speech_regions() const {
    std::vector<TimeRange> out;
    for (const auto& s : spans) {
        if (!s.is_speech()) continue;
        if (!out.empty() && out.back().end_time() == s.range.start_time()) {
            out.back() = TimeRange(out.back().start_time(), s.range.end_time());
        } else {
            out.push_back(s.range);
        }
    }
    return out;
}

std::vector<float> CorpusCase::render(int rate) const {
    const int count = static_cast<int>(duration().samples_at(rate));
    if (count <= 0) return {};
    std::vector<float> out(count);
    DeterministicRandom rng(seed);

    // Room tone everywhere: "silence" is never digital zero.
    const double end_db = ramps_noise ? noise_floor_end_db : noise_floor_db;
    for (int i = 0; i < count; ++i) {
        const double t = static_cast<double>(i) / count;
        const double level = noise_floor_db + (end_db - noise_floor_db) * t;
        out[i] = static_cast<float>(rng.gaussian() * std::pow(10, level / 20) * 0.3);
    }
    for (const auto& s : spans) {
        const int start = static_cast<int>(s.range.start_time().samples_at(rate));
        const int end = std::min(static_cast<int>(s.range.end_time().samples_at(rate)), count);
        if (end <= start) continue;
        const double amplitude = std::pow(10, s.level_db / 20);
        switch (s.kind) {
            case SignalKind::silence: break;
            case SignalKind::voiced: add_voiced(out, start, end, amplitude, rng, rate); break;
            case SignalKind::fricative: add_fricative(out, start, end, amplitude, rng); break;
            case SignalKind::voiced_with_closures:
                add_voiced_with_closures(out, start, end, amplitude, rng, rate);
                break;
        }
    }
    return out;
}

namespace corpus {

using K = SignalKind;

CorpusCase basic() {
    return {"basic_speech_silence",
            {span(K::silence, 0, 2, -62), span(K::voiced, 2, 7, -18), span(K::silence, 7, 10, -62),
             span(K::voiced, 10, 16, -18), span(K::silence, 16, 18, -62)}};
}
CorpusCase quiet_speaker() {
    return {"quiet_speaker",
            {span(K::silence, 0, 2, -62), span(K::voiced, 2, 8, -38), span(K::silence, 8, 11, -62),
             span(K::voiced, 11, 16, -38), span(K::silence, 16, 18, -62)}};
}
CorpusCase fricatives() {
    return {"fricatives",
            {span(K::silence, 0, 2, -62), span(K::voiced, 2, 6, -18), span(K::fricative, 6, 6.4, -57),
             span(K::silence, 6.4, 9, -62), span(K::voiced, 9, 13, -18),
             span(K::fricative, 13, 13.45, -56), span(K::silence, 13.45, 16, -62)}};
}
CorpusCase stop_closures() {
    return {"stop_closures",
            {span(K::silence, 0, 2, -62), span(K::voiced_with_closures, 2, 12, -20),
             span(K::silence, 12, 15, -62)}};
}
CorpusCase long_pause() {
    return {"long_pause",
            {span(K::voiced, 0, 4, -18), span(K::silence, 4, 9, -62), span(K::voiced, 9, 14, -18)}};
}
CorpusCase rising_noise_floor() {
    CorpusCase c{"rising_noise_floor",
                 {span(K::silence, 0, 2, -62), span(K::voiced, 2, 7, -20), span(K::silence, 7, 10, -62),
                  span(K::voiced, 10, 15, -20), span(K::silence, 15, 17, -62)}};
    c.noise_floor_db = -62;
    c.ramps_noise = true;
    c.noise_floor_end_db = -42;
    return c;
}
CorpusCase noisy_room() {
    CorpusCase c{"noisy_room",
                 {span(K::silence, 0, 2, -34), span(K::voiced, 2, 8, -22), span(K::silence, 8, 11, -34),
                  span(K::voiced, 11, 16, -22), span(K::silence, 16, 18, -34)}};
    c.noise_floor_db = -34;
    return c;
}
CorpusCase continuous_speech() { return {"continuous_speech", {span(K::voiced, 0, 360, -20)}}; }
CorpusCase room_tone_only() {
    CorpusCase c{"room_tone_only", {span(K::silence, 0, 20, -34)}};
    c.noise_floor_db = -34;
    return c;
}
std::vector<CorpusCase> all() {
    return {basic(),       quiet_speaker(),       fricatives(),       stop_closures(),
            long_pause(),  rising_noise_floor(),  noisy_room(),       continuous_speech(),
            room_tone_only()};
}

}  // namespace corpus
}  // namespace voxscripta::testing
