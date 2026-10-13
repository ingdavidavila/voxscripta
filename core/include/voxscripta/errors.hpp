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

}  // namespace voxscripta
