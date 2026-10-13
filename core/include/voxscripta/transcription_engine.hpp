#pragma once

#include <set>
#include <string>
#include <vector>

#include "voxscripta/media_time.hpp"
#include "voxscripta/time_range.hpp"
#include "voxscripta/transcript_models.hpp"

namespace voxscripta {

/// What an engine can do. The scheduler consults this instead of special-casing
/// engine identities.
struct EngineCapabilities {
    bool supports_word_timestamps = false;
    bool supports_diarization = false;
    bool supports_translation = false;
    /// Language codes the engine can transcribe (e.g. "en", "es").
    std::set<std::string> supported_languages;
    /// Longest span the engine accepts in one call; zero for no limit.
    MediaTime maximum_chunk_duration = MediaTime::zero();
};

/// Per-run transcription settings.
struct TranscriptionOptions {
    /// BCP-47-ish tag such as "en-US", or empty to let the engine detect.
    std::string locale = "en-US";
    bool request_word_timestamps = true;
    /// Translate to English rather than transcribing in-language.
    bool translate = false;
    /// How many chunks may be in flight at once. A CPU engine already uses every
    /// core inside one call, so the default is 1; raising it only helps engines
    /// that spend their time waiting.
    int concurrency = 1;
    int max_attempts_per_chunk = 3;
};

/// A local speech-to-text engine.
///
/// Every implementation must be fully local: there is no code path in Vox Scripta
/// that sends audio off the machine.
class TranscriptionEngine {
public:
    virtual ~TranscriptionEngine() = default;

    virtual std::string identifier() const = 0;
    virtual EngineCapabilities capabilities() const = 0;

    /// Loads models. Idempotent. Throws on failure.
    virtual void prepare(const std::string& locale) = 0;

    /// Transcribes one span of canonical audio.
    ///
    /// `samples` holds exactly `range.count()` canonical samples, the audio that
    /// `range` covers in canonical.f32. Returned segment and word times are on
    /// the original timeline: local time plus `range`'s start.
    virtual std::vector<TranscriptSegment> transcribe(const SampleRange& range, const float* samples,
                                                      const TranscriptionOptions& options) = 0;

    /// Releases model memory.
    virtual void release() = 0;
};

}  // namespace voxscripta
