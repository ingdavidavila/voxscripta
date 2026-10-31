import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaBench
import VoxScriptaTestSupport
@testable import VoxScriptaTranscription

/// whisper.cpp, run against the same audio the Apple engine is measured on.
///
/// The point of this engine is the platforms Apple's does not reach, so the
/// question that matters is not whether it links — it is whether it produces a
/// transcript good enough to put the rest of the pipeline on top of. That is a
/// word error rate against a known reference, measured the same way, on the
/// same passages.
///
/// Skipped when no model is present. The model is 145 MB and is fetched by
/// `Tools/fetch-whisper-model.sh`, so it is deliberately not in the repository
/// and these tests must not fail on a machine that has not fetched it.
@Suite("Whisper engine")
struct WhisperEngineTests {

    private var modelIsAvailable: Bool {
        FileManager.default.fileExists(atPath: WhisperEngine.defaultModelURL().path)
    }

    /// Runs `body` with a prepared engine and always releases it.
    ///
    /// Not `defer { Task { await engine.release() } }`, which is what the
    /// Apple engine's tests do and what this file did first. That spawns work
    /// nothing waits for, so `whisper_free` never ran, and ggml's Metal device
    /// hit `GGML_ASSERT([rsets->data count] == 0)` in a static destructor at
    /// process exit — every test passing and the run still failing, with a
    /// signal instead of a message.
    private func withEngine<T>(locale: String = "en-US",
                               _ body: (WhisperEngine) async throws -> T) async throws -> T {
        let engine = WhisperEngine()
        try await engine.prepare(locale: locale)
        do {
            let result = try await body(engine)
            await engine.release()
            return result
        } catch {
            await engine.release()
            throw error
        }
    }

    // MARK: - Things that need no model

    @Test("It announces itself as a distinct engine")
    func identity() async {
        let engine = WhisperEngine()
        #expect(engine.identifier == .whisper)
        #expect(engine.identifier != .appleSpeech)
        let caps = await engine.capabilities()
        #expect(caps.supportsWordTimestamps)
        // The reason it exists: Apple covers about thirty locales.
        #expect(caps.supportedLocales.count > 30)
        #expect(caps.supportedLocales.contains("es-ES"))
    }

    @Test("A locale it cannot do is refused before any work")
    func refusesUnknownLocale() async {
        let engine = WhisperEngine()
        await #expect(throws: VoxScriptaError.self) {
            try await engine.prepare(locale: "xx-XX")
        }
    }

    @Test("Locales reduce to the language code Whisper expects")
    func localeMapping() {
        #expect(WhisperEngine.whisperLanguage(for: "en-US") == "en")
        #expect(WhisperEngine.whisperLanguage(for: "es-419") == "es")
        #expect(WhisperEngine.whisperLanguage(for: "PT-br") == "pt")
        #expect(WhisperEngine.whisperLanguage(for: "de") == "de")
    }

    @Test("A missing model is reported as a missing asset, not a crash")
    func missingModel() async {
        let engine = WhisperEngine(
            modelURL: URL(filePath: "/nonexistent/ggml-base.bin"))
        await #expect(throws: VoxScriptaError.self) {
            try await engine.prepare(locale: "en-US")
        }
    }

    @Test("Reading the canonical file returns the samples asked for")
    func readsCanonicalSpan() throws {
        // The canonical file has no header and one fixed format, so this is
        // arithmetic — which is exactly why it ports.
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "c.f32")
        let samples = (0..<1000).map { Float($0) }
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: url)

        let span = try WhisperEngine.readSamples(SampleRange(start: 100, count: 50), from: url)
        #expect(span.count == 50)
        #expect(span.first == 100)
        #expect(span.last == 149)
    }

    // MARK: - The measurement

    @Test("It transcribes real speech at a usable word error rate")
    func wordErrorRate() async throws {
        try #require(modelIsAvailable,
                     "no model — run Tools/fetch-whisper-model.sh")

        let passages = Array(SpeechCorpus.standard.prefix(3))
        let tmp = try TempDirectory()
        let rendered = try await SpeechCorpus.render(passages)
        let wav = tmp.url.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: rendered, to: wav, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        let canonical = tmp.url.appending(path: "canonical.f32")
        let written = try await CanonicalDecoder().decode(url: wav, to: canonical) { _ in }

        let segments = try await withEngine { engine in
            var options = TranscriptionOptions.default
            options.locale = "en-US"
            return try await engine.transcribe(
                SampleRange(start: 0, count: written), in: canonical, options: options)
        }

        let text = segments.map(\.text).joined(separator: " ")
        let reference = SpeechCorpus.referenceText(for: passages)
        let result = WordErrorRate.measure(reference: reference, hypothesis: text)
        print("WHISPER WER \(String(format: "%.2f", result.rate * 100))%  "
              + "(S \(result.substitutions)  D \(result.deletions)  I \(result.insertions))")
        print("WHISPER TEXT: \(text)")

        #expect(!segments.isEmpty, "the engine returned nothing")
        // The Apple engine measures about 5.6% on this material. Whisper base
        // is a smaller model than Apple's, so the bar is set where a usable
        // transcript sits rather than at parity; a regression past this means
        // something is wrong with the wiring, not with the model.
        #expect(result.rate < 0.25, "word error rate \(result.rate)")
    }

    @Test("Segments carry timings on the recording's own timeline")
    func timingsAreOffset() async throws {
        try #require(modelIsAvailable,
                     "no model — run Tools/fetch-whisper-model.sh")

        let tmp = try TempDirectory()
        let rendered = try await SpeechCorpus.render(Array(SpeechCorpus.standard.prefix(1)))
        let wav = tmp.url.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: rendered, to: wav, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)
        let canonical = tmp.url.appending(path: "canonical.f32")
        let written = try await CanonicalDecoder().decode(url: wav, to: canonical) { _ in }

        // A span that does not start at zero, so an unshifted timeline shows up.
        let skip = Int64(CanonicalFormat.sampleRate)          // one second in
        let segments = try await withEngine { engine in
            var options = TranscriptionOptions.default
            options.locale = "en-US"
            return try await engine.transcribe(
                SampleRange(start: skip, count: written - skip), in: canonical, options: options)
        }

        try #require(!segments.isEmpty)
        let first = try #require(segments.first)
        #expect(first.originalStart >= MediaTime.seconds(1),
                "timings were not shifted to the recording's timeline")
        for segment in segments {
            #expect(segment.originalEnd >= segment.originalStart)
        }
    }
}
