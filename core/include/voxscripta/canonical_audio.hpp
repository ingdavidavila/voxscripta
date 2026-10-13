#pragma once

#include <filesystem>
#include <vector>

#include "voxscripta/time_range.hpp"

namespace voxscripta {

/// Reads the samples a range covers from a canonical.f32 file (headerless
/// little-endian float32). This is how a chunk, which is only a view, becomes
/// audio. Throws IoFailure when the file cannot be read or the range extends
/// past its end.
std::vector<float> read_canonical_samples(const std::filesystem::path& file, const SampleRange& range);

/// Number of samples in a canonical.f32 file. Throws IoFailure when unreadable.
std::int64_t canonical_sample_count(const std::filesystem::path& file);

}  // namespace voxscripta
