// Whisper engine tests. They need the model (Tools/fetch-whisper.sh) and, for the
// real-speech cases, the SAPI fixture (Tools/make-speech-fixture.ps1). Anything
// missing is reported as skipped, never passed.

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <set>
#include <string>
#include <vector>

#include "harness.hpp"
#include "synthesis.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/whisper_engine.hpp"
#include "voxscripta/win/mf_decoder.hpp"

using namespace voxscripta;
namespace fs = std::filesystem;

namespace {

const fs::path root = VOXSCRIPTA_SOURCE_DIR;
const fs::path model_path = root / "models" / "ggml-small.bin";
const fs::path speech_wav = root / "Tests" / "Fixtures" / "generated" / "speech-zira.wav";

/// One engine for the whole run: loading the model takes seconds, and the
/// context is built to be reused.
WhisperEngine& engine() {
    static WhisperEngine instance({model_path, 0});
    static bool prepared = false;
    if (!prepared) {
        instance.prepare("en-US");
        prepared = true;
    }
    return instance;
}

bool skip_unless(bool available, const char* what) {
    if (!available) std::printf("    (skipped: %s)\n", what);
    return available;
}

std::vector<float> decode_to_samples(const fs::path& source) {
    const fs::path out = fs::temp_directory_path() / "voxscripta_whisper_test.f32";
    win::MediaFoundationDecoder{}.decode(source, out);
    std::ifstream f(out, std::ios::binary | std::ios::ate);
    std::vector<float> samples(static_cast<std::size_t>(f.tellg()) / 4);
    f.seekg(0);
    f.read(reinterpret_cast<char*>(samples.data()), static_cast<std::streamsize>(samples.size() * 4));
    f.close();
    fs::remove(out);
    return samples;
}

std::string normalized(const std::string& s) {
    std::string out;
    for (unsigned char c : s) {
        if (std::isalnum(c)) out += static_cast<char>(std::tolower(c));
        else if (!out.empty() && out.back() != ' ') out += ' ';
    }
    return out;
}

std::string join(const std::vector<TranscriptSegment>& segs) {
    std::string out;
    for (const auto& s : segs) out += (out.empty() ? "" : " ") + s.text;
    return out;
}

}  // namespace

VS_TEST("Whisper engine", "A missing model is reported as unavailable") {
    WhisperEngine missing({root / "models" / "does-not-exist.bin", 1});
    VS_EXPECT_THROWS(missing.prepare("en-US"), SourceUnavailable);
}

VS_TEST("Whisper engine", "An unknown language is refused") {
    if (!skip_unless(fs::exists(model_path), "model not fetched")) return;
    WhisperEngine fresh({model_path, 1});
    VS_EXPECT_THROWS(fresh.prepare("xx-XX"), std::invalid_argument);
}

VS_TEST("Whisper engine", "Capabilities describe a multilingual word-timestamp engine") {
    if (!skip_unless(fs::exists(model_path), "model not fetched")) return;
    const EngineCapabilities caps = engine().capabilities();
    VS_EXPECT(caps.supports_word_timestamps);
    VS_EXPECT(caps.supported_languages.count("en") == 1);
    VS_EXPECT(caps.supported_languages.count("es") == 1);
    VS_EXPECT(caps.supported_languages.size() > 90);
}

VS_TEST("Whisper engine", "Transcribes real synthesized speech") {
    if (!skip_unless(fs::exists(model_path) && fs::exists(speech_wav),
                     "model or speech fixture missing")) return;
    const std::vector<float> samples = decode_to_samples(speech_wav);
    const SampleRange range(0, static_cast<std::int64_t>(samples.size()));

    const auto began = std::chrono::steady_clock::now();
    const auto segments = engine().transcribe(range, samples.data(), TranscriptionOptions{});
    const double took = std::chrono::duration<double>(std::chrono::steady_clock::now() - began).count();
    const double audio = static_cast<double>(samples.size()) / 16'000.0;
    std::printf("    %.1f s of audio in %.1f s (%.2fx real time)\n    \"%s\"\n", audio, took, audio / took,
                join(segments).c_str());

    const std::string text = normalized(join(segments));
    VS_EXPECT_MSG(text.find("quick brown fox") != std::string::npos, "missing 'quick brown fox'");
    VS_EXPECT_MSG(text.find("lazy dog") != std::string::npos, "missing 'lazy dog'");
    VS_EXPECT_MSG(text.find("thursday") != std::string::npos, "missing 'Thursday'");
    VS_EXPECT_MSG(text.find("transcribe") != std::string::npos, "missing 'transcribe'");
}

VS_TEST("Whisper engine", "Segments and words are ordered and stay inside the audio") {
    if (!skip_unless(fs::exists(model_path) && fs::exists(speech_wav),
                     "model or speech fixture missing")) return;
    const std::vector<float> samples = decode_to_samples(speech_wav);
    const SampleRange range(0, static_cast<std::int64_t>(samples.size()));
    const auto segments = engine().transcribe(range, samples.data(), TranscriptionOptions{});
    const MediaTime end = MediaTime::from_samples(range.end_index(), 16'000) + milliseconds(500);

    VS_EXPECT(!segments.empty());
    MediaTime previous = MediaTime::zero();
    std::size_t words = 0;
    for (const auto& s : segments) {
        VS_EXPECT(s.original_start >= previous);
        VS_EXPECT(s.original_end >= s.original_start);
        VS_EXPECT(s.original_end <= end);
        previous = s.original_start;
        MediaTime word_cursor = s.original_start;
        for (const auto& w : s.words) {
            VS_EXPECT(w.original_start >= word_cursor);
            VS_EXPECT(w.original_end >= w.original_start);
            VS_EXPECT(w.original_end <= s.original_end);
            VS_EXPECT(!w.text.empty() && w.text.front() != ' ');
            word_cursor = w.original_start;
            ++words;
        }
    }
    VS_EXPECT_MSG(words >= 15, "expected word timestamps for the sentence, got " + std::to_string(words));
}

VS_TEST("Whisper engine", "Times are placed on the original timeline by the chunk offset") {
    if (!skip_unless(fs::exists(model_path) && fs::exists(speech_wav),
                     "model or speech fixture missing")) return;
    const std::vector<float> samples = decode_to_samples(speech_wav);
    const std::int64_t offset = 100 * 16'000;  // the chunk begins 100 s into the recording
    const SampleRange range(offset, static_cast<std::int64_t>(samples.size()));
    const auto segments = engine().transcribe(range, samples.data(), TranscriptionOptions{});

    VS_EXPECT(!segments.empty());
    for (const auto& s : segments) {
        VS_EXPECT(s.original_start >= seconds(100));
        VS_EXPECT(s.original_end <= seconds(100) + seconds(static_cast<double>(samples.size()) / 16'000.0) + milliseconds(500));
    }
}

VS_TEST("Whisper engine", "Transcription is deterministic") {
    if (!skip_unless(fs::exists(model_path) && fs::exists(speech_wav),
                     "model or speech fixture missing")) return;
    const std::vector<float> samples = decode_to_samples(speech_wav);
    const SampleRange range(0, static_cast<std::int64_t>(samples.size()));
    const auto a = engine().transcribe(range, samples.data(), TranscriptionOptions{});
    const auto b = engine().transcribe(range, samples.data(), TranscriptionOptions{});
    VS_EXPECT_EQ(a.size(), b.size());
    VS_EXPECT(join(a) == join(b));
}

VS_TEST("Whisper engine", "Room tone alone produces no invented text") {
    // The hallucination the architecture warns about: Whisper-family models will
    // happily "transcribe" noise. Here the silence detector would never send
    // this audio, but the engine itself should still decline to invent words.
    if (!skip_unless(fs::exists(model_path), "model not fetched")) return;
    const auto tone = testing::corpus::room_tone_only().render();
    const SampleRange range(0, static_cast<std::int64_t>(tone.size()));
    const auto segments = engine().transcribe(range, tone.data(), TranscriptionOptions{});
    VS_EXPECT_MSG(segments.empty(), "invented: \"" + join(segments) + "\"");
}
