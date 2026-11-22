import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaBench
import VoxScriptaTestSupport

/// Whether the harness reports what happened.
///
/// Tested with a stub transcript rather than a real engine, so these run
/// without a model and on any platform. What is under test is the reporting —
/// the arithmetic, the grouping, and the honesty of a run that could not cover
/// everything it was asked to.
@Suite("Corpus runner")
struct CorpusRunnerTests {

    private let runner = CorpusRunner(engineID: "stub", modelIdentity: "stub|0")

    private func aCase(_ name: String = "en_clean") -> TranscriptionCase {
        TranscriptionCorpus.named(name)!
    }

    @Test("A perfect transcript scores zero on both metrics")
    func perfectIsZero() {
        let c = aCase()
        let row = runner.score(c, hypothesis: c.referenceText,
                               audioSeconds: 30, wallSeconds: 3)
        #expect(row.wer.rate == 0)
        #expect(row.cer.rate == 0)
        #expect(row.realTimeFactor == 0.1)
    }

    @Test("A row carries everything it is grouped by")
    func rowsAreSelfDescribing() {
        // A row that needs its surroundings to be interpreted is useless in a
        // JSON file read next month, which is the only place these end up.
        let row = runner.score(aCase("es_hiss_12dB"), hypothesis: "nada",
                               audioSeconds: 10, wallSeconds: 1)
        #expect(row.engineID == "stub")
        #expect(row.modelIdentity == "stub|0")
        #expect(row.conditionSlug == "hiss_12dB")
        #expect(row.scoringLanguage == "spanish")
        #expect(row.mixedLanguage == false)
        #expect(!row.reference.isEmpty)
    }

    @Test("A mixed case is flagged on the row, not just in the corpus")
    func mixedIsFlaggedOnTheRow() {
        let row = runner.score(aCase("mixed_es_dominant"), hypothesis: "x",
                               audioSeconds: 10, wallSeconds: 1)
        #expect(row.mixedLanguage, "a reader must be able to see the number is approximate")
        #expect(row.scoringLanguage == "spanish", "scored under the majority language")
    }

    @Test("The aggregate is weighted by length, not an average of rates")
    func aggregateIsWeighted() {
        // The bug this prevents: a four-word case scoring 50% and a
        // thousand-word case scoring 2% averaging to 26%, which describes
        // neither recording.
        let short = runner.score(
            TranscriptionCase(name: "tiny", purpose: "a deliberately tiny case for weighting",
                              segments: [CorpusSegment(passages: [SpeechPassage(name: "t", text: "one two")],
                                                       voiceLanguage: "en-US",
                                                       scoringLanguage: .english)]),
            hypothesis: "", audioSeconds: 1, wallSeconds: 1)
        let long = runner.score(aCase("en_long_with_pauses"),
                                hypothesis: TranscriptionCorpus.named("en_long_with_pauses")!.referenceText,
                                audioSeconds: 300, wallSeconds: 30)

        let report = CorpusReport(rows: [short, long])
        #expect(short.wer.rate == 1.0, "the tiny case was transcribed as nothing")
        #expect(long.wer.rate == 0.0)
        // An unweighted mean would be 0.5. Weighted, the tiny case barely moves it.
        #expect(report.aggregateWER < 0.02,
                "aggregate \(report.aggregateWER) looks like a mean of rates, not a weighted rate")
    }

    @Test("Merge delta is the cost of chunking the same audio")
    func mergeDeltaIsTheDifference() {
        let c = aCase("en_long_gapless")
        let reference = c.referenceText
        // Chunked drops a word at the seam; whole does not. The delta should be
        // exactly what the seam cost, which is the measurement that has been
        // missing for the merger.
        let whole = runner.score(c, hypothesis: reference, path: "whole",
                                 audioSeconds: 300, wallSeconds: 30)
        var words = reference.split(separator: " ").map(String.init)
        words.remove(at: words.count / 2)
        let chunked = runner.score(c, hypothesis: words.joined(separator: " "),
                                   path: "chunked", audioSeconds: 300, wallSeconds: 20)

        let deltas = CorpusReport(rows: [whole, chunked]).mergeDeltas()
        #expect(deltas.count == 1)
        #expect(deltas[0].whole == 0)
        #expect(deltas[0].delta > 0, "losing a word at the seam must show as a positive delta")
        #expect(deltas[0].delta == chunked.wer.rate)
    }

    @Test("A case measured only one way produces no delta")
    func noDeltaWithoutBothPaths() {
        // Reporting a delta against a missing counterpart would be an invented
        // number, which is worse than a missing row.
        let only = runner.score(aCase(), hypothesis: "x", path: "whole",
                                audioSeconds: 10, wallSeconds: 1)
        #expect(CorpusReport(rows: [only]).mergeDeltas().isEmpty)
    }

    @Test("The table has a line per row and columns that line up")
    func tableIsReadable() {
        let rows = TranscriptionCorpus.smoke.map {
            runner.score($0, hypothesis: "something wrong", audioSeconds: 20, wallSeconds: 4)
        }
        let table = CorpusReport(rows: rows).table
        let lines = table.split(separator: "\n")
        // Header, rule, then one line per row.
        #expect(lines.count == rows.count + 2, "got \(lines.count) lines for \(rows.count) rows")
        // Every data line must be the same width, or the columns are decorative.
        let widths = Set(lines.dropFirst(2).map(\.count))
        #expect(widths.count == 1, "data lines have widths \(widths.sorted())")
    }

    @Test("An empty report says so instead of printing an empty table")
    func emptyReportIsExplicit() {
        let report = CorpusReport(rows: [])
        #expect(report.table == "no measurements")
        #expect(report.aggregateWER == 0)
    }

    @Test("Rows group by condition and by language")
    func groupingWorks() {
        let rows = TranscriptionCorpus.conditioned.map {
            runner.score($0, hypothesis: "x", audioSeconds: 20, wallSeconds: 2)
        }
        let report = CorpusReport(rows: rows)
        #expect(report.byCondition().count == TranscriptionCorpus.conditions.count)
        #expect(Set(report.byLanguage().keys) == ["english", "spanish"])
        // Each condition should hold exactly one row per language.
        for (slug, group) in report.byCondition() {
            #expect(group.count == 2, "\(slug) has \(group.count) rows, expected one per language")
        }
    }

    @Test("A report round-trips through JSON")
    func reportIsSerializable() throws {
        // The corpus is only a regression corpus if a run can be kept and
        // compared against a later one.
        let rows = TranscriptionCorpus.smoke.map {
            runner.score($0, hypothesis: "x", audioSeconds: 20, wallSeconds: 2)
        }
        let data = try CorpusReport(rows: rows).json()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(CorpusReport.self, from: data)
        #expect(restored.rows.count == rows.count)
        #expect(restored.rows.map(\.caseName) == rows.map(\.caseName))
        #expect(!restored.hardware.isEmpty, "a run must record what it ran on")
    }
}
