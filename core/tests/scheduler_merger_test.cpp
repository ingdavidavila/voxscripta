// Ported in spirit from SchedulerTests.swift and MergerTests.swift, against the
// deterministic mock engine.

#include <algorithm>
#include <atomic>
#include <cmath>
#include <set>

#include "harness.hpp"
#include "mock_engine.hpp"
#include "voxscripta/chunk_planner.hpp"
#include "voxscripta/chunk_scheduler.hpp"
#include "voxscripta/errors.hpp"
#include "voxscripta/transcript_merger.hpp"

using namespace voxscripta;
using namespace voxscripta::testing;

namespace {

ChunkParameters small_chunks() {
    ChunkParameters p;
    p.min_duration = seconds(20);
    p.max_duration = seconds(40);
    p.target_duration = seconds(30);
    p.overlap_duration = seconds(3);
    return p;
}

/// A plan with silence gaps to cut at: roughly 5 chunks.
struct Fixture {
    SilenceMap map = make_map(150, 10);
    ChunkPlan plan = ChunkPlanner{}.plan(map, small_chunks(), "p");
    MockEngine engine;
    Fixture() { engine.register_plan(plan); }
};

const ChunkAudioReader no_audio = [](const SampleRange& r) {
    return std::vector<float>(static_cast<std::size_t>(r.count()));
};

ChunkScheduler fast_scheduler() {
    ChunkScheduler s;
    s.retry_backoff = std::chrono::milliseconds(1);
    return s;
}

std::vector<std::string> all_words(const Transcript& t) {
    std::vector<std::string> out;
    for (const auto& s : t.segments)
        for (const auto& w : s.words) out.push_back(w.text);
    return out;
}

}  // namespace

// ── Scheduler ───────────────────────────────────────────────────────────────

VS_TEST("Chunk scheduler", "Every chunk is transcribed and results come back ordered") {
    Fixture f;
    TranscriptionOptions options;
    options.concurrency = 3;
    const auto outcome = fast_scheduler().run(f.plan, no_audio, f.engine, options);
    VS_EXPECT(f.plan.chunks.size() >= 4);
    VS_EXPECT_EQ(outcome.transcripts.size(), f.plan.chunks.size());
    for (std::size_t i = 0; i < outcome.transcripts.size(); ++i) {
        VS_EXPECT_EQ(outcome.transcripts[i].sequence, static_cast<int>(i));
    }
    VS_EXPECT_EQ(outcome.completed_count(), f.plan.chunks.size());
}

VS_TEST("Chunk scheduler", "Concurrency never exceeds the configured limit") {
    for (int limit : {1, 2, 4}) {
        Fixture f;
        for (const auto& c : f.plan.chunks) {
            f.engine.set_behaviour(c.sequence, MockEngine::Behaviour::slow, 0, std::chrono::milliseconds(30));
        }
        TranscriptionOptions options;
        options.concurrency = limit;
        fast_scheduler().run(f.plan, no_audio, f.engine, options);
        VS_EXPECT_MSG(f.engine.peak_concurrency.load() <= limit, "limit " + std::to_string(limit));
        if (limit > 1) VS_EXPECT_MSG(f.engine.peak_concurrency.load() > 1, "work never overlapped");
    }
}

VS_TEST("Chunk scheduler", "A transient failure is retried and then succeeds") {
    Fixture f;
    f.engine.set_behaviour(1, MockEngine::Behaviour::fail_times, 2);
    const auto outcome = fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{});
    VS_EXPECT_EQ(outcome.transcripts.size(), f.plan.chunks.size());
    VS_EXPECT_EQ(outcome.records[1].attempts, 3);
    VS_EXPECT(outcome.records[1].state == ChunkState::completed);
}

VS_TEST("Chunk scheduler", "A permanently failing chunk does not fail the job") {
    Fixture f;
    f.engine.set_behaviour(2, MockEngine::Behaviour::fail_always);
    const auto outcome = fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{});
    VS_EXPECT_EQ(outcome.failed_chunks().size(), std::size_t{1});
    VS_EXPECT_EQ(outcome.failed_chunks()[0].sequence, 2);
    VS_EXPECT_EQ(outcome.failed_chunks()[0].attempts, 3);
    VS_EXPECT_EQ(outcome.transcripts.size(), f.plan.chunks.size() - 1);
}

VS_TEST("Chunk scheduler", "Already-completed chunks are not transcribed again") {
    Fixture f;
    const auto outcome = fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{}, {0, 1});
    const auto started = f.engine.start_order();
    VS_EXPECT(std::find(started.begin(), started.end(), 0) == started.end());
    VS_EXPECT(std::find(started.begin(), started.end(), 1) == started.end());
    VS_EXPECT_EQ(outcome.transcripts.size(), f.plan.chunks.size() - 2);
}

VS_TEST("Chunk scheduler", "Each result is committed before the chunk counts as done") {
    Fixture f;
    std::atomic<int> committed{0};
    bool ahead = false;
    SchedulerCallbacks cb;
    cb.on_chunk_complete = [&](const ChunkTranscript&) { ++committed; };
    cb.progress = [&](int done, int) {
        // Progress can only trail commits, never lead them.
        if (done > committed.load()) ahead = true;
    };
    TranscriptionOptions options;
    options.concurrency = 3;
    fast_scheduler().run(f.plan, no_audio, f.engine, options, {}, cb);
    VS_EXPECT(!ahead);
    VS_EXPECT_EQ(committed.load(), static_cast<int>(f.plan.chunks.size()));
}

VS_TEST("Chunk scheduler", "Progress is reported for every chunk and ends at the total") {
    Fixture f;
    std::vector<int> reports;
    int total_seen = 0;
    SchedulerCallbacks cb;
    cb.progress = [&](int done, int total) { reports.push_back(done); total_seen = total; };
    fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{}, {}, cb);
    VS_EXPECT_EQ(reports.size(), f.plan.chunks.size());
    VS_EXPECT_EQ(reports.back(), total_seen);
    VS_EXPECT(std::is_sorted(reports.begin(), reports.end()));
}

VS_TEST("Chunk scheduler", "Cancellation stops scheduling and leaves chunks resumable") {
    Fixture f;
    std::atomic<int> finished{0};
    SchedulerCallbacks cb;
    cb.on_chunk_complete = [&](const ChunkTranscript&) { ++finished; };
    cb.cancelled = [&] { return finished.load() >= 2; };
    VS_EXPECT_THROWS(fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{}, {}, cb),
                     SchedulerCancelled);
    VS_EXPECT_EQ(finished.load(), 2);
}

VS_TEST("Chunk scheduler", "A failing commit stops the run and surfaces the error") {
    Fixture f;
    SchedulerCallbacks cb;
    cb.on_chunk_complete = [](const ChunkTranscript&) { throw IoFailure("db", "disk full"); };
    VS_EXPECT_THROWS(fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{}, {}, cb),
                     IoFailure);
}

// ── Merger ──────────────────────────────────────────────────────────────────

VS_TEST("Transcript merger", "A full plan merges into one continuous transcript") {
    Fixture f;
    const auto outcome = fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{});
    const Transcript t = TranscriptMerger{}.merge(outcome.transcripts, f.plan, f.map, "mock");
    VS_EXPECT(t.is_monotonic());
    VS_EXPECT(t.word_count() > 100);
    // Soft boundaries need no de-duplication, so no word may repeat.
    const auto words = all_words(t);
    VS_EXPECT_EQ(std::set<std::string>(words.begin(), words.end()).size(), words.size());
}

VS_TEST("Transcript merger", "Chunks merge in sequence order regardless of completion order") {
    Fixture f;
    auto outcome = fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{});
    std::reverse(outcome.transcripts.begin(), outcome.transcripts.end());
    const Transcript t = TranscriptMerger{}.merge(outcome.transcripts, f.plan, f.map, "mock");
    VS_EXPECT(t.is_monotonic());
    VS_EXPECT(t.segments.front().original_start < t.segments.back().original_start);
}

VS_TEST("Transcript merger", "Overlapping words after a hard cut appear exactly once") {
    // Continuous speech: no gap to cut at, so every boundary is a hard cut with
    // a 3 s overlap, and each overlap is transcribed twice.
    const SilenceMap map = make_map(300);
    ChunkParameters p;
    p.min_duration = seconds(60); p.max_duration = seconds(100);
    p.target_duration = seconds(80); p.overlap_duration = seconds(3);
    const ChunkPlan plan = ChunkPlanner{}.plan(map, p, "p");
    VS_EXPECT(plan.hard_cut_count() >= 2);

    MockEngine engine;
    engine.register_plan(plan);
    const auto outcome = fast_scheduler().run(plan, no_audio, engine, TranscriptionOptions{});
    const Transcript t = TranscriptMerger{}.merge(outcome.transcripts, plan, map, "mock");

    const auto words = all_words(t);
    VS_EXPECT_EQ(std::set<std::string>(words.begin(), words.end()).size(), words.size());
    // And nothing is lost: word numbers run consecutively from start to end.
    for (std::size_t i = 1; i < words.size(); ++i) {
        VS_EXPECT_MSG(std::stol(words[i].substr(1)) == std::stol(words[i - 1].substr(1)) + 1,
                      words[i - 1] + " -> " + words[i]);
    }
    for (const auto& s : t.segments) {
        VS_EXPECT(std::find(s.warnings.begin(), s.warnings.end(), SegmentWarning::merge_ambiguity) ==
                  s.warnings.end());
    }
}

VS_TEST("Transcript merger", "An ambiguous splice is flagged rather than hidden") {
    const SilenceMap map = make_map(200);
    ChunkParameters p;
    p.min_duration = seconds(60); p.max_duration = seconds(100);
    p.target_duration = seconds(80); p.overlap_duration = seconds(3);
    const ChunkPlan plan = ChunkPlanner{}.plan(map, p, "p");
    MockEngine engine;
    engine.register_plan(plan);
    auto outcome = fast_scheduler().run(plan, no_audio, engine, TranscriptionOptions{});

    // Garble the second chunk's words so no overlap text can match.
    for (auto& seg : outcome.transcripts[1].segments)
        for (auto& w : seg.words) w.text = "zz" + w.text;

    const Transcript t = TranscriptMerger{}.merge(outcome.transcripts, plan, map, "mock");
    bool flagged = false;
    for (const auto& s : t.segments)
        flagged |= std::find(s.warnings.begin(), s.warnings.end(), SegmentWarning::merge_ambiguity) != s.warnings.end();
    VS_EXPECT(flagged);
    VS_EXPECT(t.is_monotonic());
}

VS_TEST("Transcript merger", "A missing chunk leaves a visible gap in the right place") {
    Fixture f;
    f.engine.set_behaviour(2, MockEngine::Behaviour::fail_always);
    const auto outcome = fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{});
    const Transcript t = TranscriptMerger{}.merge(outcome.transcripts, f.plan, f.map, "mock");

    const TranscriptSegment* gap = nullptr;
    for (const auto& s : t.segments)
        if (std::find(s.warnings.begin(), s.warnings.end(), SegmentWarning::transcription_gap) != s.warnings.end())
            gap = &s;
    VS_EXPECT(gap != nullptr);
    if (gap) {
        VS_EXPECT(gap->original_start == f.plan.chunks[2].original_range.start_time());
        VS_EXPECT(gap->original_end == f.plan.chunks[2].original_range.end_time());
        VS_EXPECT(gap->text.empty());
    }
    VS_EXPECT(t.is_monotonic());
}

VS_TEST("Transcript merger", "Pause durations between segments are measured and carried forward") {
    Fixture f;
    const auto outcome = fast_scheduler().run(f.plan, no_audio, f.engine, TranscriptionOptions{});
    const Transcript t = TranscriptMerger{}.merge(outcome.transcripts, f.plan, f.map, "mock");

    // The first segment has nothing before it; every later one carries a pause.
    VS_EXPECT(!t.segments.front().preceding_gap.has_value());
    for (std::size_t i = 1; i < t.segments.size(); ++i) VS_EXPECT(t.segments[i].preceding_gap.has_value());

    // The map has a 1 s gap at 10-11 s. A pause spanning it measures that gap,
    // not the raw time difference; one inside speech falls back to the raw difference.
    VS_EXPECT(TranscriptMerger::measured_pause(seconds(9.9), seconds(11.2), f.map) == seconds(1.0));
    VS_EXPECT(TranscriptMerger::measured_pause(seconds(2.0), seconds(2.4), f.map) == seconds(0.4));
    VS_EXPECT(TranscriptMerger::measured_pause(seconds(5.0), seconds(4.0), f.map) == MediaTime::zero());
}

VS_TEST("Transcript merger", "Overlap matching needs corroboration, not a single word") {
    TranscriptMerger merger;
    const std::vector<Word> a = {{"x", seconds(1), seconds(1.4), {}}, {"the", seconds(2), seconds(2.4), {}}};
    const std::vector<Word> b = {{"the", seconds(2), seconds(2.4), {}}, {"y", seconds(3), seconds(3.4), {}}};
    VS_EXPECT_EQ(merger.longest_overlap(a, b), 0);
}

VS_TEST("Transcript merger", "Words that match textually but not in time are rejected") {
    TranscriptMerger merger;
    const std::vector<Word> a = {{"hello", seconds(1), seconds(1.4), {}}, {"world", seconds(2), seconds(2.4), {}}};
    const std::vector<Word> far = {{"hello", seconds(60), seconds(60.4), {}}, {"world", seconds(61), seconds(61.4), {}}};
    const std::vector<Word> near = {{"Hello,", seconds(1.1), seconds(1.5), {}}, {"world.", seconds(2.1), seconds(2.5), {}}};
    VS_EXPECT_EQ(merger.longest_overlap(a, far), 0);
    VS_EXPECT_EQ(merger.longest_overlap(a, near), 2);  // punctuation and case are ignored
}

VS_TEST("Transcript merger", "Timestamp jitter between overlapping chunks cannot break the ordering") {
    // A real engine times the same words a little differently in each chunk. Here
    // every chunk after the first runs 100 ms early, so after de-duplication the
    // first surviving segment would start before the previous one ended.
    const SilenceMap map = make_map(200);
    ChunkParameters p;
    p.min_duration = seconds(60); p.max_duration = seconds(100);
    p.target_duration = seconds(80); p.overlap_duration = seconds(3);
    const ChunkPlan plan = ChunkPlanner{}.plan(map, p, "p");
    MockEngine engine;
    engine.register_plan(plan);
    auto outcome = fast_scheduler().run(plan, no_audio, engine, TranscriptionOptions{});

    for (std::size_t i = 1; i < outcome.transcripts.size(); ++i) {
        for (auto& seg : outcome.transcripts[i].segments) {
            seg.original_start = seg.original_start - milliseconds(100);
            seg.original_end = seg.original_end - milliseconds(100);
            for (auto& w : seg.words) {
                w.original_start = w.original_start - milliseconds(100);
                w.original_end = w.original_end - milliseconds(100);
            }
        }
    }
    const Transcript t = TranscriptMerger{}.merge(outcome.transcripts, plan, map, "mock");
    VS_EXPECT(t.is_monotonic());
    for (const auto& s : t.segments) {
        MediaTime cursor = s.original_start;
        for (const auto& w : s.words) {
            VS_EXPECT(w.original_start >= cursor);
            VS_EXPECT(w.original_end >= w.original_start);
            cursor = w.original_start;
        }
    }
    // No words were lost or repeated by the clamping.
    const auto words = all_words(t);
    VS_EXPECT_EQ(std::set<std::string>(words.begin(), words.end()).size(), words.size());
}

VS_TEST("Transcript merger", "Fragment words at a hard cut are removed when the splice shows they are noise") {
    // A cut lands mid-word: the earlier chunk ends in a fragment ("an" for
    // "enough") and the later one begins with a stray leading word. Both are
    // seen on real speech.
    const SilenceMap map = make_map(200);
    ChunkParameters p;
    p.min_duration = seconds(60); p.max_duration = seconds(100);
    p.target_duration = seconds(80); p.overlap_duration = seconds(3);
    const ChunkPlan plan = ChunkPlanner{}.plan(map, p, "p");
    MockEngine engine;
    engine.register_plan(plan);
    auto outcome = fast_scheduler().run(plan, no_audio, engine, TranscriptionOptions{});

    // Earlier chunk: append a fragment right after its last word.
    auto& first = outcome.transcripts[0].segments.back();
    first.words.push_back({"an", first.words.back().original_end, first.words.back().original_end + milliseconds(50), {}});
    first.text += " an";
    first.original_end = first.words.back().original_end;
    // Later chunk: prepend a stray word just before its first real one.
    auto& second = outcome.transcripts[1].segments.front();
    second.words.insert(second.words.begin(), Word{"uh", second.words.front().original_start - milliseconds(60),
                                                  second.words.front().original_start - milliseconds(10), {}});

    const Transcript t = TranscriptMerger{}.merge(outcome.transcripts, plan, map, "mock");
    const auto words = all_words(t);
    VS_EXPECT(std::find(words.begin(), words.end(), "an") == words.end());
    VS_EXPECT(std::find(words.begin(), words.end(), "uh") == words.end());
    for (std::size_t i = 1; i < words.size(); ++i) {
        VS_EXPECT_MSG(std::stol(words[i].substr(1)) == std::stol(words[i - 1].substr(1)) + 1,
                      words[i - 1] + " -> " + words[i]);
    }
    for (const auto& s : t.segments) {
        VS_EXPECT(std::find(s.warnings.begin(), s.warnings.end(), SegmentWarning::merge_ambiguity) ==
                  s.warnings.end());
    }
}
