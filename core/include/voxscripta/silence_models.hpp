#pragma once

#include <optional>
#include <string>
#include <vector>

#include "voxscripta/media_time.hpp"
#include "voxscripta/time_range.hpp"

namespace voxscripta {

/// Tunable parameters for the five-stage silence detector. Defaults match
/// SilenceParameters in the Swift implementation.
struct SilenceParameters {
    float margin_db = 8;
    float hysteresis_db = 4;
    float absolute_floor_db = -65;
    MediaTime min_speech_duration = milliseconds(200);
    MediaTime min_silence_duration = milliseconds(500);
    MediaTime pad_lead = milliseconds(200);
    MediaTime pad_trail = milliseconds(350);
    MediaTime paragraph_pause_threshold = milliseconds(1500);
    MediaTime section_pause_threshold = seconds(4);
    bool fricative_protection = true;

    /// Keeps more audio, cuts less. For quiet or noisy material.
    static SilenceParameters conservative() {
        SilenceParameters p;
        p.margin_db = 5;
        p.min_silence_duration = milliseconds(800);
        p.pad_lead = milliseconds(300);
        p.pad_trail = milliseconds(500);
        return p;
    }
};

struct SpeechRegion {
    TimeRange range;
    float mean_energy_db;
    float peak_energy_db;
};

struct SilenceGap {
    TimeRange range;
    float mean_energy_db;

    MediaTime duration() const { return range.duration(); }
};

/// Where speech is, where it is not, and how the detector got there.
struct SilenceMap {
    std::vector<SpeechRegion> speech_regions;  // ordered, disjoint, non-empty
    std::vector<SilenceGap> gaps;
    std::vector<float> noise_floor_profile;    // dBFS per analysis frame
    SilenceParameters parameters;
    std::string parameter_hash;                // the invalidation key
    MediaTime source_duration;

    MediaTime speech_duration() const;
    double speech_fraction() const;

    /// Silence-skipped timeline -> original timeline, clamped to the end of the
    /// last speech region.
    MediaTime original_time_for_processed(MediaTime processed) const;

    /// Original timeline -> silence-skipped timeline; nullopt inside a gap.
    std::optional<MediaTime> processed_time_for_original(MediaTime original) const;
};

}  // namespace voxscripta
