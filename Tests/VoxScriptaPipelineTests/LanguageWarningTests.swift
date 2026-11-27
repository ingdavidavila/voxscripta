import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaTranscription
import VoxScriptaProject
import VoxScriptaTestSupport
@testable import VoxScriptaPipeline

/// That the acoustic mismatch warning reaches the transcript.
///
/// `LanguageMismatchTests` establishes the rule; this establishes the wiring,
/// which is the half that can be right in isolation and still never fire. The
/// defect it guards is the worst output this program can produce: with
/// detection off and a mismatched locale, whisper's decoder writes fluent text
/// in the language it was asked for rather than failing, so a VERBATIM
/// transcript can be a fluent record of words nobody said. Measured in both
/// directions on Windows and Linux.
///
/// A deterministic mock, not the model: the question is whether the runner
/// asks and whether the answer lands on the transcript.
@Suite("Language warning", .serialized)
struct LanguageWarningTests {

    private func makeProject(in tmp: borrowing TempDirectory,
                             locale: String) async throws -> Project {
        // Three voiced spans with pauses: enough speech for the probe's
        // twenty-second sample and few enough chunks to stay quick.
        var spans: [SignalSpan] = []
        for i in 0..<3 {
            let a = Double(i) * 32, b = a + 30
            spans.append(SignalSpan(kind: .voiced,
                                    range: TimeRange(start: .seconds(a), end: .seconds(b)),
                                    levelDB: -20))
            spans.append(SignalSpan(kind: .silence,
                                    range: TimeRange(start: .seconds(b), end: .seconds(a + 32)),
                                    levelDB: -62))
        }
        let samples = SignalSynthesizer().render(spans: spans)
        let audio = tmp.url.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: samples, to: audio, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        let decoder = platformDecoder()
        return try await ProjectStore().create(
            from: audio, at: tmp.url.appending(path: "p.voxscripta"),
            chunking: ChunkParameters.default, locale: locale,
            probe: { (try await decoder.probe(url: $0), try decoder.duration(of: $0)) })
    }

    /// Runs the pipeline with detection off, as the defect requires.
    private func warnings(
        head: [LanguageLikelihood], locale: String = "en-US"
    ) async throws -> [SegmentWarning] {
        let tmp = try TempDirectory()
        // On the project, not on the options: `JobRunner.resolved` overwrites
        // `transcription.locale` from the manifest, because a project's locale
        // belongs to the project. Setting it on the options looks like it
        // works and silently runs the default instead — which is how a test
        // passes for the wrong reason.
        let project = try await makeProject(in: tmp, locale: locale)
        let engine = MockTranscriptionEngine()
        await engine.setLanguageLikelihoods(head)

        var options = JobOptions()
        options.transcription.concurrency = 1
        // The whole point. With detection on, the runner would have changed
        // the locale instead of warning about it.
        options.transcription.detectLanguage = false
        // POLISH is irrelevant here and costs a model load.
        options.polish = nil

        let transcript = try await JobRunner(engineFactory: { engine },
                                             gate: EntitlementFixture.freshTrial())
            .run(project: project, options: options)
        return transcript.segments.first?.warnings ?? []
    }

    /// Only the notes the acoustic check could have produced.
    ///
    /// A text-based check runs beside it at merge time, and the mock's
    /// synthetic words read as Polish to NaturalLanguage — so every run of
    /// this suite carries a `detected: "pl"` note that has nothing to do with
    /// either the defect or the fix. Filtering by shipping language separates
    /// them honestly rather than by position: `identifyLanguage` reports only
    /// the locales the app ships, so a note naming anything else did not come
    /// from the language head. If NaturalLanguage ever did say "es" about this
    /// fixture, these tests would fail loudly rather than pass quietly, which
    /// is the right direction for the mistake to fall.
    private func acoustic(_ warnings: [SegmentWarning]) -> [SegmentWarning] {
        warnings.filter {
            guard case .languageLooksWrong(_, let detected) = $0 else { return false }
            return ShippingLanguages.languageCodes.contains(detected)
        }
    }

    @Test("Spanish-sounding audio transcribed as English is marked")
    func warnsOnMismatch() async throws {
        let found = try await warnings(head: [
            LanguageLikelihood(locale: "es-ES", probability: 0.9987),
            LanguageLikelihood(locale: "en-US", probability: 0.0006),
        ])
        #expect(acoustic(found) == [.languageLooksWrong(transcribedAs: "en-US", detected: "es")],
                "expected exactly one acoustic note, got \(found)")
    }

    @Test("Audio that sounds like the language asked for is not marked")
    func silentOnAgreement() async throws {
        let found = try await warnings(head: [
            LanguageLikelihood(locale: "en-US", probability: 0.9994),
            LanguageLikelihood(locale: "es-ES", probability: 0.0006),
        ])
        #expect(acoustic(found).isEmpty, "warned about audio it agreed with: \(found)")
    }

    @Test("An engine with no language head produces no warning")
    func silentWithoutAHead() async throws {
        // Apple's recogniser returns empty. A warning here would be invented
        // from nothing, and its absence must not be read as verification —
        // which is why the check reports `unchecked` rather than a pass.
        let found = try await warnings(head: [])
        #expect(acoustic(found).isEmpty, "invented a verdict from no evidence: \(found)")
    }

    @Test("A different region of the same language is not a mismatch")
    func quietOnRegion() async throws {
        // es-ES audio, asked for as es-MX. Whisper identifies languages, not
        // regions, and a note here would teach the user to ignore the one
        // that matters.
        let found = try await warnings(head: [
            LanguageLikelihood(locale: "es-ES", probability: 0.9987),
            LanguageLikelihood(locale: "en-US", probability: 0.0006),
        ], locale: "es-MX")
        #expect(acoustic(found).isEmpty, "warned about a region difference: \(found)")
    }
}
