import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// The measurements the confidence floor is set from, kept as a test.
///
/// The threshold is not a guess, it is a reading of two populations that do
/// not overlap. That only stays true while it is checked: if a future engine
/// scores real speech lower, or noise higher, the floor is wrong and this is
/// where it shows.
enum ConfidenceCorpus {
    struct Sample: Sendable {
        let confidence: Float
        let text: String
        /// Whether a person actually said this.
        let isSpeech: Bool
        let source: String
    }

    /// Every segment the app produced across six recordings, with its score.
    ///
    /// Five sources were read or spoken deliberately. The sixth was recorded
    /// in the app with the microphone open for several seconds before anyone
    /// spoke, which is the case the floor exists for and the only one that
    /// produced invented text.
    static let samples: [Sample] = [
        // ── Invented, from room tone. No one said any of this. ─────────────
        .init(confidence: 0.1100, text: "Why, sister, stop, stop.",
              isSpeech: false, source: "in-app recording, before speech"),
        .init(confidence: 0.1944, text: "George, you kill the state!",
              isSpeech: false, source: "in-app recording, before speech"),
        .init(confidence: 0.4650, text: "this.",
              isSpeech: false, source: "in-app recording, before speech"),
        .init(confidence: 0.4850, text: "talk to me.",
              isSpeech: false, source: "in-app recording, before speech"),
        .init(confidence: 0.5800, text: "Serantella!",
              isSpeech: false, source: "in-app recording, before speech"),

        // ── Real speech, lowest scorers from each source ────────────────────
        .init(confidence: 0.8168, text: "Um, we did not approve it.",
              isSpeech: true, source: "conversational, mumbled"),
        .init(confidence: 0.8491, text: "Ah, so I think we should, um, start on Monday.",
              isSpeech: true, source: "conversational"),
        .init(confidence: 0.8725, text: "The quick brown fox jumps over the lazy dog.",
              isSpeech: true, source: "read aloud"),
        .init(confidence: 0.8748, text: "Twilight, and evening bell, and after that, the dark.",
              isSpeech: true, source: "poetry, read aloud"),
        .init(confidence: 0.8862, text: "Time will never stop, and so do you.",
              isSpeech: true, source: "spoken word"),
        .init(confidence: 0.9197, text: "Ahí van a tener que hacer para poder robar el tren.",
              isSpeech: true, source: "Spanish monologue"),
        .init(confidence: 0.9502, text: "This is a test of the recorder running on a Mac.",
              isSpeech: true, source: "in-app recording, spoken"),
        .init(confidence: 0.9768, text: "The quick brown fox jumps over the lazy dog.",
              isSpeech: true, source: "in-app recording, spoken"),
    ]

    static var invented: [Sample] { samples.filter { !$0.isSpeech } }
    static var speech: [Sample] { samples.filter(\.isSpeech) }
}

@Suite("Confidence floor")
struct ConfidenceFloorTests {

    private func transcript(_ rows: [(String, Float)]) -> Transcript {
        let segments = rows.enumerated().map { index, row in
            TranscriptSegment(
                originalStart: .seconds(Double(index) * 4),
                originalEnd: .seconds(Double(index) * 4 + 3),
                text: row.0,
                words: [],
                confidence: row.1)
        }
        return Transcript(variant: .verbatim, segments: segments, provenance: Provenance())
    }

    private var floor: Double { CleanParameters.defaultConfidenceFloor }

    // MARK: - The measurement the threshold rests on

    @Test("The two populations do not overlap")
    func populationsSeparate() {
        let worstSpeech = ConfidenceCorpus.speech.map(\.confidence).min()!
        let bestInvented = ConfidenceCorpus.invented.map(\.confidence).max()!
        #expect(bestInvented < worstSpeech,
                "invented text now scores as high as real speech; the floor is unsound")
    }

    @Test("The default floor sits inside the empty band, nearer the noise")
    func floorIsInTheBand() {
        let worstSpeech = Double(ConfidenceCorpus.speech.map(\.confidence).min()!)
        let bestInvented = Double(ConfidenceCorpus.invented.map(\.confidence).max()!)
        #expect(floor > bestInvented)
        #expect(floor < worstSpeech)
        // Biased towards keeping speech: losing a real sentence is worse than
        // keeping a false one, because only one of the two is recoverable by
        // reading.
        #expect(floor - bestInvented < worstSpeech - floor)
    }

    @Test("Every measured sample is classified correctly")
    func corpusIsSortedCorrectly() {
        let result = try! CleanProcessor().process(
            verbatim: transcript(ConfidenceCorpus.samples.map { ($0.text, $0.confidence) }),
            parameters: .default)
        let kept = Set(result.transcript.segments.map {
            TextTokenizer.tokens($0.text).joined(separator: " ")
        })

        for sample in ConfidenceCorpus.samples {
            let key = TextTokenizer.tokens(sample.text).joined(separator: " ")
            #expect(kept.contains(key) == sample.isSpeech,
                    "\(sample.source) @ \(sample.confidence): “\(sample.text)”")
        }
        #expect(result.segmentsDropped == ConfidenceCorpus.invented.count)
    }

    // MARK: - Behaviour

    @Test("A dropped segment is logged with its score, not silently removed")
    func dropsAreAudited() {
        let result = try! CleanProcessor().process(
            verbatim: transcript([("George, you kill the state!", 0.1944),
                                  ("This is a real sentence that was said.", 0.95)]),
            parameters: .default)

        let drops = result.edits(of: .lowConfidenceDropped)
        #expect(drops.count == 1)
        #expect(drops.first?.original == "George, you kill the state!")
        // The evidence has to be in the log, or "unsure" is just an assertion.
        #expect(drops.first?.replacement.contains("0.1944") == true)
        #expect(drops.first?.replacement.contains("0.65") == true)
        #expect(drops.first?.at == .zero)
    }

    @Test("Turning the floor off keeps everything")
    func floorIsOptional() {
        var parameters = CleanParameters.default
        parameters.confidenceFloor = nil
        let result = try! CleanProcessor().process(
            verbatim: transcript([("George, you kill the state!", 0.1944)]),
            parameters: parameters)
        #expect(result.transcript.segments.count == 1)
        #expect(result.segmentsDropped == 0)
    }

    @Test("The conservative preset deletes nothing, including whole segments")
    func conservativeKeepsEverything() {
        #expect(CleanParameters.conservative.confidenceFloor == nil)
        let result = try! CleanProcessor().process(
            verbatim: transcript([("this.", 0.465)]),
            parameters: .conservative)
        #expect(result.transcript.segments.count == 1)
    }

    @Test("A segment with no confidence reported is kept")
    func unscoredSegmentsSurvive() {
        // An engine that reports no confidence must not have its whole
        // transcript discarded on the strength of a missing number.
        let segment = TranscriptSegment(originalStart: .zero, originalEnd: .seconds(3),
                                        text: "No score was reported for this.",
                                        words: [], confidence: nil)
        let result = try! CleanProcessor().process(
            verbatim: Transcript(variant: .verbatim, segments: [segment],
                                 provenance: Provenance()),
            parameters: .default)
        #expect(result.transcript.segments.count == 1)
        #expect(result.segmentsDropped == 0)
    }

    @Test("A score exactly at the floor is kept")
    func floorIsInclusive() {
        let result = try! CleanProcessor().process(
            verbatim: transcript([("Exactly at the threshold, so it stays.", Float(0.65))]),
            parameters: .default)
        #expect(result.transcript.segments.count == 1)
    }

    @Test("The verbatim transcript handed in is not modified")
    func verbatimIsUntouched() {
        // CLEAN produces a second transcript; it does not edit the first.
        // The dropped text has to remain readable somewhere.
        let original = transcript([("George, you kill the state!", 0.1944),
                                   ("A real sentence.", 0.95)])
        _ = try! CleanProcessor().process(verbatim: original, parameters: .default)
        #expect(original.segments.count == 2)
        #expect(original.segments[0].text == "George, you kill the state!")
    }
}
