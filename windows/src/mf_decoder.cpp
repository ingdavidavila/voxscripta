#include "voxscripta/win/mf_decoder.hpp"

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "voxscripta/errors.hpp"

namespace voxscripta::win {

namespace {

namespace fs = std::filesystem;

// ── Small COM helpers (no ATL/WRL: they are not in every toolchain) ─────────

template <typename T>
class ComPtr {
public:
    ComPtr() = default;
    ComPtr(ComPtr&& other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;
    ~ComPtr() { reset(); }

    T* get() const { return ptr_; }
    T* operator->() const { return ptr_; }
    explicit operator bool() const { return ptr_ != nullptr; }
    T** put() {
        reset();
        return &ptr_;
    }
    void reset() {
        if (ptr_) {
            ptr_->Release();
            ptr_ = nullptr;
        }
    }

private:
    T* ptr_ = nullptr;
};

std::string hr_text(HRESULT hr) {
    char buffer[32];
    std::snprintf(buffer, sizeof buffer, "0x%08lX", static_cast<unsigned long>(hr));
    return buffer;
}

/// COM and Media Foundation for the lifetime of one call. Both are reference
/// counted by the OS, so nesting and concurrent decoders are fine.
class MediaFoundationSession {
public:
    MediaFoundationSession() {
        const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        // RPC_E_CHANGED_MODE: the thread is already an STA. COM is usable, and
        // we must not balance a CoInitialize that did not happen.
        com_initialized_ = SUCCEEDED(com);
        if (FAILED(com) && com != RPC_E_CHANGED_MODE) {
            throw DecodingFailed("COM initialization failed (" + hr_text(com) + ")");
        }
        const HRESULT mf = MFStartup(MF_VERSION, MFSTARTUP_LITE);
        if (FAILED(mf)) {
            if (com_initialized_) CoUninitialize();
            throw DecodingFailed("Media Foundation is not available (" + hr_text(mf) + ")");
        }
    }
    MediaFoundationSession(const MediaFoundationSession&) = delete;
    MediaFoundationSession& operator=(const MediaFoundationSession&) = delete;
    ~MediaFoundationSession() {
        MFShutdown();
        if (com_initialized_) CoUninitialize();
    }

private:
    bool com_initialized_ = false;
};

constexpr DWORD kAudio = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);

bool is_format_rejection(HRESULT hr) {
    return hr == MF_E_UNSUPPORTED_BYTESTREAM_TYPE || hr == MF_E_UNSUPPORTED_FORMAT ||
           hr == MF_E_INVALID_FORMAT || hr == MF_E_TOPO_CODEC_NOT_FOUND ||
           hr == MF_E_CANNOT_CREATE_SINK ||
           hr == MF_E_INVALIDMEDIATYPE;
}

/// Opens the file read-only and confirms it has an audio stream.
ComPtr<IMFSourceReader> open_reader(const fs::path& source) {
    std::error_code ec;
    if (!fs::exists(source, ec) || !fs::is_regular_file(source, ec)) {
        throw SourceUnavailable(source.string());
    }
    ComPtr<IMFSourceReader> reader;
    const HRESULT hr = MFCreateSourceReaderFromURL(source.c_str(), nullptr, reader.put());
    if (FAILED(hr)) {
        if (is_format_rejection(hr)) {
            throw UnsupportedFormat("Media Foundation has no demuxer for \"" +
                                    source.extension().string() + "\" (" + hr_text(hr) + ")");
        }
        throw DecodingFailed("could not open the file (" + hr_text(hr) + ")");
    }
    ComPtr<IMFMediaType> native;
    const HRESULT audio = reader->GetNativeMediaType(kAudio, 0, native.put());
    if (audio == MF_E_INVALIDSTREAMNUMBER) throw NoAudioTrack(source.string());
    if (FAILED(audio)) {
        throw UnsupportedFormat("the audio stream could not be read (" + hr_text(audio) + ")");
    }
    return reader;
}

std::string describe(double rate, int channels) {
    return std::to_string(static_cast<long long>(rate)) + " Hz " +
           (channels == 1 ? std::string("mono") : std::to_string(channels) + "ch");
}

UINT32 uint_attr(IMFAttributes* a, const GUID& key, UINT32 fallback = 0) {
    UINT32 v = fallback;
    if (FAILED(a->GetUINT32(key, &v))) return fallback;
    return v;
}

/// Asks the reader for 32-bit float at the canonical rate with `channels`
/// channels. Fails with the HRESULT so the caller can fall back.
HRESULT request_output(IMFSourceReader* reader, UINT32 channels) {
    ComPtr<IMFMediaType> type;
    HRESULT hr = MFCreateMediaType(type.put());
    if (FAILED(hr)) return hr;
    const UINT32 rate = static_cast<UINT32>(CanonicalFormat::sample_rate);
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
    type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
    type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
    type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
    type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * 4);
    type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, channels * 4 * rate);
    type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    return reader->SetCurrentMediaType(kAudio, nullptr, type.get());
}

}  // namespace

// ── probe / duration ────────────────────────────────────────────────────────

AudioFormatDescription MediaFoundationDecoder::probe(const fs::path& source) const {
    MediaFoundationSession session;
    ComPtr<IMFSourceReader> reader = open_reader(source);

    ComPtr<IMFMediaType> native;
    reader->GetNativeMediaType(kAudio, 0, native.put());

    AudioFormatDescription out;
    out.sample_rate = uint_attr(native.get(), MF_MT_AUDIO_SAMPLES_PER_SECOND);
    out.channel_count = static_cast<int>(uint_attr(native.get(), MF_MT_AUDIO_NUM_CHANNELS));
    const UINT32 bits = uint_attr(native.get(), MF_MT_AUDIO_BITS_PER_SAMPLE);
    if (bits > 0) out.bit_depth = static_cast<int>(bits);
    out.format_description = describe(out.sample_rate, out.channel_count);
    if (out.sample_rate <= 0 || out.channel_count <= 0) {
        throw UnsupportedFormat("the audio stream reports no sample rate or channels");
    }
    return out;
}

std::optional<MediaTime> MediaFoundationDecoder::duration(const fs::path& source) const {
    MediaFoundationSession session;
    ComPtr<IMFSourceReader> reader = open_reader(source);

    PROPVARIANT value;
    PropVariantInit(&value);
    const HRESULT hr = reader->GetPresentationAttribute(
        static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &value);
    std::optional<MediaTime> result;
    if (SUCCEEDED(hr) && value.vt == VT_UI8 && value.uhVal.QuadPart > 0) {
        // Media Foundation counts in 100 ns units.
        result = MediaTime(static_cast<std::int64_t>(value.uhVal.QuadPart) * 100);
    }
    PropVariantClear(&value);
    return result;
}

// ── decode ──────────────────────────────────────────────────────────────────

std::int64_t MediaFoundationDecoder::decode(const fs::path& source, const fs::path& destination,
                                            const DecodeProgressFn& progress) const {
    MediaFoundationSession session;
    ComPtr<IMFSourceReader> reader = open_reader(source);

    // Only the first audio stream is read; video is never decoded.
    reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
    reader->SetStreamSelection(kAudio, TRUE);

    // Preferred: have Media Foundation resample and mix to canonical mono. If
    // the platform refuses that combination, take canonical-rate float at the
    // source's channel count and mix here.
    UINT32 channels = 1;
    HRESULT hr = request_output(reader.get(), 1);
    if (FAILED(hr)) {
        ComPtr<IMFMediaType> native;
        reader->GetNativeMediaType(kAudio, 0, native.put());
        channels = std::max<UINT32>(1, uint_attr(native.get(), MF_MT_AUDIO_NUM_CHANNELS, 2));
        hr = request_output(reader.get(), channels);
        if (FAILED(hr)) {
            throw UnsupportedFormat("no conversion path to canonical PCM (" + hr_text(hr) + ")");
        }
    }

    const auto total = duration(source);  // 100 ns precision; may be unknown
    const double total_hns = total ? static_cast<double>(total->nanoseconds()) / 100.0 : 0.0;

    std::error_code ec;
    if (destination.has_parent_path()) fs::create_directories(destination.parent_path(), ec);
    std::ofstream out(destination, std::ios::binary | std::ios::trunc);
    if (!out) throw IoFailure(destination.string(), "could not create the file");

    std::int64_t written = 0;
    double last_reported = -1;
    std::vector<float> mixed;

    auto fail_cleanup = [&] {
        out.close();
        std::error_code ignore;
        fs::remove(destination, ignore);
    };

    try {
        for (;;) {
            DWORD flags = 0;
            LONGLONG timestamp = 0;
            ComPtr<IMFSample> sample;
            hr = reader->ReadSample(kAudio, 0, nullptr, &flags, &timestamp, sample.put());
            if (FAILED(hr)) throw DecodingFailed("reading failed (" + hr_text(hr) + ")");
            if (flags & MF_SOURCE_READERF_ERROR) throw DecodingFailed("the source reported an error");
            if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
                // A mid-stream format change would silently corrupt the timeline.
                ComPtr<IMFMediaType> now;
                reader->GetCurrentMediaType(kAudio, now.put());
                if (uint_attr(now.get(), MF_MT_AUDIO_SAMPLES_PER_SECOND) !=
                        static_cast<UINT32>(CanonicalFormat::sample_rate) ||
                    uint_attr(now.get(), MF_MT_AUDIO_NUM_CHANNELS) != channels) {
                    throw DecodingFailed("the audio format changed mid-stream");
                }
            }

            if (sample) {
                ComPtr<IMFMediaBuffer> buffer;
                hr = sample->ConvertToContiguousBuffer(buffer.put());
                if (FAILED(hr)) throw DecodingFailed("could not read a sample (" + hr_text(hr) + ")");

                BYTE* bytes = nullptr;
                DWORD length = 0;
                hr = buffer->Lock(&bytes, nullptr, &length);
                if (FAILED(hr)) throw DecodingFailed("could not lock a buffer (" + hr_text(hr) + ")");

                const std::size_t frames = length / (4 * channels);
                if (channels == 1) {
                    out.write(reinterpret_cast<const char*>(bytes),
                              static_cast<std::streamsize>(frames * 4));
                } else {
                    // Average the channels: a speaker on one side only is kept,
                    // and the sum can never clip.
                    mixed.resize(frames);
                    const float* in = reinterpret_cast<const float*>(bytes);
                    for (std::size_t f = 0; f < frames; ++f) {
                        float sum = 0;
                        for (UINT32 c = 0; c < channels; ++c) sum += in[f * channels + c];
                        mixed[f] = sum / static_cast<float>(channels);
                    }
                    out.write(reinterpret_cast<const char*>(mixed.data()),
                              static_cast<std::streamsize>(frames * 4));
                }
                buffer->Unlock();
                if (!out) throw IoFailure(destination.string(), "write failed");
                written += static_cast<std::int64_t>(frames);

                if (progress && total_hns > 0) {
                    const double fraction = std::min(static_cast<double>(timestamp) / total_hns, 1.0);
                    if (fraction - last_reported >= 0.01) {
                        last_reported = fraction;
                        if (!progress(fraction)) throw DecodeCancelled();
                    }
                }
            }
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        }
        if (written == 0) throw DecodingFailed("decoding produced no samples");
        out.flush();
        if (!out) throw IoFailure(destination.string(), "flush failed");
        out.close();
    } catch (...) {
        fail_cleanup();
        throw;
    }
    if (progress) progress(1.0);
    return written;
}

}  // namespace voxscripta::win
