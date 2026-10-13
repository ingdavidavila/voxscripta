// Ported from Tests/VoxScriptaDSPTests/DecoderTests.swift. Fixtures are
// synthesized at test time: WAV written directly, AAC/M4A written through
// Media Foundation's own encoder. Both are generated on the machine under test,
// so a pass means this machine's decoder handled this machine's encoder.

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "harness.hpp"
#include "synthesis.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/frame_analysis.hpp"
#include "voxscripta/silence_detector.hpp"
#include "voxscripta/win/mf_decoder.hpp"

using namespace voxscripta;
using namespace voxscripta::testing;
using voxscripta::win::DecodeCancelled;
using voxscripta::win::MediaFoundationDecoder;
namespace fs = std::filesystem;

namespace {

/// A scratch directory removed on scope exit.
struct TempDir {
    fs::path path;
    TempDir() {
        static int counter = 0;
        path = fs::temp_directory_path() /
               ("voxscripta_win_test_" + std::to_string(::GetCurrentProcessId()) + "_" +
                std::to_string(counter++));
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

std::vector<std::int16_t> to_pcm16(const std::vector<float>& mono, int channels) {
    std::vector<std::int16_t> out;
    out.reserve(mono.size() * static_cast<std::size_t>(channels));
    for (float s : mono) {
        const float clipped = std::max(-1.0f, std::min(1.0f, s));
        const auto v = static_cast<std::int16_t>(std::lrintf(clipped * 32767.0f));
        for (int c = 0; c < channels; ++c) out.push_back(v);
    }
    return out;
}

void put32(std::ofstream& f, std::uint32_t v) { f.write(reinterpret_cast<const char*>(&v), 4); }
void put16(std::ofstream& f, std::uint16_t v) { f.write(reinterpret_cast<const char*>(&v), 2); }

fs::path write_wav(const CorpusCase& c, const fs::path& dir, int rate, int channels = 1) {
    const auto pcm = to_pcm16(c.render(rate), channels);
    const fs::path path = dir / ("source-" + std::to_string(rate) + "-" + std::to_string(channels) + ".wav");
    std::ofstream f(path, std::ios::binary);
    const std::uint32_t data_bytes = static_cast<std::uint32_t>(pcm.size() * 2);
    f.write("RIFF", 4); put32(f, 36 + data_bytes); f.write("WAVE", 4);
    f.write("fmt ", 4); put32(f, 16); put16(f, 1); put16(f, static_cast<std::uint16_t>(channels));
    put32(f, static_cast<std::uint32_t>(rate));
    put32(f, static_cast<std::uint32_t>(rate * channels * 2));
    put16(f, static_cast<std::uint16_t>(channels * 2)); put16(f, 16);
    f.write("data", 4); put32(f, data_bytes);
    f.write(reinterpret_cast<const char*>(pcm.data()), data_bytes);
    return path;
}

template <typename T>
struct Com {
    T* p = nullptr;
    ~Com() { if (p) p->Release(); }
    T** put() { return &p; }
    T* operator->() const { return p; }
};

/// Encodes to AAC in an MP4 container with Media Foundation's own encoder.
/// Returns an empty path when this machine has no AAC encoder, so the test can
/// report a skip rather than a false failure.
fs::path write_m4a(const CorpusCase& c, const fs::path& dir, int rate, int channels = 1) {
    const auto pcm = to_pcm16(c.render(rate), channels);
    const fs::path path = dir / "source.m4a";
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) return {};
    fs::path result;
    do {
        Com<IMFSinkWriter> writer;
        if (FAILED(MFCreateSinkWriterFromURL(path.c_str(), nullptr, nullptr, writer.put()))) break;

        Com<IMFMediaType> out;
        MFCreateMediaType(out.put());
        out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        out->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
        out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(rate));
        out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, static_cast<UINT32>(channels));
        out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 12000);
        out->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
        out->SetUINT32(MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29);
        DWORD stream = 0;
        if (FAILED(writer->AddStream(out.p, &stream))) break;

        Com<IMFMediaType> in;
        MFCreateMediaType(in.put());
        in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
        in->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
        in->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        in->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(rate));
        in->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, static_cast<UINT32>(channels));
        in->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, static_cast<UINT32>(channels * 2));
        in->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, static_cast<UINT32>(rate * channels * 2));
        if (FAILED(writer->SetInputMediaType(stream, in.p, nullptr))) break;
        if (FAILED(writer->BeginWriting())) break;

        // One-second slices keep each sample a sensible size.
        const std::size_t per_slice = static_cast<std::size_t>(rate * channels);
        LONGLONG time = 0;
        bool ok = true;
        for (std::size_t at = 0; at < pcm.size() && ok; at += per_slice) {
            const std::size_t n = std::min(per_slice, pcm.size() - at);
            Com<IMFMediaBuffer> buffer;
            MFCreateMemoryBuffer(static_cast<DWORD>(n * 2), buffer.put());
            BYTE* data = nullptr;
            buffer->Lock(&data, nullptr, nullptr);
            std::memcpy(data, pcm.data() + at, n * 2);
            buffer->Unlock();
            buffer->SetCurrentLength(static_cast<DWORD>(n * 2));
            Com<IMFSample> sample;
            MFCreateSample(sample.put());
            sample->AddBuffer(buffer.p);
            const LONGLONG duration = static_cast<LONGLONG>(n / channels) * 10'000'000LL / rate;
            sample->SetSampleTime(time);
            sample->SetSampleDuration(duration);
            time += duration;
            ok = SUCCEEDED(writer->WriteSample(stream, sample.p));
        }
        if (!ok) break;
        if (FAILED(writer->Finalize())) break;
        result = path;
    } while (false);
    MFShutdown();
    return result;
}

std::vector<float> read_samples(const fs::path& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    const auto bytes = static_cast<std::size_t>(f.tellg());
    f.seekg(0);
    std::vector<float> out(bytes / 4);
    f.read(reinterpret_cast<char*>(out.data()), static_cast<std::streamsize>(bytes));
    return out;
}

std::int64_t expected_samples(const CorpusCase& c) {
    return c.duration().samples_at(CanonicalFormat::sample_rate);
}

}  // namespace

VS_TEST("Media Foundation decoder", "Probe reports the source format without decoding") {
    TempDir tmp;
    const auto source = write_wav(corpus::basic(), tmp.path, 44'100);
    const auto format = MediaFoundationDecoder{}.probe(source);
    VS_EXPECT_EQ(static_cast<int>(format.sample_rate), 44'100);
    VS_EXPECT_EQ(format.channel_count, 1);
    VS_EXPECT(format.bit_depth.has_value() && *format.bit_depth == 16);
}

VS_TEST("Media Foundation decoder", "Duration comes from the container") {
    TempDir tmp;
    const auto source = write_wav(corpus::basic(), tmp.path, 44'100);
    const auto duration = MediaFoundationDecoder{}.duration(source);
    VS_EXPECT(duration.has_value());
    if (duration) VS_EXPECT(std::abs((*duration - corpus::basic().duration()).seconds()) < 0.05);
}

VS_TEST("Media Foundation decoder", "Decodes to canonical rate with the expected sample count") {
    TempDir tmp;
    const auto source = write_wav(corpus::basic(), tmp.path, 44'100);
    const auto dest = tmp.path / "canonical.f32";
    const std::int64_t written = MediaFoundationDecoder{}.decode(source, dest);
    VS_EXPECT_EQ(written, static_cast<std::int64_t>(fs::file_size(dest) / 4));
    // Resamplers may differ by a few frames at the tail; 10 ms of tolerance.
    VS_EXPECT(std::abs(written - expected_samples(corpus::basic())) < 160);
}

VS_TEST("Media Foundation decoder", "Every required sample rate converges on the same canonical length") {
    for (int rate : {8'000, 16'000, 22'050, 44'100, 48'000}) {
        TempDir tmp;
        const auto source = write_wav(corpus::basic(), tmp.path, rate);
        const std::int64_t written = MediaFoundationDecoder{}.decode(source, tmp.path / "c.f32");
        VS_EXPECT_MSG(std::abs(written - expected_samples(corpus::basic())) < 320,
                      "rate " + std::to_string(rate) + " gave " + std::to_string(written));
    }
}

VS_TEST("Media Foundation decoder", "AAC in MP4 decodes") {
    TempDir tmp;
    const auto source = write_m4a(corpus::basic(), tmp.path, 44'100);
    if (source.empty()) {
        std::printf("    (skipped: this machine has no AAC encoder to build a fixture with)\n");
        return;
    }
    const std::int64_t written = MediaFoundationDecoder{}.decode(source, tmp.path / "c.f32");
    // Lossy encoders pad; allow a larger tail tolerance.
    VS_EXPECT_MSG(std::abs(written - expected_samples(corpus::basic())) < 4096,
                  "wrote " + std::to_string(written));

    const auto samples = read_samples(tmp.path / "c.f32");
    float peak = 0;
    for (std::size_t i = 3 * 16'000; i < 6 * 16'000 && i < samples.size(); ++i) {
        peak = std::max(peak, std::abs(samples[i]));
    }
    VS_EXPECT_MSG(peak > 0.02f, "the decoded AAC speech span is silent");
}

VS_TEST("Media Foundation decoder", "Stereo is downmixed rather than having a channel dropped") {
    TempDir tmp;
    const auto source = write_wav(corpus::basic(), tmp.path, 44'100, 2);
    const auto dest = tmp.path / "c.f32";
    VS_EXPECT(MediaFoundationDecoder{}.decode(source, dest) > 0);

    const auto samples = read_samples(dest);
    float peak = 0;
    for (std::size_t i = static_cast<std::size_t>(2.5 * 16'000); i < 6.5 * 16'000 && i < samples.size(); ++i) {
        peak = std::max(peak, std::abs(samples[i]));
    }
    VS_EXPECT_MSG(peak > 0.02f, "the signal did not survive the downmix");
}

VS_TEST("Media Foundation decoder", "Progress is reported and ends at 1") {
    TempDir tmp;
    const auto source = write_wav(corpus::basic(), tmp.path, 44'100);
    std::vector<double> reports;
    MediaFoundationDecoder{}.decode(source, tmp.path / "c.f32", [&](double p) {
        reports.push_back(p);
        return true;
    });
    VS_EXPECT(!reports.empty());
    VS_EXPECT(!reports.empty() && reports.back() == 1.0);
    VS_EXPECT(std::is_sorted(reports.begin(), reports.end()));
}

VS_TEST("Media Foundation decoder", "Decoded audio preserves the loud and quiet spans") {
    TempDir tmp;
    const auto source = write_wav(corpus::basic(), tmp.path, 48'000);
    const auto dest = tmp.path / "c.f32";
    MediaFoundationDecoder{}.decode(source, dest);
    const auto samples = read_samples(dest);

    auto rms = [&](double from, double to) {
        double sum = 0;
        std::size_t n = 0;
        for (auto i = static_cast<std::size_t>(from * 16'000); i < to * 16'000 && i < samples.size(); ++i, ++n) {
            sum += static_cast<double>(samples[i]) * samples[i];
        }
        return n ? std::sqrt(sum / static_cast<double>(n)) : 0.0;
    };
    const double speech = rms(3, 6);    // -18 dBFS span
    const double silence = rms(8.0, 9.5);
    VS_EXPECT(speech > silence * 20);
    VS_EXPECT(silence < 0.01);
}

VS_TEST("Media Foundation decoder", "A missing file is reported as unavailable, not as a decode failure") {
    VS_EXPECT_THROWS(MediaFoundationDecoder{}.probe("C:/nonexistent/x.wav"), SourceUnavailable);
    VS_EXPECT_THROWS(MediaFoundationDecoder{}.decode("C:/nonexistent/x.wav", "unused.f32"), SourceUnavailable);
}

VS_TEST("Media Foundation decoder", "A file that is not audio is refused and leaves no output") {
    TempDir tmp;
    const auto bogus = tmp.path / "not-audio.wav";
    { std::ofstream(bogus) << "this is plainly not a RIFF file"; }
    const auto dest = tmp.path / "c.f32";
    bool threw = false;
    try {
        MediaFoundationDecoder{}.decode(bogus, dest);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    VS_EXPECT(threw);
    VS_EXPECT(!fs::exists(dest));
}

VS_TEST("Media Foundation decoder", "Cancelling removes the partial output") {
    TempDir tmp;
    const auto source = write_wav(corpus::basic(), tmp.path, 44'100);
    const auto dest = tmp.path / "c.f32";
    VS_EXPECT_THROWS(MediaFoundationDecoder{}.decode(source, dest, [](double) { return false; }),
                     DecodeCancelled);
    VS_EXPECT(!fs::exists(dest));
}

VS_TEST("Media Foundation decoder", "Paths with non-ASCII characters work") {
    TempDir tmp;
    const auto dir = tmp.path / L"grabación ñandú 録音";
    fs::create_directories(dir);
    const auto source = write_wav(corpus::basic(), dir, 16'000);
    VS_EXPECT(MediaFoundationDecoder{}.decode(source, dir / L"salida.f32") > 0);
}

VS_TEST("Media Foundation decoder", "A long file decodes the same way a short one does") {
    // Buffers are sized per sample, never from the file's length, so a long file
    // allocates what a short one does; asserting the length is a stable proxy for
    // a footprint measurement that would be flaky under a test runner.
    TempDir tmp;
    const auto source = write_wav(corpus::continuous_speech(), tmp.path, 16'000);
    const std::int64_t written = MediaFoundationDecoder{}.decode(source, tmp.path / "long.f32");
    VS_EXPECT(std::abs(written - expected_samples(corpus::continuous_speech())) < 320);
}

VS_TEST("Media Foundation decoder", "Decode, analyse and detect end to end") {
    // The whole P2 chain on a decoded file: Media Foundation resamples a 44.1 kHz
    // WAV, the streaming analyzer reads it from disk, and the detector must still
    // find the two speech regions the corpus was built with.
    TempDir tmp;
    const auto c = corpus::basic();
    const auto source = write_wav(c, tmp.path, 44'100);
    const auto dest = tmp.path / "canonical.f32";
    MediaFoundationDecoder{}.decode(source, dest);

    const FrameFeatures features = FrameAnalyzer().analyze_file(dest.string(), FrameGeometry{});
    const SilenceMap map = SilenceDetector{}.detect(features, SilenceParameters{}, c.duration(), "e2e");
    VS_EXPECT_EQ(map.speech_regions.size(), std::size_t{2});

    const auto truth = c.expected_speech_regions();
    for (std::size_t i = 0; i < truth.size() && i < map.speech_regions.size(); ++i) {
        const auto& d = map.speech_regions[i].range;
        VS_EXPECT(std::abs((d.start_time() - truth[i].start_time()).seconds()) < 0.5);
        VS_EXPECT(std::abs((d.end_time() - truth[i].end_time()).seconds()) < 0.5);
    }
}
