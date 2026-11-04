#include "voxscripta/canonical_audio.hpp"

#include <fstream>

#include "voxscripta/errors.hpp"

namespace voxscripta {

std::int64_t canonical_sample_count(const std::filesystem::path& file) {
    std::error_code ec;
    const auto bytes = std::filesystem::file_size(file, ec);
    if (ec) throw IoFailure(file.string(), ec.message());
    return static_cast<std::int64_t>(bytes / 4);
}

std::vector<float> read_canonical_samples(const std::filesystem::path& file, const SampleRange& range) {
    const std::int64_t total = canonical_sample_count(file);
    if (range.end_index() > total) {
        throw IoFailure(file.string(), "range ends at sample " + std::to_string(range.end_index()) +
                                           " but the file holds " + std::to_string(total));
    }
    std::ifstream in(file, std::ios::binary);
    if (!in) throw IoFailure(file.string(), "could not open");
    in.seekg(range.byte_begin());

    std::vector<float> samples(static_cast<std::size_t>(range.count()));
    in.read(reinterpret_cast<char*>(samples.data()), static_cast<std::streamsize>(samples.size() * 4));
    if (static_cast<std::size_t>(in.gcount()) != samples.size() * 4) {
        throw IoFailure(file.string(), "short read");
    }
    return samples;
}

}  // namespace voxscripta
