#pragma once

#include <filesystem>
#include <memory>

#include "voxscripta/transcription_engine.hpp"

namespace voxscripta {

/// Transcription through whisper.cpp, CPU only.
///
/// The model is loaded once in `prepare` and reused for every chunk. Calls are
/// serialized (a whisper context is not reentrant); whisper itself spreads each
/// call across `threads` cores.
class WhisperEngine final : public TranscriptionEngine {
public:
    struct Config {
        std::filesystem::path model_path;
        /// 0 = use the machine's hardware threads.
        int threads = 0;
    };

    explicit WhisperEngine(Config config);
    ~WhisperEngine() override;
    WhisperEngine(const WhisperEngine&) = delete;
    WhisperEngine& operator=(const WhisperEngine&) = delete;

    std::string identifier() const override { return "whisper.cpp"; }
    EngineCapabilities capabilities() const override;
    void prepare(const std::string& locale) override;
    std::vector<TranscriptSegment> transcribe(const SampleRange& range, const float* samples,
                                              const TranscriptionOptions& options) override;
    void release() override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace voxscripta
