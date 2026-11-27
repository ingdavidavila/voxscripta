import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaFFI

/// That the wire carries what ``WarningSummary`` decided, faithfully.
///
/// The aggregating and the ordering are tested in `WarningSummaryTests`, where
/// they live. What can only go wrong here is the encoding.
@Suite("Warning wire")
struct WarningWireTests {

    private func segment(_ start: Double, _ warnings: [SegmentWarning]) -> TranscriptSegment {
        var s = TranscriptSegment(originalStart: .seconds(start),
                                  originalEnd: .seconds(start + 2),
                                  text: "A sentence.", words: [], confidence: 0.9)
        s.warnings = warnings
        return s
    }

    private func json(_ transcript: Transcript) throws -> String {
        let encoded = try JSONEncoder().encode(Wire.warningsForTesting(in: transcript))
        return String(decoding: encoded, as: UTF8.self)
    }

    @Test("Numbers stay numbers")
    func numbersAreNotPreFormatted() throws {
        // A Spanish interface writes 0,42 where an English one writes 0.42.
        // Pre-formatting in the engine would decide that for both.
        let text = try json(Transcript(
            variant: .clean, segments: [segment(0, [.lowConfidence(0.42)])],
            provenance: Provenance()))
        #expect(!text.contains("\"0.42\""), "a number arrived as a string: \(text)")
        // And not 0.4199999868869781 either. The engine reports confidence as a
        // Float, and widening one to Double is where that comes from.
        #expect(text.contains("\"confidence\":0.42"), "\(text)")
    }

    @Test("A whole-transcript warning encodes a null position, not a zero")
    func wholeTranscriptEncodesNull() throws {
        let text = try json(Transcript(
            variant: .clean, segments: [segment(0, [])], provenance: Provenance(),
            notes: [.languageLooksWrong(transcribedAs: "en-US", detected: "es")]))
        #expect(text.contains("\"startSeconds\":null"), "\(text)")
        #expect(text.contains("\"wholeTranscript\":true"), "\(text)")
    }

    @Test("Values keep their names on the wire")
    func valuesKeepTheirNames() throws {
        let text = try json(Transcript(
            variant: .clean, segments: [segment(0, [])], provenance: Provenance(),
            notes: [.languageLooksWrong(transcribedAs: "en-US", detected: "es")]))
        #expect(text.contains("\"transcribedAs\":\"en-US\""), "\(text)")
        #expect(text.contains("\"detected\":\"es\""), "\(text)")
    }
}
