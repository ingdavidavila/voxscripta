import Testing
import Foundation
@testable import VoxScriptaCore

@Suite("Identifiers")
struct IdentifierTests {

    @Test("Tagged IDs encode as bare UUID strings")
    func encoding() throws {
        let id = ChunkID()
        let data = try JSONEncoder().encode(id)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == "\"\(id.rawValue.uuidString)\"")
        #expect(try JSONDecoder().decode(ChunkID.self, from: data) == id)
    }

    @Test("Fresh IDs are distinct")
    func distinct() {
        #expect(Set((0..<1000).map { _ in SegmentID() }).count == 1000)
    }
}

@Suite("Error taxonomy")
struct ErrorTests {

    @Test("Retryable errors are the transient ones")
    func retryable() {
        #expect(VoxScriptaError.ioFailure(path: "/x", reason: "busy").isRetryable)
        #expect(VoxScriptaError.transcriptionFailed(chunk: ChunkID(), reason: "timeout").isRetryable)
        #expect(!VoxScriptaError.unsupportedFormat(description: "bad").isRetryable)
        #expect(!VoxScriptaError.cancelled.isRetryable)
        // Retrying a placeholder would spin forever without ever succeeding.
        #expect(!VoxScriptaError.notImplemented("x").isRetryable)
    }

    @Test("Only whole-job problems are fatal to the job")
    func fatal() {
        #expect(VoxScriptaError.sourceUnavailable(path: "/x").isFatalToJob)
        #expect(VoxScriptaError.insufficientDiskSpace(needed: 10, available: 1).isFatalToJob)
        // One bad chunk must not fail a 200-chunk lecture.
        #expect(!VoxScriptaError.transcriptionFailed(chunk: ChunkID(), reason: "x").isFatalToJob)
    }

    @Test("Every case has a user-facing message")
    func messages() {
        let cases: [VoxScriptaError] = [
            .sourceUnavailable(path: "/a"), .sourceChanged(path: "/a"),
            .unsupportedFormat(description: "x"), .decodingFailed(reason: "x"),
            .analysisFailed(stage: "s", reason: "x"), .noSpeechDetected,
            .engineUnavailable(.appleSpeech, reason: "x"),
            .localeUnsupported(.appleSpeech, locale: "xx"),
            .transcriptionFailed(chunk: ChunkID(), reason: "x"),
            .modelAssetMissing(description: "x"),
            .modelUnavailable(.systemDefault, reason: "x"),
            .contextWindowExceeded(tokens: 5000, limit: 4096),
            .validationRejected(reasons: ["numbers"]),
            .projectCorrupt(reason: "x"), .schemaTooNew(found: 2, supported: 1),
            .insufficientDiskSpace(needed: 2, available: 1),
            .ioFailure(path: "/a", reason: "x"), .cancelled, .notImplemented("x"),
        ]
        for c in cases {
            let message = c.errorDescription
            #expect(message?.isEmpty == false)
        }
    }
}

@Suite("Transcript model")
struct TranscriptTests {

    private func segment(_ start: Double, _ end: Double, _ text: String, gap: Double? = nil) -> TranscriptSegment {
        TranscriptSegment(
            originalStart: .seconds(start),
            originalEnd: .seconds(end),
            text: text,
            precedingGap: gap.map { MediaTime.seconds($0) }
        )
    }

    @Test("Monotonicity detects out-of-order segments")
    func monotonic() {
        let good = Transcript(
            variant: .verbatim,
            segments: [segment(0, 5, "one"), segment(5, 10, "two"), segment(12, 15, "three")],
            provenance: Provenance()
        )
        #expect(good.isMonotonic)

        let bad = Transcript(
            variant: .verbatim,
            segments: [segment(0, 10, "one"), segment(5, 15, "two")],
            provenance: Provenance()
        )
        #expect(!bad.isMonotonic)
    }

    @Test("Paragraph breaks come from measured pauses, not guesses")
    func paragraphsFromPauses() {
        // The §7 example: a five-second pause must not collapse into one sentence.
        let t = Transcript(
            variant: .verbatim,
            segments: [
                segment(0, 1, "Hello..."),
                segment(6, 8, "...my name is David.", gap: 5),
            ],
            provenance: Provenance()
        )
        let text = t.plainText()
        #expect(text.contains("\n\n"))
        #expect(text == "Hello...\n\n...my name is David.")
    }

    @Test("A short gap keeps segments on one line")
    func shortGapJoins() {
        let t = Transcript(
            variant: .verbatim,
            segments: [segment(0, 1, "One."), segment(1.2, 2, "Two.", gap: 0.2)],
            provenance: Provenance()
        )
        #expect(t.plainText() == "One. Two.")
    }

    @Test("Speaker slot exists and defaults to nil for V1")
    func speakerSlotReserved() {
        // §30: diarization is deferred, but the field ships now so adding it later
        // populates something the exports already understand.
        let s = segment(0, 1, "Hello.")
        #expect(s.speaker == nil)
        var withSpeaker = s
        withSpeaker.speaker = SpeakerID()
        #expect(withSpeaker.speaker != nil)
    }

    @Test("Transcript round-trips through JSON")
    func codable() throws {
        let t = Transcript(
            variant: .clean,
            segments: [
                TranscriptSegment(
                    originalStart: .seconds(1), originalEnd: .seconds(2),
                    text: "Hello.",
                    words: [Word(text: "Hello", originalStart: .seconds(1), originalEnd: .seconds(1.5), confidence: 0.9)],
                    warnings: [.lowConfidence(0.4)]
                )
            ],
            provenance: Provenance(engineID: .appleSpeech)
        )
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(back.variant == .clean)
        #expect(back.segments.count == 1)
        #expect(back.wordCount == 1)
        #expect(back.segments[0].warnings == [.lowConfidence(0.4)])
        #expect(back.provenance.engineID == .appleSpeech)
    }
}

@Suite("Chunk model")
struct ChunkModelTests {

    @Test("Only hard cuts require overlap")
    func overlapRule() {
        #expect(BoundaryKind.hardCut.requiresOverlap)
        #expect(!BoundaryKind.silence(gapDuration: .seconds(1)).requiresOverlap)
        #expect(!BoundaryKind.endOfMedia.requiresOverlap)
    }

    @Test("Canonical format byte accounting")
    func byteAccounting() {
        // Six hours of canonical audio: the figure the memory strategy is built on.
        let sixHours = MediaTime.seconds(6 * 3600)
        #expect(CanonicalFormat.byteCount(for: sixHours) == 6 * 3600 * 16_000 * 4)
        #expect(CanonicalFormat.byteCount(for: sixHours) == 1_382_400_000)
    }
}
