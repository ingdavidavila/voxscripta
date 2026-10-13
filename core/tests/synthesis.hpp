#pragma once

// Port of Sources/VoxScriptaTestSupport (DeterministicRandom, SignalSynthesizer,
// StandardCorpus). The signal is not real speech; it reproduces the energy,
// zero-crossing rate and spectral flatness the silence detector keys on, exactly
// and reproducibly, with ground-truth span boundaries known by construction.

#include <cstdint>
#include <string>
#include <vector>

#include "voxscripta/audio_format.hpp"
#include "voxscripta/time_range.hpp"

namespace voxscripta::testing {

class DeterministicRandom {
public:
    explicit DeterministicRandom(std::uint64_t seed)
        : state_(seed == 0 ? 0x9E3779B97F4A7C15ULL : seed) {}

    std::uint64_t next() {
        state_ = state_ * 6364136223846793005ULL + 1442695040888963407ULL;
        return state_;
    }
    double uniform() { return static_cast<double>(next() >> 11) * (1.0 / 9007199254740992.0); }
    double bipolar() { return uniform() * 2 - 1; }
    double gaussian() {
        double sum = 0;
        for (int i = 0; i < 6; ++i) sum += uniform();
        return (sum - 3) / 0.7071;
    }

private:
    std::uint64_t state_;
};

enum class SignalKind { voiced, fricative, voiced_with_closures, silence };

struct SignalSpan {
    SignalKind kind;
    TimeRange range;
    double level_db;

    bool is_speech() const { return kind != SignalKind::silence; }
};

struct CorpusCase {
    std::string name;
    std::vector<SignalSpan> spans;
    double noise_floor_db = -62;
    bool ramps_noise = false;
    double noise_floor_end_db = 0;
    std::uint64_t seed = 0x0C7A5EEDULL;

    MediaTime duration() const {
        return spans.empty() ? MediaTime::zero() : spans.back().range.end_time();
    }
    /// Speech spans with adjacent spans coalesced.
    std::vector<TimeRange> expected_speech_regions() const;
    std::vector<float> render() const;
};

namespace corpus {
CorpusCase basic();
CorpusCase quiet_speaker();
CorpusCase fricatives();
CorpusCase stop_closures();
CorpusCase long_pause();
CorpusCase rising_noise_floor();
CorpusCase noisy_room();
CorpusCase continuous_speech();
CorpusCase room_tone_only();
std::vector<CorpusCase> all();
}  // namespace corpus

}  // namespace voxscripta::testing
