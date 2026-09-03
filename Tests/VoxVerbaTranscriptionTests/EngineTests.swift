import Testing
import Foundation
import VoxVerbaCore
@testable import VoxVerbaTranscription

@Suite("Transcription engines")
struct EngineTests {

    @Test("Both shipped engines advertise word timestamps")
    func wordTimestamps() async {
        // The merger's overlap de-duplication and the polish validator both depend
        // on word-level timing, so an engine without it cannot be a default.
        #expect(await AppleSpeechEngine().capabilities().supportsWordTimestamps)
        #expect(await WhisperKitEngine().capabilities().supportsWordTimestamps)
    }

    @Test("Engine identities are distinct")
    func identities() {
        #expect(AppleSpeechEngine().identifier == .appleSpeech)
        #expect(WhisperKitEngine().identifier == .whisperKit)
        #expect(EngineID.appleSpeech != EngineID.whisperKit)
    }

    @Test("Diarization is deferred in both V1 engines")
    func diarizationDeferred() async {
        // §30: architected for, not shipped. The V2 path is Parakeet via FluidAudio.
        #expect(!(await AppleSpeechEngine().capabilities().supportsDiarization))
        #expect(!(await WhisperKitEngine().capabilities().supportsDiarization))
    }

    @Test("Default concurrency is 4, set from measurement")
    func concurrencyDefault() {
        // Measured on an M5: 4.74 s at 1, 2.72 s at 2, 2.14 s at 4, 1.99 s at 8,
        // regressing at 12. 4 captures all but 7% of the benefit at two-thirds
        // the memory of 8. The prediction that 1 would win was wrong.
        #expect(TranscriptionOptions.default.concurrency == 4)
    }

    @Test("Concurrency and attempts are floored at 1")
    func optionFloors() {
        let o = TranscriptionOptions(concurrency: 0, maxAttemptsPerChunk: 0)
        #expect(o.concurrency == 1)
        #expect(o.maxAttemptsPerChunk == 1)
    }

    @Test("The alternate engine is still a Phase 2.1 stub")
    func whisperKitPending() async {
        // The Apple engine is implemented; WhisperKit lands with the model
        // download path. Until then it must fail loudly rather than return empty.
        let engine = WhisperKitEngine()
        await #expect(throws: VoxVerbaError.self) {
            try await engine.prepare(locale: "en-US")
        }
        await #expect(throws: VoxVerbaError.self) {
            try await engine.transcribe(SampleRange(start: 0, count: 16_000),
                                        in: URL(filePath: "/dev/null"), options: .default)
        }
    }

    @Test("The Apple engine rejects an unsupported locale before doing work")
    func unsupportedLocale() async {
        let engine = AppleSpeechEngine()
        await #expect(throws: VoxVerbaError.localeUnsupported(.appleSpeech, locale: "xx-XX")) {
            try await engine.prepare(locale: "xx-XX")
        }
    }

    @Test("The Apple engine refuses to transcribe before preparation")
    func unpreparedEngine() async {
        let engine = AppleSpeechEngine()
        await #expect(throws: VoxVerbaError.self) {
            try await engine.transcribe(SampleRange(start: 0, count: 16_000),
                                        in: URL(filePath: "/dev/null"), options: .default)
        }
    }

}
