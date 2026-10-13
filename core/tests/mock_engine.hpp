#pragma once

// A deterministic stand-in for a speech engine (port of MockTranscriptionEngine).
//
// The scheduler and merger have logic worth testing precisely - retry budgets,
// ordering under concurrency, overlap de-duplication - and none of it should
// depend on a speech model's output. Word N always sits at time N / rate, so two
// chunks that overlap in time emit the very same words at the very same times,
// which is exactly what the merger's de-duplication has to recognise.

#include <algorithm>
#include <atomic>
#include <cmath>
#include <chrono>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

#include "voxscripta/audio_format.hpp"
#include "voxscripta/chunk_models.hpp"
#include "voxscripta/silence_models.hpp"
#include "voxscripta/transcription_engine.hpp"

namespace voxscripta::testing {

class MockEngine final : public TranscriptionEngine {
public:
    enum class Behaviour { succeed, fail_always, fail_times, slow };

    double words_per_second = 2.0;
    std::atomic<int> peak_concurrency{0};

    void register_plan(const ChunkPlan& plan) {
        for (const auto& c : plan.chunks) sequence_by_start_[c.sample_range.start_index()] = c.sequence;
    }
    void set_behaviour(int sequence, Behaviour b, int times = 0,
                       std::chrono::milliseconds delay = std::chrono::milliseconds(0)) {
        behaviours_[sequence] = {b, times, delay};
    }
    /// Sequences in the order transcription first started.
    std::vector<int> start_order() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return start_order_;
    }

    std::string identifier() const override { return "mock"; }
    EngineCapabilities capabilities() const override {
        EngineCapabilities c;
        c.supports_word_timestamps = true;
        c.supported_languages = {"en"};
        return c;
    }
    void prepare(const std::string&) override {}
    void release() override {}

    std::vector<TranscriptSegment> transcribe(const SampleRange& range, const float*,
                                              const TranscriptionOptions&) override {
        const int sequence = sequence_of(range);
        const int now = ++active_;
        int seen = peak_concurrency.load();
        while (now > seen && !peak_concurrency.compare_exchange_weak(seen, now)) {}
        struct Leave { std::atomic<int>& a; ~Leave() { --a; } } leave{active_};

        Spec spec;
        int attempt;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (std::find(start_order_.begin(), start_order_.end(), sequence) == start_order_.end()) {
                start_order_.push_back(sequence);
            }
            attempt = ++attempts_[sequence];
            const auto it = behaviours_.find(sequence);
            if (it != behaviours_.end()) spec = it->second;
        }
        if (spec.behaviour == Behaviour::fail_always) throw std::runtime_error("mock: always fails");
        if (spec.behaviour == Behaviour::fail_times && attempt <= spec.times) {
            throw std::runtime_error("mock: transient failure");
        }
        if (spec.behaviour == Behaviour::slow) std::this_thread::sleep_for(spec.delay);

        // Words whose whole span lies inside the chunk, 10 to a segment.
        const MediaTime start = MediaTime::from_samples(range.start_index(), CanonicalFormat::sample_rate);
        const MediaTime end = MediaTime::from_samples(range.end_index(), CanonicalFormat::sample_rate);
        const double step = 1.0 / words_per_second;
        std::vector<TranscriptSegment> out;
        TranscriptSegment current;
        for (long n = static_cast<long>(std::ceil(start.seconds() * words_per_second));; ++n) {
            const MediaTime w0 = seconds(static_cast<double>(n) * step);
            const MediaTime w1 = seconds(static_cast<double>(n) * step + step * 0.9);
            if (w1 > end) break;
            if (current.words.empty()) current.original_start = w0;
            current.words.push_back({"w" + std::to_string(n), w0, w1, 0.9f});
            current.original_end = w1;
            if (current.words.size() == 10) { finish(current, out); }
        }
        if (!current.words.empty()) finish(current, out);
        return out;
    }

private:
    struct Spec {
        Behaviour behaviour = Behaviour::succeed;
        int times = 0;
        std::chrono::milliseconds delay{0};
    };

    static void finish(TranscriptSegment& seg, std::vector<TranscriptSegment>& out) {
        for (const auto& w : seg.words) seg.text += (seg.text.empty() ? "" : " ") + w.text;
        out.push_back(std::move(seg));
        seg = TranscriptSegment{};
    }
    int sequence_of(const SampleRange& r) const {
        const auto it = sequence_by_start_.find(r.start_index());
        return it == sequence_by_start_.end() ? -1 : it->second;
    }

    std::map<std::int64_t, int> sequence_by_start_;
    std::map<int, Spec> behaviours_;
    std::map<int, int> attempts_;
    std::vector<int> start_order_;
    mutable std::mutex mutex_;
    std::atomic<int> active_{0};
};

/// One speech region of `speech_seconds` inside a recording, with an optional
/// 1 s silence gap every `gap_every` seconds (0 = none: continuous speech).
inline SilenceMap make_map(double speech_seconds, double gap_every = 0) {
    SilenceMap map;
    map.parameter_hash = "test";
    double t = 0;
    if (gap_every <= 0) {
        map.speech_regions.push_back({TimeRange(seconds(0), seconds(speech_seconds)), -20, -12});
        t = speech_seconds;
    } else {
        while (t < speech_seconds) {
            const double end = std::min(t + gap_every, speech_seconds);
            map.speech_regions.push_back({TimeRange(seconds(t), seconds(end)), -20, -12});
            t = end;
            if (t < speech_seconds) {
                map.gaps.push_back({TimeRange(seconds(t), seconds(t + 1.0)), -60});
                t += 1.0;
            }
        }
    }
    map.source_duration = seconds(t);
    return map;
}

}  // namespace voxscripta::testing
