#include "voxscripta/silence_detector.hpp"

#include <algorithm>

#include "voxscripta/errors.hpp"

namespace voxscripta {

namespace {

struct Run {
    bool value;
    int start;
    int length;
};

int frames_in(MediaTime duration, MediaTime hop) {
    return hop.nanoseconds() > 0 ? static_cast<int>(duration.nanoseconds() / hop.nanoseconds()) : 0;
}

std::vector<Run> run_lengths(const std::vector<bool>& flags) {
    std::vector<Run> runs;
    int start = 0;
    const int n = static_cast<int>(flags.size());
    for (int i = 1; i <= n; ++i) {
        if (i == n || flags[i] != flags[start]) {
            runs.push_back({flags[start], start, i - start});
            start = i;
        }
    }
    return runs;
}

/// Merges neighbouring runs that share a value after a gating pass.
std::vector<Run> coalesce(const std::vector<Run>& runs) {
    std::vector<Run> out;
    for (const Run& run : runs) {
        if (!out.empty() && out.back().value == run.value) {
            out.back().length += run.length;
        } else {
            out.push_back(run);
        }
    }
    return out;
}

/// Half-open frame span [lo, hi) covering `range`; never empty unless there are
/// no frames at all.
std::pair<int, int> frame_range(const FrameFeatures& f, const TimeRange& range) {
    const int lo = std::max(0, f.geometry.frame_at_time(range.start_time()));
    const int hi = std::min(f.count(), f.geometry.frame_at_time(range.end_time()));
    if (lo < hi) return {lo, hi};
    return {lo, std::min(lo + 1, f.count())};
}

float mean_db(const FrameFeatures& f, const TimeRange& range) {
    const auto [lo, hi] = frame_range(f, range);
    if (lo >= hi) return FrameAnalyzer::minimum_db;
    float sum = 0;
    for (int i = lo; i < hi; ++i) sum += f.rms_db[i];
    return sum / static_cast<float>(hi - lo);
}

float peak_db(const FrameFeatures& f, const TimeRange& range) {
    const auto [lo, hi] = frame_range(f, range);
    if (lo >= hi) return FrameAnalyzer::minimum_db;
    float peak = FrameAnalyzer::minimum_db;
    for (int i = lo; i < hi; ++i) peak = std::max(peak, f.rms_db[i]);
    return peak;
}

}  // namespace

SilenceMap SilenceDetector::detect(const FrameFeatures& features, const SilenceParameters& p,
                                   MediaTime source_duration,
                                   const std::string& parameter_hash) const {
    const int n = features.count();
    if (n <= 0) throw AnalysisFailed("silence detection", "no analysis frames");

    // Stage 1: noise floor.
    const std::vector<float> floor = noise_floor_tracker.track(features);

    // Stage 2: adaptive dual thresholds with hysteresis.
    std::vector<bool> is_speech(n, false);
    bool in_speech = false;
    for (int i = 0; i < n; ++i) {
        const float exit_level = std::max(floor[i] + p.margin_db, p.absolute_floor_db);
        const float enter_level = exit_level + p.hysteresis_db;
        const float level = features.rms_db[i];

        if (in_speech) {
            if (level < exit_level) {
                // Stage 3: fricative protection. A frame below the exit level is
                // still speech when it looks spectrally like sibilance.
                const bool is_fricative = p.fricative_protection &&
                                          features.zero_crossing_rate[i] > fricative_zcr_threshold &&
                                          features.spectral_flatness[i] > fricative_flatness_threshold &&
                                          level > floor[i] + fricative_margin_db;
                if (!is_fricative) in_speech = false;
            }
        } else if (level > enter_level) {
            in_speech = true;
        }
        is_speech[i] = in_speech;
    }

    // Stage 4: duration gating. Order matters: demote short speech first, then
    // promote short silence; reversed, noise is merged into speech.
    const MediaTime hop = features.geometry.hop_duration;
    const int min_speech_frames = frames_in(p.min_speech_duration, hop);
    const int min_silence_frames = frames_in(p.min_silence_duration, hop);

    std::vector<Run> runs = run_lengths(is_speech);
    for (Run& r : runs) {
        if (r.value && r.length < min_speech_frames) r.value = false;
    }
    runs = coalesce(runs);
    for (std::size_t i = 0; i < runs.size(); ++i) {
        if (!runs[i].value && runs[i].length < min_silence_frames) {
            // Leading and trailing silence is real silence, never a closure.
            if (i == 0 || i == runs.size() - 1) continue;
            runs[i].value = true;
        }
    }
    runs = coalesce(runs);

    // Stage 5: asymmetric padding, outward only.
    const TimeRange media(MediaTime::zero(), source_duration);
    std::vector<TimeRange> padded;
    for (const Run& run : runs) {
        if (!run.value) continue;
        const MediaTime start = features.geometry.time_of_frame(run.start);
        const MediaTime end =
            MediaTime::min(features.geometry.time_of_frame(run.start + run.length), source_duration);
        if (end <= start) continue;
        const TimeRange expanded = TimeRange(start, end).padded(p.pad_lead, p.pad_trail, media);
        if (!padded.empty() && expanded.start_time() <= padded.back().end_time()) {
            padded.back() = TimeRange(padded.back().start_time(),
                                      MediaTime::max(padded.back().end_time(), expanded.end_time()));
        } else {
            padded.push_back(expanded);
        }
    }
    if (padded.empty()) throw NoSpeechDetected();

    // Assemble.
    SilenceMap map;
    for (const TimeRange& range : padded) {
        map.speech_regions.push_back({range, mean_db(features, range), peak_db(features, range)});
    }
    MediaTime cursor = MediaTime::zero();
    for (const SpeechRegion& region : map.speech_regions) {
        if (region.range.start_time() > cursor) {
            const TimeRange range(cursor, region.range.start_time());
            map.gaps.push_back({range, mean_db(features, range)});
        }
        cursor = region.range.end_time();
    }
    if (cursor < source_duration) {
        const TimeRange range(cursor, source_duration);
        map.gaps.push_back({range, mean_db(features, range)});
    }
    map.noise_floor_profile = floor;
    map.parameters = p;
    map.parameter_hash = parameter_hash;
    map.source_duration = source_duration;
    return map;
}

}  // namespace voxscripta
