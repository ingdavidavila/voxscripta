#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <stdexcept>

#include "voxscripta/audio_format.hpp"
#include "voxscripta/media_time.hpp"

namespace voxscripta::win {

/// Called with 0...1 completion. Return false to cancel; decode then throws
/// DecodeCancelled and leaves no partial file behind.
using DecodeProgressFn = std::function<bool(double)>;

class DecodeCancelled : public std::runtime_error {
public:
    DecodeCancelled() : std::runtime_error("decode cancelled") {}
};

/// Streams a source file into the canonical 16 kHz mono float PCM
/// representation using Windows Media Foundation.
///
/// Counterpart of CanonicalDecoder.swift. Memory behaviour is the same on
/// purpose: samples are read a buffer at a time and appended to disk, so a
/// six-hour file has the same footprint as a six-second one.
///
/// Read-only by construction: the source is only ever opened for reading.
///
/// Formats are whatever Media Foundation has a demuxer and decoder for on the
/// running machine: WAV, MP3, AAC/M4A/MP4, WMA, and FLAC on current Windows 10
/// and 11. AIFF, CAF and Ogg are not handled natively; those fail with
/// UnsupportedFormat so the caller can ask for a conversion.
class MediaFoundationDecoder {
public:
    /// Probes the format without decoding.
    /// Throws SourceUnavailable, NoAudioTrack, UnsupportedFormat.
    AudioFormatDescription probe(const std::filesystem::path& source) const;

    /// The container-reported duration, or nullopt when it does not say.
    std::optional<MediaTime> duration(const std::filesystem::path& source) const;

    /// Decodes `source` into `destination` as raw little-endian float32 at
    /// CanonicalFormat::sample_rate, mono. Multichannel sources are mixed down,
    /// not reduced to one channel. Returns the number of samples written.
    /// Throws SourceUnavailable, NoAudioTrack, UnsupportedFormat, DecodingFailed,
    /// IoFailure, DecodeCancelled.
    std::int64_t decode(const std::filesystem::path& source,
                        const std::filesystem::path& destination,
                        const DecodeProgressFn& progress = {}) const;
};

}  // namespace voxscripta::win
