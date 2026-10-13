// voxscripta-cli: transcribe a recording on this PC. Nothing leaves the machine.
//
//   voxscripta-cli transcribe talk.mp3 -o out --format txt,srt
//   voxscripta-cli analyze talk.mp3
//
// The pipeline is the same one the app will run: decode to canonical PCM, analyse
// frames, detect silence, plan chunks, transcribe each chunk, merge, export.

#include <windows.h>
#include <shellapi.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "voxscripta/canonical_audio.hpp"
#include "voxscripta/chunk_planner.hpp"
#include "voxscripta/chunk_scheduler.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/exporters.hpp"
#include "voxscripta/frame_analysis.hpp"
#include "voxscripta/silence_detector.hpp"
#include "voxscripta/transcript_merger.hpp"
#include "voxscripta/whisper_engine.hpp"
#include "voxscripta/win/mf_decoder.hpp"

using namespace voxscripta;
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;

namespace {

std::atomic<bool> g_interrupted{false};

BOOL WINAPI on_ctrl(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT) {
        g_interrupted = true;
        return TRUE;
    }
    return FALSE;
}

std::string utf8(const std::wstring& w) {
    if (w.empty()) return {};
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<std::size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
    return out;
}

std::vector<std::string> command_line() {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    std::vector<std::string> out;
    for (int i = 0; i < argc; ++i) out.push_back(utf8(argv[i]));
    LocalFree(argv);
    return out;
}

fs::path path_from_utf8(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<std::size_t>(n), wchar_t{});
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return fs::path(w);
}

std::string u8(const fs::path& p) { return utf8(p.wstring()); }

struct Args {
    std::string command;
    fs::path input;
    fs::path out_dir;
    std::vector<ExportFormat> formats{ExportFormat::plain_text};
    fs::path model;
    std::string locale = "en-US";
    int threads = 0;
    bool keep_intermediates = false;
    bool timestamps = false;
    bool verbose = false;
    // Chunk sizing in seconds; 0 keeps the default.
    double chunk_min = 0, chunk_max = 0, chunk_target = 0;
};

void usage(std::FILE* to) {
    std::fputs(
        "Vox Scripta - local transcription for Windows\n"
        "\n"
        "usage:\n"
        "  voxscripta-cli transcribe <audio> [options]\n"
        "  voxscripta-cli analyze <audio>        show silence map and chunk plan; no model needed\n"
        "\n"
        "options:\n"
        "  -o, --out <dir>         where to write results (default: next to the audio)\n"
        "  --format <list>         txt,md,srt,vtt, comma separated (default: txt)\n"
        "  --model <file>          Whisper model (default: models\\ggml-small.bin)\n"
        "  --locale <tag>          spoken language, e.g. en-US, es-ES; 'auto' detects (default: en-US)\n"
        "  --threads <n>           CPU threads for Whisper (default: automatic)\n"
        "  --chunk-min/--chunk-max/--chunk-target <sec>   chunk sizing (default 120/300/240)\n"
        "  --timestamps           put [time] markers in txt and md output\n"
        "  --verbose               print each chunk's raw engine output before merging\n"
        "  --keep-intermediates    keep the decoded canonical audio\n"
        "\n"
        "The original audio is only ever read. Nothing is sent over the network.\n",
        to);
}

bool parse(const std::vector<std::string>& v, Args& a, std::string& error) {
    if (v.size() < 2) { error = "missing command"; return false; }
    a.command = v[1];
    if (a.command == "help" || a.command == "--help" || a.command == "-h") return true;
    if (a.command != "transcribe" && a.command != "analyze") { error = "unknown command: " + a.command; return false; }

    for (std::size_t i = 2; i < v.size(); ++i) {
        const std::string& s = v[i];
        auto value = [&](const char* name) -> const std::string* {
            if (i + 1 >= v.size()) { error = std::string(name) + " needs a value"; return nullptr; }
            return &v[++i];
        };
        if (s == "-o" || s == "--out") {
            const auto* x = value("--out"); if (!x) return false; a.out_dir = path_from_utf8(*x);
        } else if (s == "--format") {
            const auto* x = value("--format"); if (!x) return false;
            a.formats.clear();
            std::stringstream list(*x);
            for (std::string item; std::getline(list, item, ',');) {
                ExportFormat f;
                if (!format_from_extension(item, f)) { error = "unknown format: " + item; return false; }
                if (std::find(a.formats.begin(), a.formats.end(), f) == a.formats.end()) a.formats.push_back(f);
            }
        } else if (s == "--model") {
            const auto* x = value("--model"); if (!x) return false; a.model = path_from_utf8(*x);
        } else if (s == "--locale") {
            const auto* x = value("--locale"); if (!x) return false; a.locale = *x == "auto" ? "" : *x;
        } else if (s == "--threads") {
            const auto* x = value("--threads"); if (!x) return false; a.threads = std::atoi(x->c_str());
        } else if (s == "--chunk-min" || s == "--chunk-max" || s == "--chunk-target") {
            const auto* x = value(s.c_str()); if (!x) return false;
            (s == "--chunk-min" ? a.chunk_min : s == "--chunk-max" ? a.chunk_max : a.chunk_target) = std::atof(x->c_str());
        } else if (s == "--verbose") {
            a.verbose = true;
        } else if (s == "--timestamps") {
            a.timestamps = true;
        } else if (s == "--keep-intermediates") {
            a.keep_intermediates = true;
        } else if (!s.empty() && s[0] == '-') {
            error = "unknown option: " + s; return false;
        } else if (a.input.empty()) {
            a.input = path_from_utf8(s);
        } else {
            error = "unexpected argument: " + s; return false;
        }
    }
    if (a.input.empty()) { error = "no audio file given"; return false; }
    return true;
}

fs::path find_model(const Args& a, const fs::path& exe_dir) {
    if (!a.model.empty()) return a.model;
    if (const char* env = std::getenv("VOXSCRIPTA_MODEL")) return path_from_utf8(env);
    for (const fs::path& base : {exe_dir, exe_dir / "..", exe_dir / ".." / "..", fs::current_path()}) {
        const fs::path candidate = base / "models" / "ggml-small.bin";
        if (fs::exists(candidate)) return fs::weakly_canonical(candidate);
    }
    return fs::path("models") / "ggml-small.bin";
}

std::string clock(double seconds_total) {
    const int s = static_cast<int>(seconds_total + 0.5);
    char buf[32];
    if (s >= 3600) std::snprintf(buf, sizeof buf, "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60);
    else std::snprintf(buf, sizeof buf, "%d:%02d", s / 60, s % 60);
    return buf;
}

void note(const std::string& line) { std::fprintf(stderr, "%s\n", line.c_str()); }

/// Everything up to a chunk plan; shared by both commands.
struct Prepared {
    fs::path work_dir;
    fs::path canonical;
    MediaTime duration;
    SilenceMap silence;
    ChunkPlan plan;
};

Prepared prepare(const Args& a, const fs::path& out_dir) {
    Prepared p;
    const std::string stem = u8(a.input.stem());
    p.work_dir = out_dir / (stem + ".voxscripta-work");
    p.canonical = p.work_dir / "canonical.f32";

    win::MediaFoundationDecoder decoder;
    const AudioFormatDescription format = decoder.probe(a.input);
    note("source: " + format.format_description + (format.bit_depth ? ", " + std::to_string(*format.bit_depth) + "-bit" : ""));

    int last = -1;
    const auto t0 = Clock::now();
    decoder.decode(a.input, p.canonical, [&](double f) {
        const int pct = static_cast<int>(f * 100);
        if (pct / 10 != last / 10) { std::fprintf(stderr, "\rdecoding %3d%%", pct); last = pct; }
        return !g_interrupted.load();
    });
    std::fprintf(stderr, "\rdecoding 100%%\n");

    const std::int64_t samples = canonical_sample_count(p.canonical);
    p.duration = MediaTime::from_samples(samples, CanonicalFormat::sample_rate);
    note("duration: " + clock(p.duration.seconds()) + "  (decoded in " + clock(std::chrono::duration<double>(Clock::now() - t0).count()) + ")");

    const FrameFeatures features = FrameAnalyzer().analyze_file(p.canonical.string(), FrameGeometry{}, [&](double f) {
        std::fprintf(stderr, "\ranalysing %3d%%", static_cast<int>(f * 100));
        return !g_interrupted.load();
    });
    std::fprintf(stderr, "\ranalysing 100%%\n");

    p.silence = SilenceDetector{}.detect(features, SilenceParameters{}, p.duration, "cli");
    char line[160];
    std::snprintf(line, sizeof line, "speech: %s of %s (%.0f%%) in %zu regions",
                  clock(p.silence.speech_duration().seconds()).c_str(), clock(p.duration.seconds()).c_str(),
                  p.silence.speech_fraction() * 100, p.silence.speech_regions.size());
    note(line);

    ChunkParameters chunks;
    if (a.chunk_min > 0) chunks.min_duration = seconds(a.chunk_min);
    if (a.chunk_max > 0) chunks.max_duration = seconds(a.chunk_max);
    if (a.chunk_target > 0) chunks.target_duration = seconds(a.chunk_target);
    p.plan = ChunkPlanner{}.plan(p.silence, chunks, "cli");
    note("plan: " + std::to_string(p.plan.chunks.size()) + " chunk(s), " + std::to_string(p.plan.hard_cut_count()) + " hard cut(s)");
    return p;
}

int run_analyze(const Args& a) {
    const fs::path out_dir = a.out_dir.empty() ? fs::temp_directory_path() : a.out_dir;
    Prepared p = prepare(a, out_dir);
    std::printf("\nspeech regions\n");
    for (const auto& r : p.silence.speech_regions) {
        std::printf("  %s - %s  (mean %.0f dB, peak %.0f dB)\n", r.range.start_time().to_string().c_str(),
                    r.range.end_time().to_string().c_str(), static_cast<double>(r.mean_energy_db),
                    static_cast<double>(r.peak_energy_db));
    }
    std::printf("\nchunks\n");
    for (const auto& c : p.plan.chunks) {
        const char* kind = c.boundary_kind.kind == BoundaryKind::Kind::silence ? "silence"
                           : c.boundary_kind.kind == BoundaryKind::Kind::hard_cut ? "HARD CUT" : "end";
        std::printf("  #%d  %s - %s  ends at: %s\n", c.sequence, c.original_range.start_time().to_string().c_str(),
                    c.original_range.end_time().to_string().c_str(), kind);
    }
    std::error_code ec;
    if (!a.keep_intermediates) fs::remove_all(p.work_dir, ec);
    return 0;
}

int run_transcribe(const Args& a, const fs::path& exe_dir) {
    const fs::path out_dir = a.out_dir.empty() ? (a.input.has_parent_path() ? a.input.parent_path() : fs::current_path()) : a.out_dir;
    std::error_code ec;
    fs::create_directories(out_dir, ec);

    const fs::path model = find_model(a, exe_dir);
    if (!fs::exists(model)) {
        std::fprintf(stderr, "error: Whisper model not found at %s\n       run Tools/fetch-whisper.sh or pass --model\n", u8(model).c_str());
        return 1;
    }

    const auto began = Clock::now();
    Prepared p = prepare(a, out_dir);

    WhisperEngine engine({model, a.threads});
    note("loading model " + u8(model.filename()));
    engine.prepare(a.locale);

    TranscriptionOptions options;
    options.locale = a.locale;
    SchedulerCallbacks callbacks;
    callbacks.cancelled = [] { return g_interrupted.load(); };
    callbacks.progress = [&](int done, int total) {
        std::fprintf(stderr, "transcribing chunk %d/%d  (%s elapsed)\n", done, total,
                     clock(std::chrono::duration<double>(Clock::now() - began).count()).c_str());
    };
    const auto reader = [&](const SampleRange& r) { return read_canonical_samples(p.canonical, r); };
    const SchedulerOutcome outcome = ChunkScheduler{}.run(p.plan, reader, engine, options, {}, callbacks);
    engine.release();

    if (a.verbose) {
        for (const auto& chunk : outcome.transcripts) {
            std::fprintf(stderr, "\n--- chunk %d (%.1f s to transcribe)\n", chunk.sequence, chunk.processing_seconds);
            for (const auto& seg : chunk.segments) {
                std::fprintf(stderr, "[%s - %s] %s\n", seg.original_start.to_string().c_str(),
                             seg.original_end.to_string().c_str(), seg.text.c_str());
            }
        }
    }

    for (const auto& failed : outcome.failed_chunks()) {
        std::fprintf(stderr, "warning: chunk %d could not be transcribed (%s); a gap marker was left in its place\n",
                     failed.sequence, failed.last_error.c_str());
    }

    const Transcript transcript = TranscriptMerger{}.merge(outcome.transcripts, p.plan, p.silence, engine.identifier());

    ExportOptions export_options;
    export_options.include_timestamps = a.timestamps;
    const std::string stem = u8(a.input.stem());
    for (ExportFormat format : a.formats) {
        std::string body;
        try {
            body = export_transcript(transcript, format, export_options);
        } catch (const AnalysisFailed& e) {
            std::fprintf(stderr, "skipped .%s: %s\n", file_extension(format), e.what());
            continue;
        }
        const fs::path target = out_dir / path_from_utf8(stem + "." + file_extension(format));
        std::ofstream out(target, std::ios::binary | std::ios::trunc);
        out.write(body.data(), static_cast<std::streamsize>(body.size()));
        if (!out) throw IoFailure(u8(target), "could not write");
        std::printf("wrote %s\n", u8(target).c_str());
    }

    const double took = std::chrono::duration<double>(Clock::now() - began).count();
    char line[200];
    std::snprintf(line, sizeof line, "done: %zu words in %s (%.2fx real time)", transcript.word_count(),
                  clock(took).c_str(), p.duration.seconds() / std::max(took, 0.001));
    note(line);

    if (!a.keep_intermediates) fs::remove_all(p.work_dir, ec);
    return outcome.failed_chunks().empty() ? 0 : 3;
}

}  // namespace

int main() {
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCtrlHandler(on_ctrl, TRUE);

    const std::vector<std::string> argv = command_line();
    Args args;
    std::string error;
    if (!parse(argv, args, error)) {
        std::fprintf(stderr, "error: %s\n\n", error.c_str());
        usage(stderr);
        return 64;
    }
    if (args.command == "help" || args.command == "--help" || args.command == "-h") {
        usage(stdout);
        return 0;
    }

    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    const fs::path exe_dir = fs::path(exe).parent_path();

    try {
        return args.command == "analyze" ? run_analyze(args) : run_transcribe(args, exe_dir);
    } catch (const NoSpeechDetected&) {
        std::fprintf(stderr, "\nno speech was detected in this recording.\n");
        return 2;
    } catch (const win::DecodeCancelled&) {
        std::fprintf(stderr, "\ncancelled.\n");
        return 130;
    } catch (const AnalysisCancelled&) {
        std::fprintf(stderr, "\ncancelled.\n");
        return 130;
    } catch (const SchedulerCancelled&) {
        std::fprintf(stderr, "\ncancelled; nothing was written.\n");
        return 130;
    } catch (const SourceUnavailable& e) {
        std::fprintf(stderr, "\nerror: %s\n", e.what());
        return 66;
    } catch (const NoAudioTrack& e) {
        std::fprintf(stderr, "\nerror: %s\n", e.what());
        return 65;
    } catch (const UnsupportedFormat& e) {
        std::fprintf(stderr, "\nerror: %s\n       convert the file to WAV, MP3 or M4A and try again.\n", e.what());
        return 65;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "\nerror: %s\n", e.what());
        return 1;
    }
}
