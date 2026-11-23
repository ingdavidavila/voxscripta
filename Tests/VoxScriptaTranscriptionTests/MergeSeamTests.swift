import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaTranscription

/// The splice point, at unit speed.
///
/// Both bugs these cover were found by a 7-minute measurement on real audio,
/// which is too slow to guard them. The geometry that broke is small and exact,
/// so it is reproduced here directly: a word still being spoken across the cut,
/// and an engine reporting past the end of its own chunk.
///
/// Together they made every recording longer than about four minutes fail to
/// merge, which is to say fail entirely — the merger's monotonicity check threw
/// rather than shipping a corrupt transcript, so there was no bad output, just
/// no output.
@Suite("Merge seams")
struct MergeSeamTests {

    private func word(_ text: String, _ start: Double, _ end: Double) -> Word {
        Word(text: text, originalStart: .seconds(start), originalEnd: .seconds(end))
    }

    private func segment(_ chunkID: ChunkID, _ words: [Word]) -> TranscriptSegment {
        TranscriptSegment(
            chunkID: chunkID,
            originalStart: words.first!.originalStart,
            originalEnd: words.last!.originalEnd,
            text: words.map(\.text).joined(separator: " "),
            words: words)
    }

    /// Two chunks meeting at 300 s, the second overlapping the first by 3 s —
    /// the shape `ChunkPlanner` produces for a hard cut.
    private func hardCutPlan(_ a: ChunkID, _ b: ChunkID) -> ChunkPlan {
        ChunkPlan(
            chunks: [
                ChunkSpec(id: a, sequence: 0,
                          originalRange: TimeRange(start: .zero, end: .seconds(300)),
                          processedRange: TimeRange(start: .zero, end: .seconds(300)),
                          sampleRange: SampleRange(start: 0, count: 300 * 16_000),
                          boundaryKind: .hardCut),
                ChunkSpec(id: b, sequence: 1,
                          originalRange: TimeRange(start: .seconds(297), end: .seconds(600)),
                          processedRange: TimeRange(start: .seconds(297), end: .seconds(600)),
                          sampleRange: SampleRange(start: 297 * 16_000, count: 303 * 16_000),
                          boundaryKind: .hardCut,
                          overlapLead: .seconds(3)),
            ],
            parameters: .default, parameterHash: "seam-test")
    }

    private func emptySilenceMap() -> SilenceMap {
        SilenceMap(speechRegions: [], gaps: [], noiseFloorProfile: [],
                   parameters: .default, parameterHash: "seam-test",
                   sourceDuration: .seconds(600))
    }

    @Test("A word spoken across the splice does not drag the segment back before it")
    func straddlingWordDoesNotReopenTheSeam() throws {
        // The measured failure: chunk 0 ended at 300.000 and chunk 1's first
        // surviving segment began at 299.940, overlapping by 60 ms. The word
        // "continues" starts at 299.94 and ends at 300.30, so it is correctly
        // kept — it is still being spoken after the cut — but the segment must
        // begin at the cut, not at the word.
        let a = ChunkID(), b = ChunkID()
        let first = segment(a, [word("sentence", 296.98, 297.6),
                                word("that", 297.7, 298.2),
                                word("continues", 299.94, 300.0)])
        let second = segment(b, [word("continues", 299.94, 300.30),
                                 word("onward", 300.4, 301.42)])

        let transcript = try TranscriptMerger().merge(
            chunks: [ChunkTranscript(chunkID: a, sequence: 0, segments: [first],
                                     engineID: .whisper, processingDuration: 1),
                     ChunkTranscript(chunkID: b, sequence: 1, segments: [second],
                                     engineID: .whisper, processingDuration: 1)],
            plan: hardCutPlan(a, b), silenceMap: emptySilenceMap(),
            provenance: Provenance(engineID: .whisper))

        #expect(transcript.isMonotonic, "the seam reopened")
        for (left, right) in zip(transcript.segments, transcript.segments.dropFirst()) {
            #expect(left.originalEnd <= right.originalStart,
                    "\(left.originalEnd.seconds) overlaps \(right.originalStart.seconds)")
        }
    }

    @Test("The straddling word is kept, not dropped")
    func straddlingWordSurvives() throws {
        // Clamping the start rather than discarding the word is the whole
        // point: the word was really spoken, and turning a timing error into a
        // missing word would be the worse failure and the harder to notice.
        let a = ChunkID(), b = ChunkID()
        let first = segment(a, [word("the", 296.0, 296.5), word("word", 299.94, 300.0)])
        let second = segment(b, [word("onward", 300.4, 301.42)])

        let transcript = try TranscriptMerger().merge(
            chunks: [ChunkTranscript(chunkID: a, sequence: 0, segments: [first],
                                     engineID: .whisper, processingDuration: 1),
                     ChunkTranscript(chunkID: b, sequence: 1, segments: [second],
                                     engineID: .whisper, processingDuration: 1)],
            plan: hardCutPlan(a, b), silenceMap: emptySilenceMap(),
            provenance: Provenance(engineID: .whisper))

        let text = transcript.segments.flatMap(\.words).map(\.text)
        #expect(text.contains("onward"), "a word after the cut was lost: \(text)")
    }

    @Test("A failed ordering check names the offending pair")
    func theErrorSaysWhereItWentWrong() throws {
        // A soft cut: the chunks abut with no overlap, so the merger does not
        // deduplicate and has no opportunity to repair anything. If an engine
        // reports past the end of its own chunk here, nothing between it and
        // the ordering check will catch it — which is precisely why
        // `ChunkScheduler.clamped` exists upstream, and why this test asserts
        // the message rather than the absence of the failure.
        //
        // "Not in ascending order" on its own cost two measurement runs spent
        // guessing which of two causes was in play, so the message now carries
        // the geometry.
        let a = ChunkID(), b = ChunkID()
        let plan = ChunkPlan(
            chunks: [
                ChunkSpec(id: a, sequence: 0,
                          originalRange: TimeRange(start: .zero, end: .seconds(242.86)),
                          processedRange: TimeRange(start: .zero, end: .seconds(242.86)),
                          sampleRange: SampleRange(start: 0, count: 3_885_760),
                          boundaryKind: .silence(gapDuration: .seconds(1))),
                ChunkSpec(id: b, sequence: 1,
                          originalRange: TimeRange(start: .seconds(242.86), end: .seconds(480)),
                          processedRange: TimeRange(start: .seconds(242.86), end: .seconds(480)),
                          sampleRange: SampleRange(start: 3_885_760, count: 3_794_240),
                          boundaryKind: .silence(gapDuration: .seconds(1))),
            ],
            parameters: .default, parameterHash: "seam-test")

        // The measured overshoot: chunk 0 was handed audio ending at 242.86
        // and claimed a segment ending at 243.32.
        let first = segment(a, [word("over", 240.0, 243.32)])
        let second = segment(b, [word("shoot", 242.86, 244.0)])

        var thrown: (any Error)?
        do {
            _ = try TranscriptMerger().merge(
                chunks: [ChunkTranscript(chunkID: a, sequence: 0, segments: [first],
                                         engineID: .whisper, processingDuration: 1),
                         ChunkTranscript(chunkID: b, sequence: 1, segments: [second],
                                         engineID: .whisper, processingDuration: 1)],
                plan: plan, silenceMap: emptySilenceMap(),
                provenance: Provenance(engineID: .whisper))
        } catch { thrown = error }

        let message = thrown.map { String(describing: $0) } ?? ""
        #expect(thrown != nil, "an overshooting segment must not merge silently")
        #expect(message.contains("243.320"), "the message should name the end time: \(message)")
        #expect(message.contains("242.860"), "and the start it collides with: \(message)")
        #expect(message.contains("overlapping by"), "and by how much: \(message)")
    }

    @Test("The scheduler's clamp is what prevents the case above")
    func schedulerClampPreventsIt() {
        // Stated as a test so the dependency between the two is recorded: the
        // merger cannot repair a soft-cut overshoot, so something upstream has
        // to, and that is the scheduler.
        let range = TimeRange(start: .zero, end: .seconds(242.86))
        let clamped = ChunkScheduler.clamped([segment(ChunkID(), [word("over", 240.0, 243.32)])],
                                             to: range)
        #expect(clamped[0].originalEnd == .seconds(242.86))
    }
}
