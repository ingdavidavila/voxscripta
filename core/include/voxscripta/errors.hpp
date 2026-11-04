#pragma once

#include <stdexcept>
#include <string>

namespace voxscripta {

/// An analysis stage could not proceed. Mirrors VoxScriptaError.analysisFailed.
class AnalysisFailed : public std::runtime_error {
public:
    AnalysisFailed(const std::string& stage, const std::string& reason)
        : std::runtime_error(stage + ": " + reason), stage_(stage) {}
    const std::string& stage() const noexcept { return stage_; }

private:
    std::string stage_;
};

/// The recording contains no speech. Mirrors VoxScriptaError.noSpeechDetected.
///
/// A distinct type rather than a flag on AnalysisFailed: callers treat "this file
/// is silent" as a user-facing outcome, not a fault.
class NoSpeechDetected : public std::runtime_error {
public:
    NoSpeechDetected() : std::runtime_error("no speech was detected in the recording") {}
};

/// The source file does not exist or cannot be opened. Mirrors sourceUnavailable.
class SourceUnavailable : public std::runtime_error {
public:
    explicit SourceUnavailable(const std::string& path)
        : std::runtime_error("the source file is unavailable: " + path) {}
};

/// The container or codec is not one the platform decoder understands.
class UnsupportedFormat : public std::runtime_error {
public:
    explicit UnsupportedFormat(const std::string& description)
        : std::runtime_error("unsupported format: " + description) {}
};

/// The container opened but holds no audio stream (a silent screen recording,
/// say). Distinct from UnsupportedFormat because the fix is different: the
/// file is fine, it has no sound in it.
class NoAudioTrack : public std::runtime_error {
public:
    explicit NoAudioTrack(const std::string& path)
        : std::runtime_error("the file has no audio track: " + path) {}
};

/// Decoding started and then failed.
class DecodingFailed : public std::runtime_error {
public:
    explicit DecodingFailed(const std::string& reason)
        : std::runtime_error("decoding failed: " + reason) {}
};

/// Reading or writing a file failed.
class IoFailure : public std::runtime_error {
public:
    IoFailure(const std::string& path, const std::string& reason)
        : std::runtime_error("I/O failure on " + path + ": " + reason) {}
};

}  // namespace voxscripta
