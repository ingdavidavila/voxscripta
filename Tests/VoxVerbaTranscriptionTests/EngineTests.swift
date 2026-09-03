import Testing
import Foundation
import VoxVerbaCore
@testable import VoxVerbaTranscription

@Suite("Transcription engines")
struct EngineTests {

    @Test("Both shipped engines advertise word timestamps")
    func wordTimestamps() {
        // The merger's overlap de-duplication and the polish validator both depend
        // on word-level timing, so an engine without it cannot be a default.
        #expect(AppleSpeechEngine().capabilities.supportsWordTimestamps)
        #expect(WhisperKitEngine().capabilities.supportsWordTimestamps)
    }

    @Test("Engine identities are distinct")
    func identities() {
        #expect(AppleSpeechEngine().identifier == .appleSpeech)
        #expect(WhisperKitEngine().identifier == .whisperKit)
        #expect(EngineID.appleSpeech != EngineID.whisperKit)
    }

    @Test("Diarization is deferred in both V1 engines")
    func diarizationDeferred() {
        // §30: architected for, not shipped. The V2 path is Parakeet via FluidAudio.
        #expect(!AppleSpeechEngine().capabilities.supportsDiarization)
        #expect(!WhisperKitEngine().capabilities.supportsDiarization)
    }

    @Test("Default concurrency is 1")
    func concurrencyDefault() {
        // Neural Engine inference is a serialized hardware resource; more in flight
        // usually buys contention, not throughput. Phase 2 sets this from measurement.
        #expect(TranscriptionOptions.default.concurrency == 1)
    }

    @Test("Concurrency and attempts are floored at 1")
    func optionFloors() {
        let o = TranscriptionOptions(concurrency: 0, maxAttemptsPerChunk: 0)
        #expect(o.concurrency == 1)
        #expect(o.maxAttemptsPerChunk == 1)
    }

    @Test("Engines announce their unimplemented state")
    func placeholders() async {
        for engine in [AppleSpeechEngine() as any TranscriptionEngine, WhisperKitEngine()] {
            await #expect(throws: VoxVerbaError.self) {
                try await engine.prepare(locale: "en-US")
            }
            await #expect(throws: VoxVerbaError.self) {
                try await engine.transcribe(SampleRange(start: 0, count: 16_000),
                                            in: URL(filePath: "/dev/null"),
                                            options: .default)
            }
        }
    }

    @Test("Merger announces its unimplemented state")
    func merger() {
        let plan = ChunkPlan(chunks: [], parameters: .default, parameterHash: "x")
        let map = SilenceMap(speechRegions: [], gaps: [], noiseFloorProfile: [],
                             parameters: .default, parameterHash: "x", sourceDuration: .seconds(1))
        #expect(throws: VoxVerbaError.self) {
            try TranscriptMerger().merge(chunks: [], plan: plan, silenceMap: map,
                                         provenance: Provenance())
        }
    }
}
