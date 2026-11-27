import Testing
import Foundation
@testable import VoxScriptaCore

/// The list every interface is given, and in what order.
///
/// Both interfaces word these from their own catalogues — engine-side wording
/// cannot work off Apple, because `String(localized:)` is shimmed to identity
/// and the shim is reached after interpolation, so the lookup key is already
/// destroyed. The engine therefore has to get the *structure* right: a stable
/// code, values keyed by name, one entry per kind, and an order neither
/// interface chooses.
///
/// Tested here rather than at the C boundary because this is where the rule
/// is. `WarningWireTests` checks only that the JSON carries it faithfully.
@Suite("Warning summary")
struct WarningSummaryTests {

    private func segment(_ start: Double, _ warnings: [SegmentWarning],
                         text: String = "A sentence.") -> TranscriptSegment {
        var s = TranscriptSegment(originalStart: .seconds(start),
                                  originalEnd: .seconds(start + 2),
                                  text: text, words: [], confidence: 0.9)
        s.warnings = warnings
        return s
    }

    private func transcript(_ segments: [TranscriptSegment],
                            notes: [SegmentWarning] = [],
                            variant: TranscriptVariant = .clean) -> Transcript {
        Transcript(variant: variant, segments: segments,
                   provenance: Provenance(), notes: notes)
    }

    private func wire(_ transcript: Transcript) -> [AggregatedWarning] {
        WarningSummary.aggregate(transcript)
    }

    // MARK: - Aggregation

    @Test("Thirty doubtful segments are one entry with a count")
    func aggregatesByCode() {
        // The whole point of aggregating. Grouping on the enum case *with its
        // values* would have produced up to thirty entries of count one,
        // because lowConfidence(0.42) and lowConfidence(0.55) are different
        // values of the same case. That is the bug this test exists for.
        let segments = (0..<30).map {
            segment(Double($0) * 3, [.lowConfidence(Float(0.30 + Double($0) * 0.01))])
        }
        let entries = wire(transcript(segments))
        #expect(entries.count == 1)
        #expect(entries[0].warning.code == "lowConfidence")
        #expect(entries[0].count == 30)
    }

    @Test("An aggregate reports the worst occurrence, not the mildest")
    func aggregateCarriesTheWorst() {
        // A banner saying "confidence 0.64" about a transcript whose worst
        // segment scored 0.11 understates it. The lowest is the one worth
        // naming.
        let entries = wire(transcript([
            segment(0, [.lowConfidence(0.64)]),
            segment(3, [.lowConfidence(0.11)]),
            segment(6, [.lowConfidence(0.52)]),
        ]))
        #expect(entries.count == 1)
        guard case .number(let worst)? = entries[0].warning.values["confidence"] else {
            Issue.record("no confidence in \(entries[0].warning.values)")
            return
        }
        #expect(abs(worst - 0.11) < 0.001)
    }

    @Test("The first occurrence is where a per-segment entry points")
    func startsAtTheFirstOccurrence() {
        let entries = wire(transcript([
            segment(12, [.mergeAmbiguity]),
            segment(40, [.mergeAmbiguity]),
        ]))
        #expect(entries[0].startSeconds == 12)
    }

    // MARK: - Whole-transcript entries have no position

    @Test("A whole-transcript entry sends no start time")
    func wholeTranscriptHasNoStart() {
        // It rides on no segment at all now. Sending 0 would have a banner say
        // "at 0:00" about something with no position.
        let entries = wire(transcript(
            [segment(0, [])],
            notes: [.languageLooksWrong(transcribedAs: "en-US", detected: "es")]))
        #expect(entries.count == 1)
        #expect(entries[0].warning.describesWholeTranscript)
        #expect(entries[0].startSeconds == nil)
    }

    @Test("Both homes are read")
    func readsNotesAndSegmentWarnings() {
        // Reading only one of them is how the wrong-language note went missing
        // from CLEAN in the first place.
        let entries = wire(transcript(
            [segment(0, [.mergeAmbiguity])],
            notes: [.languageLooksWrong(transcribedAs: "en-US", detected: "es")]))
        #expect(Set(entries.map(\.warning.code)) == ["languageLooksWrong", "mergeAmbiguity"])
    }

    // MARK: - Order

    @Test("Missing words outrank doubtful words")
    func severityOrder() {
        // The Windows session's rule, and the reason the order is engine-side:
        // if each interface ranked these, a banner would say different things
        // on a phone and a laptop about the same recording.
        let entries = wire(transcript(
            [segment(0, [.lowConfidence(0.3), .mergeAmbiguity, .transcriptionGap])],
            notes: [.cleanRemovedLowConfidence(segments: 2, floor: 0.65),
                    .fewWordsForSpeech(words: 4, speechSeconds: 120),
                    .languageLooksWrong(transcribedAs: "en-US", detected: "es")]))
        #expect(entries.map(\.warning.code) == [
            "languageLooksWrong", "fewWordsForSpeech", "transcriptionGap",
            "cleanRemovedLowConfidence", "mergeAmbiguity", "lowConfidence",
        ])
    }

    @Test("The order does not change between reads")
    func orderIsStable() {
        // Built from a dictionary, whose order is not stable. A banner that
        // reshuffles between two reads of the same project looks broken.
        let source = transcript(
            [segment(0, [.mergeAmbiguity]), segment(3, [.polishRetried])],
            notes: [.fewWordsForSpeech(words: 4, speechSeconds: 120)])
        let first = wire(source).map(\.warning.code)
        for _ in 0..<20 {
            #expect(wire(source).map(\.warning.code) == first)
        }
    }

    // MARK: - Values

    @Test("Values are keyed by the case's own labels")
    func valuesAreNamed() {
        let entries = wire(transcript(
            [segment(0, [])],
            notes: [.languageLooksWrong(transcribedAs: "en-US", detected: "es")]))
        #expect(entries[0].warning.values["transcribedAs"] == .text("en-US"))
        #expect(entries[0].warning.values["detected"] == .text("es"))
    }

    @Test("Every case has a code, and no two share one")
    func codesAreUniqueAndTotal() {
        let all: [SegmentWarning] = [
            .mergeAmbiguity, .lowConfidence(0.5), .transcriptionGap,
            .polishFellBack(reasons: ["a"]), .polishRetried,
            .languageLooksWrong(transcribedAs: "en-US", detected: "es"),
            .fewWordsForSpeech(words: 1, speechSeconds: 2),
            .cleanRemovedLowConfidence(segments: 1, floor: 0.65),
            .cleanKeptAllBelowFloor(segments: 1, floor: 0.65),
        ]
        #expect(Set(all.map(\.code)).count == all.count)
        #expect(Set(all.map(\.severity)).count == all.count,
                "two cases share a severity, so their order is arbitrary")
    }
}
