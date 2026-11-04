#include "voxscripta/chunk_scheduler.hpp"

#include <algorithm>
#include <exception>
#include <mutex>
#include <thread>

#include "voxscripta/errors.hpp"

namespace voxscripta {

std::vector<ChunkRecord> SchedulerOutcome::failed_chunks() const {
    std::vector<ChunkRecord> out;
    for (const auto& r : records) {
        if (r.state == ChunkState::failed_permanent) out.push_back(r);
    }
    return out;
}

std::size_t SchedulerOutcome::completed_count() const {
    return static_cast<std::size_t>(std::count_if(
        records.begin(), records.end(), [](const ChunkRecord& r) { return r.state == ChunkState::completed; }));
}

namespace {

/// Errors that retrying cannot fix: a bad argument stays bad.
bool is_retryable(const std::exception& e) {
    return dynamic_cast<const std::invalid_argument*>(&e) == nullptr &&
           dynamic_cast<const std::logic_error*>(&e) == nullptr &&
           dynamic_cast<const SourceUnavailable*>(&e) == nullptr;
}

struct Attempt {
    bool ok = false;
    ChunkTranscript transcript;
    ChunkRecord record;
};

Attempt transcribe_with_retries(const ChunkSpec& chunk, const ChunkAudioReader& read_audio,
                                TranscriptionEngine& engine, const TranscriptionOptions& options,
                                std::chrono::milliseconds backoff, const SchedulerCallbacks& callbacks) {
    Attempt result;
    result.record.sequence = chunk.sequence;
    result.record.state = ChunkState::in_flight;
    auto delay = backoff;

    while (result.record.attempts < options.max_attempts_per_chunk) {
        if (callbacks.cancelled && callbacks.cancelled()) {
            result.record.state = ChunkState::pending;  // resume picks it up unchanged
            result.record.last_error = "cancelled";
            return result;
        }
        ++result.record.attempts;
        const auto started = std::chrono::steady_clock::now();
        try {
            const std::vector<float> samples = read_audio(chunk.sample_range);
            auto segments = engine.transcribe(chunk.sample_range, samples.data(), options);
            const double elapsed =
                std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();

            for (auto& s : segments) s.chunk_sequence = chunk.sequence;
            result.ok = true;
            result.record.state = ChunkState::completed;
            result.record.processing_seconds = elapsed;
            result.record.last_error.clear();
            result.transcript = {chunk.sequence, std::move(segments), engine.identifier(), elapsed};
            return result;
        } catch (const std::exception& e) {
            result.record.last_error = e.what();
            if (!is_retryable(e) || result.record.attempts >= options.max_attempts_per_chunk) {
                result.record.state = ChunkState::failed_permanent;
                return result;
            }
            result.record.state = ChunkState::retry_scheduled;
            std::this_thread::sleep_for(delay);
            delay *= 2;
        }
    }
    result.record.state = ChunkState::failed_permanent;
    return result;
}

}  // namespace

SchedulerOutcome ChunkScheduler::run(const ChunkPlan& plan, const ChunkAudioReader& read_audio,
                                     TranscriptionEngine& engine, const TranscriptionOptions& options,
                                     const std::set<int>& skipping,
                                     const SchedulerCallbacks& callbacks) const {
    std::vector<const ChunkSpec*> pending;
    for (const auto& chunk : plan.chunks) {
        if (!skipping.count(chunk.sequence)) pending.push_back(&chunk);
    }
    SchedulerOutcome outcome;
    if (pending.empty()) return outcome;

    const int total = static_cast<int>(plan.chunks.size());
    int done = total - static_cast<int>(pending.size());
    std::size_t next = 0;
    bool stop = false;
    bool was_cancelled = false;
    std::exception_ptr error;
    std::mutex mutex;

    auto worker = [&] {
        for (;;) {
            const ChunkSpec* chunk = nullptr;
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (stop || next >= pending.size()) return;
                if (callbacks.cancelled && callbacks.cancelled()) {
                    stop = was_cancelled = true;
                    return;
                }
                chunk = pending[next++];
            }
            Attempt attempt = transcribe_with_retries(*chunk, read_audio, engine, options, retry_backoff, callbacks);
            try {
                // Commit before counting it done, so a crash between the two
                // cannot lose work that was reported as finished.
                if (attempt.ok && callbacks.on_chunk_complete) callbacks.on_chunk_complete(attempt.transcript);
            } catch (...) {
                std::lock_guard<std::mutex> lock(mutex);
                if (!error) error = std::current_exception();
                stop = true;
                return;
            }
            std::lock_guard<std::mutex> lock(mutex);
            if (attempt.record.state == ChunkState::pending) was_cancelled = stop = true;
            if (attempt.ok) outcome.transcripts.push_back(std::move(attempt.transcript));
            outcome.records.push_back(attempt.record);
            ++done;
            if (callbacks.progress) callbacks.progress(done, total);
        }
    };

    const int workers = std::max(1, std::min(options.concurrency, static_cast<int>(pending.size())));
    std::vector<std::thread> threads;
    for (int i = 1; i < workers; ++i) threads.emplace_back(worker);
    worker();
    for (auto& t : threads) t.join();

    auto by_sequence = [](const auto& a, const auto& b) { return a.sequence < b.sequence; };
    std::sort(outcome.transcripts.begin(), outcome.transcripts.end(), by_sequence);
    std::sort(outcome.records.begin(), outcome.records.end(), by_sequence);

    if (error) std::rethrow_exception(error);
    if (was_cancelled) throw SchedulerCancelled();
    return outcome;
}

}  // namespace voxscripta
