#include "voxscripta/frame_analysis.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstring>
#include <fstream>

#include "voxscripta/errors.hpp"

namespace voxscripta {

// ── FrameGeometry ───────────────────────────────────────────────────────────

int FrameGeometry::frame_count_for_samples(std::int64_t n) const {
    const std::int64_t window = window_samples();
    const std::int64_t hop = hop_samples();
    return n < window ? 0 : static_cast<int>((n - window) / hop) + 1;
}

MediaTime FrameGeometry::time_of_frame(int index) const {
    return MediaTime::from_samples(static_cast<std::int64_t>(index) * hop_samples(), sample_rate);
}

int FrameGeometry::frame_at_time(MediaTime time) const {
    const std::int64_t frame = time.samples_at(sample_rate) / hop_samples();
    return static_cast<int>(std::max<std::int64_t>(0, frame));
}

// ── FrameFeatures ───────────────────────────────────────────────────────────

FrameFeatures::FrameFeatures(std::vector<float> rms, std::vector<float> zcr,
                             std::vector<float> flatness, FrameGeometry g)
    : rms_db(std::move(rms)),
      zero_crossing_rate(std::move(zcr)),
      spectral_flatness(std::move(flatness)),
      geometry(g) {
    if (rms_db.size() != zero_crossing_rate.size() || rms_db.size() != spectral_flatness.size()) {
        throw std::invalid_argument(
            "FrameFeatures requires all feature arrays to be the same length");
    }
}

// ── Feature computation ─────────────────────────────────────────────────────

namespace {

constexpr double kPi = 3.14159265358979323846;

/// In-place iterative radix-2 FFT. Computed in double: the transform is a small
/// fraction of the cost and double keeps the result independent of how a
/// compiler contracts float expressions.
void fft_in_place(std::vector<std::complex<double>>& a) {
    const std::size_t n = a.size();
    for (std::size_t i = 1, j = 0; i < n; ++i) {
        std::size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (std::size_t len = 2; len <= n; len <<= 1) {
        const double angle = -2.0 * kPi / static_cast<double>(len);
        const std::complex<double> wlen(std::cos(angle), std::sin(angle));
        for (std::size_t i = 0; i < n; i += len) {
            std::complex<double> w(1.0, 0.0);
            for (std::size_t k = 0; k < len / 2; ++k) {
                const auto u = a[i + k];
                const auto v = a[i + k + len / 2] * w;
                a[i + k] = u + v;
                a[i + k + len / 2] = u - v;
                w *= wlen;
            }
        }
    }
}

/// Everything one frame needs, with its scratch buffers allocated once.
struct FrameWorker {
    const FrameGeometry& geometry;
    int fft_size;
    std::vector<double> window;
    std::vector<std::complex<double>> spectrum;
    std::vector<double> power;

    FrameWorker(const FrameGeometry& g, int fft)
        : geometry(g), fft_size(fft), window(g.window_samples()), spectrum(fft), power(fft / 2) {
        // Denormalized Hann, w[n] = 0.5 (1 - cos(2 pi n / N)). This is the shape
        // vDSP_hann_window produces with vDSP_HANN_DENORM. Flatness is a ratio,
        // so a small difference in window convention moves it by well under the
        // margin the detector's thresholds leave.
        const double n = static_cast<double>(window.size());
        for (std::size_t i = 0; i < window.size(); ++i) {
            window[i] = 0.5 * (1.0 - std::cos(2.0 * kPi * static_cast<double>(i) / n));
        }
    }

    void process(const float* frame, float& rms, float& zcr, float& flatness) {
        const int wn = geometry.window_samples();
        rms = FrameAnalyzer::dbfs(FrameAnalyzer::root_mean_square(frame, wn));
        zcr = FrameAnalyzer::zero_crossing_rate(frame, wn);

        const int copy = std::min(wn, fft_size);
        for (int i = 0; i < fft_size; ++i) {
            const double v = i < copy ? static_cast<double>(frame[i]) * window[i] : 0.0;
            spectrum[i] = std::complex<double>(v, 0.0);
        }
        fft_in_place(spectrum);

        // vDSP's real FFT returns twice the true DFT and packs Nyquist into the
        // imaginary part of bin 0, so bin 0 carries DC^2 + Nyquist^2. Reproduce
        // both so flatness sees the same spectrum the Swift implementation does.
        const double dc = spectrum[0].real();
        const double nyquist = spectrum[fft_size / 2].real();
        power[0] = 4.0 * (dc * dc + nyquist * nyquist);
        for (int k = 1; k < fft_size / 2; ++k) power[k] = 4.0 * std::norm(spectrum[k]);
        flatness = FrameAnalyzer::spectral_flatness(power);
    }
};

}  // namespace

FrameAnalyzer::FrameAnalyzer(int fft_size) : fft_size_(fft_size) {
    if (fft_size < 2 || (fft_size & (fft_size - 1)) != 0) {
        throw std::invalid_argument("fftSize must be a power of two");
    }
}

float FrameAnalyzer::root_mean_square(const float* s, int n) {
    double sum = 0;
    for (int i = 0; i < n; ++i) sum += static_cast<double>(s[i]) * s[i];
    return static_cast<float>(std::sqrt(sum / n));
}

float FrameAnalyzer::dbfs(float amplitude) {
    return amplitude <= 0 ? minimum_db : std::max(20.0f * std::log10(amplitude), minimum_db);
}

float FrameAnalyzer::zero_crossing_rate(const float* s, int n) {
    if (n <= 1) return 0;
    int crossings = 0;
    float previous = s[0];
    for (int i = 1; i < n; ++i) {
        const float current = s[i];
        if ((current >= 0) != (previous >= 0)) ++crossings;
        previous = current;
    }
    return static_cast<float>(crossings) / static_cast<float>(n - 1);
}

float FrameAnalyzer::spectral_flatness(const std::vector<double>& power) {
    if (power.empty()) return 0;
    const double epsilon = 1e-12;
    double log_sum = 0, linear_sum = 0;
    for (double value : power) {
        const double v = value + epsilon;
        log_sum += std::log(v);
        linear_sum += v;
    }
    const double count = static_cast<double>(power.size());
    const double geometric = std::exp(log_sum / count);
    const double arithmetic = linear_sum / count;
    if (!(arithmetic > 0)) return 0;
    return static_cast<float>(std::min(geometric / arithmetic, 1.0));
}

FrameFeatures FrameAnalyzer::analyze(const float* samples, std::int64_t count,
                                     const FrameGeometry& geometry,
                                     const ProgressFn& progress) const {
    const int frames = geometry.frame_count_for_samples(count);
    if (frames <= 0) {
        throw AnalysisFailed("frame analysis",
                             "the recording is shorter than one " +
                                 std::to_string(geometry.window_samples()) + "-sample window");
    }
    std::vector<float> rms(frames), zcr(frames), flat(frames);
    FrameWorker worker(geometry, fft_size_);
    const std::int64_t hop = geometry.hop_samples();

    for (int f = 0; f < frames; ++f) {
        if (progress && f % 4096 == 0 && !progress(static_cast<double>(f) / frames)) {
            throw AnalysisCancelled();
        }
        worker.process(samples + f * hop, rms[f], zcr[f], flat[f]);
    }
    if (progress) progress(1.0);
    return FrameFeatures(std::move(rms), std::move(zcr), std::move(flat), geometry);
}

FrameFeatures FrameAnalyzer::analyze_file(const std::string& path, const FrameGeometry& geometry,
                                          const ProgressFn& progress) const {
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (!in) throw AnalysisFailed("frame analysis", "cannot open " + path);
    const std::int64_t bytes = static_cast<std::int64_t>(in.tellg());
    in.seekg(0);
    const std::int64_t total = bytes / 4;

    const int frames = geometry.frame_count_for_samples(total);
    if (frames <= 0) {
        throw AnalysisFailed("frame analysis",
                             "the recording is shorter than one " +
                                 std::to_string(geometry.window_samples()) + "-sample window");
    }
    std::vector<float> rms(frames), zcr(frames), flat(frames);
    FrameWorker worker(geometry, fft_size_);
    const std::int64_t hop = geometry.hop_samples();
    const std::int64_t window = geometry.window_samples();

    // `buffer` holds samples [base, base + buffer.size()). Frames are processed
    // as soon as their whole window is resident, then the consumed prefix is
    // dropped, so memory stays at one block however long the file is.
    constexpr std::int64_t block = 1 << 20;
    std::vector<float> buffer;
    std::int64_t base = 0, loaded = 0;
    int next = 0;

    while (next < frames) {
        if (loaded < total) {
            const std::int64_t want = std::min(block, total - loaded);
            const std::size_t old = buffer.size();
            buffer.resize(old + static_cast<std::size_t>(want));
            in.read(reinterpret_cast<char*>(buffer.data() + old), want * 4);
            if (in.gcount() != want * 4) throw AnalysisFailed("frame analysis", "short read on " + path);
            loaded += want;
        }
        while (next < frames &&
               static_cast<std::int64_t>(next) * hop + window - base <=
                   static_cast<std::int64_t>(buffer.size())) {
            if (progress && next % 4096 == 0 && !progress(static_cast<double>(next) / frames)) {
                throw AnalysisCancelled();
            }
            worker.process(buffer.data() + (static_cast<std::int64_t>(next) * hop - base),
                           rms[next], zcr[next], flat[next]);
            ++next;
        }
        const std::int64_t keep_from = static_cast<std::int64_t>(next) * hop - base;
        if (keep_from > 0 && keep_from <= static_cast<std::int64_t>(buffer.size())) {
            buffer.erase(buffer.begin(), buffer.begin() + keep_from);
            base += keep_from;
        }
    }
    if (progress) progress(1.0);
    return FrameFeatures(std::move(rms), std::move(zcr), std::move(flat), geometry);
}

}  // namespace voxscripta
