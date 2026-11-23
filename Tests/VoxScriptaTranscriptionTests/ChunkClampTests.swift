import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaTranscription

/// Whether a chunk's segments stay inside the chunk.
///
/// This exists because of a real failure, not a hypothetical one. On a
/// 15-minute recording the first chunk covered 0.00–242.86 s and Whisper
/// reported a segment ending at 243.32 s. The next chunk began at 242.86, so
/// the merged sequence went backwards, the merger's monotonicity check threw,
/// and the whole transcript failed — meaning no recording long enough to need
/// a second chunk could be transcribed at all.
@Suite("Chunk segment clamping")
struct ChunkClampTests {

    private func segment(_ start: Double, _ end: Double, _ text: String = "words here")
        -> TranscriptSegment {
        TranscriptSegment(originalStart: .seconds(start), originalEnd: .seconds(end),
                          text: text)
    }

    private let chunk = TimeRange(start: .seconds(100), end: .seconds(200))

    @Test("A segment that overshoots the chunk end is pulled back to it")
    func overshootIsClamped() {
        // The measured case, to the millisecond.
        let range = TimeRange(start: .zero, end: .seconds(242.86))
        let out = ChunkScheduler.clamped([segment(240, 243.32)], to: range)
        #expect(out.count == 1)
        #expect(out[0].originalEnd == .seconds(242.86))
        #expect(out[0].originalStart == .seconds(240), "the start was fine and must not move")
    }

    @Test("A segment already inside the chunk is untouched")
    func insideIsUnchanged() {
        let original = [segment(110, 120), segment(130, 150)]
        let out = ChunkScheduler.clamped(original, to: chunk)
        #expect(out == original, "clamping must be a no-op on valid input")
    }

    @Test("A segment starting before the chunk is pulled forward")
    func undershootIsClamped() {
        let out = ChunkScheduler.clamped([segment(95, 150)], to: chunk)
        #expect(out[0].originalStart == .seconds(100))
        #expect(out[0].originalEnd == .seconds(150))
    }

    @Test("Nothing is ever dropped, however wrong the timestamps")
    func textSurvives() {
        // The engine heard only this chunk's audio, so the words came from
        // inside it whatever its clock says. Dropping the segment would turn a
        // timing error into missing words, which is the worse failure and the
        // harder one to notice.
        let out = ChunkScheduler.clamped(
            [segment(300, 400, "entirely past the end"),
             segment(10, 20, "entirely before the start")],
            to: chunk)
        #expect(out.count == 2, "clamping must not discard segments")
        #expect(out.map(\.text) == ["entirely past the end", "entirely before the start"])
    }

    @Test("Clamping never inverts a segment")
    func neverInverted() {
        // A zero-length segment at a boundary is acceptable; one that ends
        // before it starts would break every ordering check downstream.
        for (start, end) in [(300.0, 400.0), (10.0, 20.0), (190.0, 250.0), (50.0, 500.0)] {
            let out = ChunkScheduler.clamped([segment(start, end)], to: chunk)
            #expect(out[0].originalEnd >= out[0].originalStart,
                    "\(start)…\(end) clamped to an inverted span")
            #expect(out[0].originalStart >= chunk.start)
            #expect(out[0].originalEnd <= chunk.end)
        }
    }

    @Test("Clamped chunks abut without overlapping, which is what the merger needs")
    func adjacentChunksDoNotOverlap() {
        // The property the bug violated, stated directly: given two chunks that
        // meet at a boundary, no clamped segment of the first can end after any
        // clamped segment of the second begins.
        let first = TimeRange(start: .zero, end: .seconds(242.86))
        let second = TimeRange(start: .seconds(242.86), end: .seconds(481.52))

        let a = ChunkScheduler.clamped([segment(240, 243.32)], to: first)
        let b = ChunkScheduler.clamped([segment(242.86, 250)], to: second)

        #expect(a.last!.originalEnd <= b.first!.originalStart,
                "\(a.last!.originalEnd.seconds) ends after \(b.first!.originalStart.seconds) begins")
    }
}
