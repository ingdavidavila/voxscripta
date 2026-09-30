import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaLanguage

/// A clean transcript of independent sentences.
func cleanTranscript(_ texts: [String]) -> Transcript {
    var segments: [TranscriptSegment] = []
    for (index, text) in texts.enumerated() {
        let start = MediaTime.seconds(Double(index) * 3)
        segments.append(TranscriptSegment(
            originalStart: start, originalEnd: start + .seconds(2.5), text: text,
            words: text.split(separator: " ").enumerated().map { i, w in
                Word(text: String(w), originalStart: start + .seconds(Double(i) * 0.2),
                     originalEnd: start + .seconds(Double(i) * 0.2 + 0.18))
            }))
    }
    return Transcript(variant: .clean, segments: segments, provenance: Provenance())
}

@Suite("Polish processor")
struct PolishProcessorTests {

    private let sentences = [
        "We sold 500 units in the third quarter.",
        "We did not approve the revised budget.",
        "It might be possible to finish by Friday.",
    ]

    @Test("Unchanged output is accepted")
    func echoAccepted() async throws {
        let host = MockLanguageModelHost(behaviour: .echo)
        try await host.load()
        let result = try await PolishProcessor().process(
            clean: cleanTranscript(sentences), parameters: .default, host: host)

        #expect(result.sentences.count == 3)
        #expect(result.count(.accepted) == 3)
        #expect(result.rejectionRate == 0)
        #expect(result.transcript.variant == .polished)
    }

    @Test("One sentence per call, so nothing can be merged or shifted")
    func oneSentencePerCall() async throws {
        let host = MockLanguageModelHost(behaviour: .echo)
        try await host.load()
        _ = try await PolishProcessor().process(
            clean: cleanTranscript(sentences), parameters: .default, host: host)
        #expect(await host.callCount == 3)
    }

    @Test("Surrounding sentences are supplied as read-only context")
    func providesContext() async throws {
        let host = MockLanguageModelHost(behaviour: .echo)
        try await host.load()
        _ = try await PolishProcessor().process(
            clean: cleanTranscript(sentences), parameters: .default, host: host)

        let contexts = await host.contextsSeen
        #expect(contexts.count == 3)
        #expect(contexts[0].preceding.isEmpty)
        #expect(!contexts[0].following.isEmpty)
        #expect(!contexts[1].preceding.isEmpty)
        #expect(contexts[2].following.isEmpty)
    }

    @Test("A rejected window is retried with its violations named")
    func retriesWithViolations() async throws {
        let host = MockLanguageModelHost(behaviour: .failFirstThenEcho)
        try await host.load()
        let result = try await PolishProcessor().process(
            clean: cleanTranscript([sentences[0]]), parameters: .default, host: host)

        #expect(await host.callCount == 2)
        #expect(result.count(.acceptedAfterRetry) == 1)

        // The retry must say what went wrong; a bare "try again" produces the
        // same output.
        let retryInstructions = await host.instructionsSeen[1]
        #expect(retryInstructions.contains("rejected"))
        #expect(retryInstructions.lowercased().contains("900")
                || retryInstructions.lowercased().contains("number"))
    }

    @Test("A twice-rejected sentence keeps the clean text and is flagged")
    func fallsBackAndFlags() async throws {
        // Invents a number every time — the numeric check must never let it pass.
        let host = MockLanguageModelHost(
            behaviour: .alwaysCorrupt { $0 + " Revenue rose 40 percent." })
        try await host.load()
        let clean = cleanTranscript([sentences[0]])
        let result = try await PolishProcessor().process(
            clean: clean, parameters: .default, host: host)

        #expect(result.count(.fellBackToClean) == 1)
        #expect(result.fallbackRate == 1)
        // The surviving text is the clean text, unchanged.
        #expect(result.transcript.segments[0].text == sentences[0])
        // And the segment says so.
        let flagged = result.transcript.segments[0].warnings.contains {
            if case .polishFellBack = $0 { return true }
            return false
        }
        #expect(flagged)
    }

    @Test("An unavailable model leaves a complete clean transcript")
    func modelUnavailable() async throws {
        // Polish is an enhancement. A model that cannot run must not fail a job
        // whose transcription already succeeded.
        let host = MockLanguageModelHost(behaviour: .unavailable)
        let result = try await PolishProcessor().process(
            clean: cleanTranscript(sentences), parameters: .default, host: host)

        #expect(result.count(.modelFailed) == 3)
        #expect(result.transcript.segments.map(\.text) == sentences)
    }

    @Test("Numbers, names and negations survive a corrupting model")
    func protectsFacts() async throws {
        let corruptions: [(String, @Sendable (String) -> String)] = [
            ("number", { $0.replacingOccurrences(of: "500", with: "1,000") }),
            ("negation", { $0.replacingOccurrences(of: "did not approve", with: "approved") }),
            ("hedge", { $0.replacingOccurrences(of: "might be", with: "is") }),
        ]
        for (name, corrupt) in corruptions {
            let host = MockLanguageModelHost(behaviour: .alwaysCorrupt(corrupt))
            try await host.load()
            let result = try await PolishProcessor().process(
                clean: cleanTranscript(sentences), parameters: .default, host: host)

            // Whatever the model did, the transcript still says what was said.
            for (index, original) in sentences.enumerated() where corrupt(original) != original {
                #expect(result.transcript.segments[index].text == original,
                        "\(name) corruption reached the transcript")
            }
        }
    }

    @Test("Word timings are dropped only where text was rewritten")
    func timingsDroppedOnlyWhenChanged() async throws {
        let host = MockLanguageModelHost(behaviour: .transform { $0 == "We did not approve the revised budget." ? "We did not approve the revised budget, no." : $0 })
        try await host.load()
        let result = try await PolishProcessor().process(
            clean: cleanTranscript(sentences), parameters: .default, host: host)

        // Unchanged sentences keep their word-level timing for subtitle export.
        #expect(!result.transcript.segments[0].words.isEmpty)
        // A rewritten one drops it, because the words no longer describe the text.
        let rewritten = result.transcript.segments[1]
        if rewritten.text != sentences[1] { #expect(rewritten.words.isEmpty) }
        // Segment spans always survive, so timing is never lost entirely.
        #expect(result.transcript.segments.allSatisfy { $0.originalEnd > $0.originalStart })
        #expect(result.transcript.isMonotonic)
    }

    @Test("Provenance records the model and the prompt version")
    func recordsProvenance() async throws {
        let host = MockLanguageModelHost(behaviour: .echo)
        try await host.load()
        let result = try await PolishProcessor().process(
            clean: cleanTranscript(sentences), parameters: .default, host: host)

        // Two runs of "the same" pipeline are only comparable if the transcript
        // says which prompt produced it.
        #expect(result.transcript.provenance.promptVersion == PolishPrompt.version)
        #expect(result.transcript.provenance.modelID == .systemDefault)
    }

    @Test("An empty transcript is returned untouched")
    func emptyTranscript() async throws {
        let host = MockLanguageModelHost(behaviour: .echo)
        let result = try await PolishProcessor().process(
            clean: Transcript(variant: .clean, segments: [], provenance: Provenance()),
            parameters: .default, host: host)
        #expect(result.sentences.isEmpty)
        #expect(await host.callCount == 0)
    }
}
