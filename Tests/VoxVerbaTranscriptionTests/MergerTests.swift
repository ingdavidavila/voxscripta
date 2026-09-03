import Testing
import Foundation
import VoxVerbaCore
import VoxVerbaTestSupport
@testable import VoxVerbaTranscription

@Suite("Transcript merger")
struct TranscriptMergerTests {

    private func emptyMap(duration: Double) -> SilenceMap {
        SilenceMap(speechRegions: [SpeechRegion(
            range: TimeRange(start: .zero, end: .seconds(duration)),
            meanEnergyDB: -20, peakEnergyDB: -12)],
            gaps: [], noiseFloorProfile: [], parameters: .default,
            parameterHash: "t", sourceDuration: .seconds(duration))
    }

    private func words(_ texts: [String], from start: Double, step: Double = 0.5) -> [Word] {
        texts.enumerated().map { i, text in
            Word(text: text,
                 originalStart: .seconds(start + Double(i) * step),
                 originalEnd: .seconds(start + Double(i) * step + step * 0.8),
                 confidence: 0.9)
        }
    }

    private func segment(_ texts: [String], from start: Double, chunk: ChunkID) -> TranscriptSegment {
        let w = words(texts, from: start)
        return TranscriptSegment(
            chunkID: chunk,
            originalStart: w.first!.originalStart,
            originalEnd: w.last!.originalEnd,
            text: texts.joined(separator: " "),
            words: w)
    }

    @Test("Chunks merge in sequence order regardless of completion order")
    func ordersBySequence() async throws {
        let plan = makePlan(count: 4, seconds: 10)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)
        let outcome = try await ChunkScheduler().run(
            plan: plan, canonicalFile: URL(filePath: "/dev/null"),
            engine: engine, options: .default)

        // Feed the merger in deliberately scrambled order.
        let scrambled = [outcome.transcripts[2], outcome.transcripts[0],
                         outcome.transcripts[3], outcome.transcripts[1]]
        let transcript = try TranscriptMerger().merge(
            chunks: scrambled, plan: plan, silenceMap: emptyMap(duration: 40),
            provenance: Provenance())

        #expect(transcript.isMonotonic)
        let texts = transcript.segments.map(\.text)
        #expect(texts[0].hasPrefix("c0w0"))
        #expect(texts[1].hasPrefix("c1w0"))
        #expect(texts[3].hasPrefix("c3w0"))
    }

    @Test("Overlapping words after a hard cut appear exactly once")
    func deduplicatesOverlap() throws {
        let a = ChunkID(), b = ChunkID()
        // Chunk A ends "...bought some milk"; chunk B repeats "some milk" because
        // its audio began three seconds earlier.
        let first = segment(["i", "went", "to", "the", "store", "and", "bought", "some", "milk"],
                            from: 0, chunk: a)
        let second = segment(["some", "milk", "yesterday", "i", "also", "stopped"],
                             from: 3.5, chunk: b)

        let plan = ChunkPlan(chunks: [
            ChunkSpec(id: a, sequence: 0,
                      originalRange: TimeRange(start: .zero, end: .seconds(4.5)),
                      processedRange: TimeRange(start: .zero, end: .seconds(4.5)),
                      sampleRange: SampleRange(start: 0, count: 72_000),
                      boundaryKind: .hardCut),
            ChunkSpec(id: b, sequence: 1,
                      originalRange: TimeRange(start: .seconds(3.5), end: .seconds(7)),
                      processedRange: TimeRange(start: .seconds(3.5), end: .seconds(7)),
                      sampleRange: SampleRange(start: 56_000, count: 56_000),
                      boundaryKind: .endOfMedia,
                      overlapLead: .seconds(1)),
        ], parameters: .default, parameterHash: "t")

        let transcript = try TranscriptMerger().merge(
            chunks: [
                ChunkTranscript(chunkID: a, sequence: 0, segments: [first],
                                engineID: .mock, processingDuration: 0),
                ChunkTranscript(chunkID: b, sequence: 1, segments: [second],
                                engineID: .mock, processingDuration: 0),
            ],
            plan: plan, silenceMap: emptyMap(duration: 7), provenance: Provenance())

        let text = transcript.plainText()
        // The duplicated pair survives once, and the sentence reads continuously.
        #expect(text.contains("bought some milk yesterday"))
        #expect(text.components(separatedBy: "milk").count - 1 == 1)
        #expect(transcript.isMonotonic)
    }

    @Test("An ambiguous splice is flagged rather than hidden")
    func flagsAmbiguousMerge() throws {
        let a = ChunkID(), b = ChunkID()
        // No shared words at all, so no confident splice point exists.
        let first = segment(["alpha", "bravo", "charlie"], from: 0, chunk: a)
        let second = segment(["xray", "yankee", "zulu"], from: 1.0, chunk: b)

        let plan = ChunkPlan(chunks: [
            ChunkSpec(id: a, sequence: 0,
                      originalRange: TimeRange(start: .zero, end: .seconds(2)),
                      processedRange: TimeRange(start: .zero, end: .seconds(2)),
                      sampleRange: SampleRange(start: 0, count: 32_000),
                      boundaryKind: .hardCut),
            ChunkSpec(id: b, sequence: 1,
                      originalRange: TimeRange(start: .seconds(1), end: .seconds(3)),
                      processedRange: TimeRange(start: .seconds(1), end: .seconds(3)),
                      sampleRange: SampleRange(start: 16_000, count: 32_000),
                      boundaryKind: .endOfMedia, overlapLead: .seconds(1)),
        ], parameters: .default, parameterHash: "t")

        let transcript = try TranscriptMerger().merge(
            chunks: [
                ChunkTranscript(chunkID: a, sequence: 0, segments: [first],
                                engineID: .mock, processingDuration: 0),
                ChunkTranscript(chunkID: b, sequence: 1, segments: [second],
                                engineID: .mock, processingDuration: 0),
            ],
            plan: plan, silenceMap: emptyMap(duration: 3), provenance: Provenance())

        let flagged = transcript.segments.contains { $0.warnings.contains(.mergeAmbiguity) }
        #expect(flagged, "an unresolvable splice must be surfaced, not silently guessed")
    }

    @Test("A missing chunk leaves a visible gap in the right place")
    func gapMarkerForFailedChunk() async throws {
        let plan = makePlan(count: 5, seconds: 10)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)
        await engine.setBehaviour(.failAlways, forSequence: 2)

        let outcome = try await ChunkScheduler(retryBackoff: .milliseconds(1)).run(
            plan: plan, canonicalFile: URL(filePath: "/dev/null"),
            engine: engine, options: .default)
        let transcript = try TranscriptMerger().merge(
            chunks: outcome.transcripts, plan: plan,
            silenceMap: emptyMap(duration: 50), provenance: Provenance())

        let gaps = transcript.segments.filter { $0.warnings.contains(.transcriptionGap) }
        #expect(gaps.count == 1)
        #expect(gaps[0].originalStart == .seconds(20))
        #expect(gaps[0].originalEnd == .seconds(30))
        // The surrounding chunks are still present and in order.
        #expect(transcript.segments.count == 5)
        #expect(transcript.isMonotonic)
    }

    @Test("Pause durations between segments are measured and carried forward")
    func computesPrecedingGaps() throws {
        let a = ChunkID()
        // The §7 case: "Hello..." then five seconds then "...my name is David."
        let one = segment(["hello"], from: 0, chunk: a)
        let two = segment(["my", "name", "is", "david"], from: 6, chunk: a)

        let plan = ChunkPlan(chunks: [
            ChunkSpec(id: a, sequence: 0,
                      originalRange: TimeRange(start: .zero, end: .seconds(9)),
                      processedRange: TimeRange(start: .zero, end: .seconds(9)),
                      sampleRange: SampleRange(start: 0, count: 144_000),
                      boundaryKind: .endOfMedia),
        ], parameters: .default, parameterHash: "t")

        let transcript = try TranscriptMerger().merge(
            chunks: [ChunkTranscript(chunkID: a, sequence: 0, segments: [one, two],
                                     engineID: .mock, processingDuration: 0)],
            plan: plan, silenceMap: emptyMap(duration: 9), provenance: Provenance())

        #expect(transcript.segments.count == 2)
        let gap = transcript.segments[1].precedingGap
        #expect(gap != nil)
        #expect(gap! > .seconds(5))
        #expect(transcript.segments[1].startsParagraph(using: .default))
        #expect(transcript.plainText().contains("\n\n"))
    }

    @Test("Overlap matching needs corroboration, not a single word")
    func requiresTwoWordMatch() {
        let merger = TranscriptMerger()
        let previous = [Word(text: "the", originalStart: .seconds(1), originalEnd: .seconds(1.2))]
        let current = [Word(text: "the", originalStart: .seconds(1), originalEnd: .seconds(1.2))]
        // One common word is a coincidence in any English transcript.
        #expect(merger.longestOverlap(previous, current) == nil)

        let p2 = [Word(text: "some", originalStart: .seconds(1), originalEnd: .seconds(1.2)),
                  Word(text: "milk", originalStart: .seconds(1.5), originalEnd: .seconds(1.8))]
        let c2 = [Word(text: "Some", originalStart: .seconds(1), originalEnd: .seconds(1.2)),
                  Word(text: "milk.", originalStart: .seconds(1.5), originalEnd: .seconds(1.8))]
        // Case and punctuation must not defeat the match.
        #expect(merger.longestOverlap(p2, c2) == 2)
    }

    @Test("Words that match textually but not in time are rejected")
    func rejectsTimeMismatch() {
        let merger = TranscriptMerger(overlapSearchWords: 40, timestampTolerance: .seconds(1))
        let previous = [Word(text: "some", originalStart: .seconds(1), originalEnd: .seconds(1.2)),
                        Word(text: "milk", originalStart: .seconds(1.5), originalEnd: .seconds(1.8))]
        // The same phrase said again a minute later is not the same utterance.
        let current = [Word(text: "some", originalStart: .seconds(61), originalEnd: .seconds(61.2)),
                       Word(text: "milk", originalStart: .seconds(61.5), originalEnd: .seconds(61.8))]
        #expect(merger.longestOverlap(previous, current) == nil)
    }

    @Test("A full plan merges into one continuous transcript")
    func producesOneTranscript() async throws {
        // §15: chunking is an internal detail; the user gets one transcript.
        let plan = makePlan(count: 30, seconds: 10)
        let engine = MockTranscriptionEngine()
        await engine.register(plan: plan)
        let outcome = try await ChunkScheduler().run(
            plan: plan, canonicalFile: URL(filePath: "/dev/null"),
            engine: engine, options: .default)

        let transcript = try TranscriptMerger().merge(
            chunks: outcome.transcripts, plan: plan,
            silenceMap: emptyMap(duration: 300), provenance: Provenance(engineID: .mock))

        #expect(transcript.isMonotonic)
        #expect(transcript.wordCount == 30 * 20)
        #expect(transcript.timeRange?.start == .zero)
        #expect(transcript.timeRange?.end == .seconds(300))
    }
}
