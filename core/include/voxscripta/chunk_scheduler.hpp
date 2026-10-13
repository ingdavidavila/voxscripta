#pragma once

#include <chrono>
#include <functional>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

#include "voxscripta/chunk_models.hpp"
#include "voxscripta/transcription_engine.hpp"

namespace voxscripta {

/// One chunk's result, before merging.
struct ChunkTranscript {
    int sequence = 0;
    std::vector<TranscriptSegment> segments;
    std::string engine_id;
    /// Wall-clock time the engine took.
    double processing_seconds = 0;
};

enum class ChunkState { pending, in_flight, retry_scheduled, completed, failed_permanent };

/// Bookkeeping for one chunk, kept for the ones that failed as well.
struct ChunkRecord {
    int sequence = 0;
    ChunkState state = ChunkState::pending;
    int attempts = 0;
    std::string last_error;
    double processing_seconds = 0;
};

struct SchedulerOutcome {
    std::vector<ChunkTranscript> transcripts;  // successful, ordered by sequence
    std::vector<ChunkRecord> records;          // every chunk run, ordered by sequence

    /// Chunks that exhausted their retries. The job continues without them.
    std::vector<ChunkRecord> failed_chunks() const;
    std::size_t completed_count() const;
};

/// Thrown by run() when cancellation was requested. Finished chunks have
/// already been handed to `on_chunk_complete`.
class SchedulerCancelled : public std::runtime_error {
public:
    SchedulerCancelled() : std::runtime_error("transcription cancelled") {}
};

struct SchedulerCallbacks {
    /// Runs on a worker thread before the chunk is counted done, so a caller that
    /// persists results is durable up to every chunk reported finished. If it
    /// throws, the run stops and the exception is rethrown from run().
    std::function<void(const ChunkTranscript&)> on_chunk_complete;
    /// (chunks done, chunks total), called after each chunk settles. Serialized.
    std::function<void(int, int)> progress;
    /// Polled between chunks; return true to stop.
    std::function<bool()> cancelled;
};

/// Supplies the audio for a chunk. Called on worker threads.
using ChunkAudioReader = std::function<std::vector<float>(const SampleRange&)>;

/// Drives chunk transcription with bounded concurrency and a retry budget.
///
/// **A failed chunk does not fail the job.** After its retries are exhausted the
/// chunk is marked failed_permanent, the merger leaves a visible gap marker in
/// its place, and the remaining chunks proceed. A 200-chunk lecture with one
/// corrupt region should yield 199 good chunks and a marker, not nothing.
class ChunkScheduler {
public:
    /// Base delay before a retry; doubled on each further attempt.
    std::chrono::milliseconds retry_backoff{250};

    SchedulerOutcome run(const ChunkPlan& plan, const ChunkAudioReader& read_audio,
                         TranscriptionEngine& engine, const TranscriptionOptions& options,
                         const std::set<int>& skipping = {},
                         const SchedulerCallbacks& callbacks = {}) const;
};

}  // namespace voxscripta
