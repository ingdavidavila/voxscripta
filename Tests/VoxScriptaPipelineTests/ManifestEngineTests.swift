import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTranscription
import VoxScriptaProject
@testable import VoxScriptaPipeline

/// What a project records about the engine that made it.
///
/// `ProjectManifest.engineID` defaulted to Apple's recogniser and no caller
/// passed anything else, so every project created on Windows, Linux or
/// Android claimed `apple.speech-transcriber` for a transcript whisper.cpp
/// produced. Two things were wrong with that: the manifest is a file a user
/// can open, and `ResumePlanner` hashes the transcription stage on this value,
/// so the field is load-bearing rather than descriptive.
///
/// Found by the Windows session while investigating something else entirely.
@Suite("Manifest engine identity")
struct ManifestEngineTests {

    @Test("The default engine names the recogniser this platform will use")
    func defaultEngineMatchesThePlatform() {
        let identifier = JobRunner.defaultEngine().identifier
        #if canImport(Speech)
        #expect(identifier == .appleSpeech)
        #else
        #expect(identifier == .whisper)
        #endif
    }

    @Test("The engine reaches the resume hash, so changing it invalidates")
    func engineChangesTheTranscriptionHash() {
        // The point of recording it. Two projects identical but for the
        // engine must not share cached chunks: that is how one transcript
        // ends up half Apple's words and half whisper's.
        func inputs(_ engine: EngineID) -> StageInputs {
            StageInputs(
                sourceContentHash: "same",
                frameGeometryDescription: "same",
                silenceParameters: .default,
                chunkParameters: .default,
                engineID: engine,
                locale: "en-US",
                concurrency: 4,
                modelIdentity: "",
                cleanDescription: "same",
                polishDescription: "same")
        }
        #expect(inputs(.appleSpeech).hash(for: .transcription)
                != inputs(.whisper).hash(for: .transcription))
    }

    @Test("Apple is unchanged, so no existing Mac project re-transcribes")
    func appleProjectsHashAsBefore() {
        // The fix only moves the value off Apple. A Mac project's manifest
        // already said apple.speech-transcriber, so its hash must not move —
        // otherwise everyone's library re-transcribes on first open.
        #if canImport(Speech)
        #expect(JobRunner.defaultEngine().identifier == EngineID.appleSpeech)
        #endif
    }
}
