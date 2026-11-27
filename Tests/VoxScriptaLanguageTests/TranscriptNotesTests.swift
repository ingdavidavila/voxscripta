import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// Notes that describe the whole recording, and the two defects that put them
/// where they are.
///
/// The wrong-language note used to be appended to `segments[0].warnings`,
/// because `warnings` was the only place a warning could go. CLEAN then
/// deleted that segment for scoring below its confidence floor and the note
/// went with it — and on one real recording CLEAN dropped *every* segment and
/// handed back an empty transcript with no warning at all, while the
/// recognised speech sat in VERBATIM beside it.
///
/// The selection was not bad luck, which is why this suite exists rather than
/// a single regression test. Decoding speech against the wrong language is
/// what produces low confidence, so the note had been pinned to precisely the
/// segment that the condition it describes was most likely to remove. Found by
/// the Windows session running real audio in both directions on main.
@Suite("Transcript notes")
struct TranscriptNotesTests {

    private func verbatim(_ rows: [(String, Float)],
                          notes: [SegmentWarning] = []) -> Transcript {
        let segments = rows.enumerated().map { index, row in
            TranscriptSegment(
                originalStart: .seconds(Double(index) * 4),
                originalEnd: .seconds(Double(index) * 4 + 3),
                text: row.0, words: [], confidence: row.1)
        }
        return Transcript(variant: .verbatim, segments: segments,
                          provenance: Provenance(), notes: notes)
    }

    private var floor: Double { CleanParameters.defaultConfidenceFloor }

    private func clean(_ verbatim: Transcript) throws -> Transcript {
        try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                     silenceParameters: .default).transcript
    }

    /// Returns what it is given, so POLISH runs end to end without a model and
    /// the only thing under test is whether the notes came through.
    private actor PassThroughHost: LanguageModelHosting {
        nonisolated let configuration = LanguageModelConfiguration(backend: .mlx)
        func isReady() async -> Bool { true }
        func load() async throws {}
        func unload() async {}
        func rewrite(sentences: [String], context: PolishContext,
                     instructions: String,
                     language: TranscriptLanguage) async throws -> [String] {
            sentences
        }
    }

    // MARK: - The note survives the segment it used to live on

    @Test("A note outlives a segment dropped for low confidence")
    func noteSurvivesTheDrop() throws {
        // The exact shape the Windows session measured: seg0 scores 0.34, is
        // dropped, and a later segment of wrong-language text is kept. Before
        // this, CLEAN came out carrying no warning at all.
        let source = verbatim([("Primera frase.", 0.34), ("Segunda frase.", 0.91)],
                              notes: [.languageLooksWrong(transcribedAs: "en-US",
                                                          detected: "es")])
        let result = try clean(source)
        #expect(result.segments.count == 1, "the low-confidence segment should still go")
        #expect(result.notes.contains(.languageLooksWrong(transcribedAs: "en-US",
                                                         detected: "es")))
    }

    @Test("CLEAN never hands back an empty transcript when VERBATIM had one")
    func neverEmptiesANonEmptyTranscript() throws {
        // Measured case: Spanish audio asked for as en-US on the base model
        // scored 0.61 across the board. Every segment was dropped and the
        // default view was a blank page.
        let source = verbatim([("Uno.", 0.61), ("Dos.", 0.58), ("Tres.", 0.44)],
                              notes: [.languageLooksWrong(transcribedAs: "en-US",
                                                          detected: "es")])
        let result = try clean(source)
        #expect(result.segments.count == 3, "a blank CLEAN is the defect, not the fix")
        #expect(result.notes.contains(.cleanKeptAllBelowFloor(segments: 3, floor: floor)))
        #expect(result.notes.contains(.languageLooksWrong(transcribedAs: "en-US",
                                                          detected: "es")),
                "the reason it looked wrong must survive too")
    }

    @Test("Keeping them all withdraws the drop log that no longer happened")
    func keptSegmentsLeaveNoDropEdits() throws {
        // Otherwise the edit log says three segments were removed for low
        // confidence while all three are present, and the polish review screen
        // reads that log.
        let source = verbatim([("Uno.", 0.61), ("Dos.", 0.58)])
        let result = try CleanProcessor().process(verbatim: source, parameters: .default,
                                                  silenceParameters: .default)
        #expect(!result.edits.contains { $0.kind == .lowConfidenceDropped })
        #expect(result.transcript.segments.count == 2)
    }

    @Test("A partial drop is reported with its count")
    func partialDropIsCounted() throws {
        let source = verbatim([("Uno.", 0.31), ("Dos.", 0.92), ("Tres.", 0.40)])
        let result = try clean(source)
        #expect(result.segments.count == 1)
        #expect(result.notes.contains(.cleanRemovedLowConfidence(segments: 2, floor: floor)))
    }

    @Test("Nothing dropped means nothing claimed")
    func silentWhenNothingDropped() throws {
        let result = try clean(verbatim([("Uno.", 0.95), ("Dos.", 0.92)]))
        #expect(result.notes.isEmpty)
    }

    // MARK: - Carried, not re-derived

    @Test("POLISH carries the notes CLEAN carried")
    func polishCarriesNotes() async throws {
        // POLISH rewrites sentences, which is more reason to keep the note and
        // not less: the reader is further from the audio than ever.
        let cleaned = Transcript(
            variant: .clean,
            segments: [TranscriptSegment(originalStart: .zero, originalEnd: .seconds(3),
                                         text: "Una frase.", words: [], confidence: 0.9)],
            provenance: Provenance(),
            notes: [.languageLooksWrong(transcribedAs: "en-US", detected: "es")])
        let result = try await PolishProcessor().process(
            clean: cleaned, parameters: .default, host: PassThroughHost())
        #expect(result.transcript.notes == cleaned.notes)
    }

    // MARK: - The field joins the contract defaulted-empty

    @Test("A transcript written before notes existed still decodes")
    func oldTranscriptsDecode() throws {
        // Rule 6. Every project on disk predates this field, and a synthesised
        // decoder does not apply a default for a missing key — so this is the
        // test that the hand-written one exists and works.
        let old = """
        {"variant":"verbatim","segments":[],"provenance":{"engineID":"mock",\
        "silenceParameterHash":"a","chunkParameterHash":"b","concurrency":1,\
        "generatedAt":0,"appVersion":"1"}}
        """
        let decoded = try? JSONDecoder().decode(Transcript.self, from: Data(old.utf8))
        #expect(decoded != nil, "adding notes must not break every project on disk")
        #expect(decoded?.notes.isEmpty == true)
    }

    @Test("Notes survive a round trip")
    func notesRoundTrip() throws {
        let original = verbatim([("Uno.", 0.9)],
                                notes: [.languageLooksWrong(transcribedAs: "en-US",
                                                            detected: "es"),
                                        .cleanRemovedLowConfidence(segments: 2, floor: 0.65)])
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(back.notes == original.notes)
    }

    // MARK: - Which case goes where

    @Test("Per-segment cases are not transcript-wide")
    func perSegmentCasesAreNotWide() {
        for note in [SegmentWarning.mergeAmbiguity, .lowConfidence(0.3),
                     .transcriptionGap, .polishFellBack(reasons: ["x"]), .polishRetried] {
            #expect(!note.describesWholeTranscript, "\(note) is about one segment")
        }
    }

    @Test("Transcript-wide cases say so")
    func wideCasesSaySo() {
        for note in [SegmentWarning.languageLooksWrong(transcribedAs: "en-US", detected: "es"),
                     .fewWordsForSpeech(words: 3, speechSeconds: 90),
                     .cleanRemovedLowConfidence(segments: 1, floor: 0.65),
                     .cleanKeptAllBelowFloor(segments: 1, floor: 0.65)] {
            #expect(note.describesWholeTranscript, "\(note) is about the recording")
        }
    }
}
