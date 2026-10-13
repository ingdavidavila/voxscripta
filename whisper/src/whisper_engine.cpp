#include "voxscripta/whisper_engine.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <mutex>
#include <stdexcept>
#include <thread>

#include "voxscripta/audio_format.hpp"
#include "voxscripta/errors.hpp"
#include "whisper.h"

namespace voxscripta {

namespace {

/// "en-US" -> "en"; empty -> "auto" (let Whisper detect).
std::string language_code(const std::string& locale) {
    if (locale.empty()) return "auto";
    std::string code = locale.substr(0, locale.find_first_of("-_"));
    std::transform(code.begin(), code.end(), code.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return code;
}

/// Whisper timestamps are in units of 10 ms.
MediaTime centiseconds(std::int64_t cs) { return MediaTime(cs * 10'000'000LL); }

std::string trim_leading_space(std::string s) {
    s.erase(0, s.find_first_not_of(' '));
    return s;
}

/// Whisper labels non-speech audio with bracketed annotations: "[BLANK_AUDIO]",
/// "[Music]", "(birds chirping)", "*sigh*". Those describe sound, not words, and
/// on noise they are the model's version of a hallucination. A segment that is
/// nothing but such a label is dropped; speech inside brackets alongside other
/// text is untouched.
bool is_sound_annotation(const std::string& text) {
    if (text.size() < 2) return false;
    const char open = text.front();
    const char close = text.back();
    const bool bracketed = (open == '[' && close == ']') || (open == '(' && close == ')') ||
                           (open == '*' && close == '*');
    if (!bracketed) return false;
    // Reject if another opener appears inside: "[a] and [b]" is not one label.
    return text.find_first_of("[](){}", 1) == text.size() - 1 || open == '*';
}

}  // namespace

struct WhisperEngine::Impl {
    Config config;
    whisper_context* context = nullptr;
    std::mutex mutex;  // a whisper context is not reentrant

    ~Impl() { free_context(); }
    void free_context() {
        if (context) {
            whisper_free(context);
            context = nullptr;
        }
    }
};

WhisperEngine::WhisperEngine(Config config) : impl_(std::make_unique<Impl>()) {
    impl_->config = std::move(config);
}

WhisperEngine::~WhisperEngine() = default;

EngineCapabilities WhisperEngine::capabilities() const {
    EngineCapabilities caps;
    caps.supports_word_timestamps = true;
    caps.supports_translation = true;
    // Every language the loaded build knows, rather than a hardcoded list.
    for (int id = 0; id <= whisper_lang_max_id(); ++id) {
        if (const char* code = whisper_lang_str(id)) caps.supported_languages.insert(code);
    }
    // Whisper windows its input at 30 s internally, so any length is accepted.
    caps.maximum_chunk_duration = MediaTime::zero();
    return caps;
}

void WhisperEngine::prepare(const std::string& locale) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const std::string lang = language_code(locale);
    if (lang != "auto" && whisper_lang_id(lang.c_str()) < 0) {
        throw std::invalid_argument("Whisper does not support the language \"" + lang + "\"");
    }
    if (impl_->context) return;

    std::error_code ec;
    if (!std::filesystem::is_regular_file(impl_->config.model_path, ec)) {
        throw SourceUnavailable(impl_->config.model_path.string());
    }
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    impl_->context = whisper_init_from_file_with_params(impl_->config.model_path.string().c_str(), cparams);
    if (!impl_->context) {
        throw DecodingFailed("Whisper could not load the model at " + impl_->config.model_path.string());
    }
}

std::vector<TranscriptSegment> WhisperEngine::transcribe(const SampleRange& range, const float* samples,
                                                         const TranscriptionOptions& options) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->context) throw std::logic_error("WhisperEngine::transcribe called before prepare");
    if (range.count() == 0) return {};
    if (range.count() > INT32_MAX) throw std::invalid_argument("chunk is too long for one Whisper call");

    const std::string lang = language_code(options.locale);
    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = impl_->config.threads > 0
                           ? impl_->config.threads
                           : static_cast<int>(std::max(1u, std::min(8u, std::thread::hardware_concurrency())));
    params.language = lang.c_str();
    params.translate = options.translate;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.token_timestamps = options.request_word_timestamps;
    // Each chunk is transcribed independently: carrying text across chunks would
    // let one chunk's mistakes steer the next, and make results depend on
    // scheduling order.
    params.no_context = true;
    params.suppress_blank = true;

    if (whisper_full(impl_->context, params, samples, static_cast<int>(range.count())) != 0) {
        throw DecodingFailed("Whisper failed on the chunk starting at sample " +
                             std::to_string(range.start_index()));
    }

    const MediaTime origin = MediaTime::from_samples(range.start_index(), CanonicalFormat::sample_rate);
    const whisper_token eot = whisper_token_eot(impl_->context);
    std::vector<TranscriptSegment> out;

    const int segment_count = whisper_full_n_segments(impl_->context);
    for (int s = 0; s < segment_count; ++s) {
        TranscriptSegment seg;
        seg.original_start = origin + centiseconds(whisper_full_get_segment_t0(impl_->context, s));
        seg.original_end = origin + centiseconds(whisper_full_get_segment_t1(impl_->context, s));
        if (seg.original_end < seg.original_start) seg.original_end = seg.original_start;
        seg.text = trim_leading_space(whisper_full_get_segment_text(impl_->context, s));
        if (seg.text.empty() || is_sound_annotation(seg.text)) continue;

        // Words: a token that begins with a space starts a new word; the rest
        // continue it. Special tokens (timestamps, end-of-text) are skipped.
        double p_sum = 0;
        int p_count = 0;
        const int token_count = whisper_full_n_tokens(impl_->context, s);
        for (int t = 0; t < token_count; ++t) {
            const whisper_token_data data = whisper_full_get_token_data(impl_->context, s, t);
            if (data.id >= eot) continue;
            const std::string piece = whisper_full_get_token_text(impl_->context, s, t);
            if (piece.find_first_not_of(" \t\n") == std::string::npos) continue;
            p_sum += static_cast<double>(data.p);
            ++p_count;
            if (!options.request_word_timestamps) continue;

            MediaTime start = data.t0 >= 0 ? origin + centiseconds(data.t0) : seg.original_start;
            MediaTime end = data.t1 >= 0 ? origin + centiseconds(data.t1) : seg.original_end;
            start = start.clamped(seg.original_start, seg.original_end);
            end = end.clamped(start, seg.original_end);

            if (piece.front() == ' ' || seg.words.empty()) {
                seg.words.push_back({trim_leading_space(piece), start, end, data.p});
            } else {
                Word& w = seg.words.back();
                w.text += piece;
                w.original_end = end;
                // A word is as sure as its least sure piece.
                w.confidence = std::min(w.confidence.value_or(1.0f), data.p);
            }
        }
        if (p_count > 0) seg.confidence = static_cast<float>(p_sum / p_count);
        out.push_back(std::move(seg));
    }
    return out;
}

void WhisperEngine::release() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->free_context();
}

}  // namespace voxscripta
