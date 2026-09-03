import Foundation
import VoxVerbaCore

/// Reassembles chunk transcripts into one continuous transcript (§15).
///
/// Chunking is an internal implementation detail; the user never sees it. The
/// merger orders results by ``ChunkSpec/sequence``, joins soft boundaries plainly,
/// and de-duplicates hard-cut overlaps by aligning word timestamps across the
/// overlapping span. Where alignment fails it splits at the nominal boundary and
/// records ``SegmentWarning/mergeAmbiguity`` rather than hiding the uncertainty.
///
/// Paragraph and section breaks come from the measured gaps in the `SilenceMap`,
/// which is how §7's pause semantics survive silence being skipped.
///
/// - Note: Phase 2 implements this.
public protocol TranscriptMerging: Sendable {
    func merge(
        chunks: [ChunkTranscript],
        plan: ChunkPlan,
        silenceMap: SilenceMap,
        provenance: Provenance
    ) throws -> Transcript
}

public struct TranscriptMerger: TranscriptMerging {
    /// Words compared on each side of a hard cut when searching for the splice point.
    public let overlapSearchWords: Int
    /// How far apart matched words may sit before the match is rejected.
    public let timestampTolerance: MediaTime

    public init(overlapSearchWords: Int = 40, timestampTolerance: MediaTime = .seconds(2)) {
        self.overlapSearchWords = overlapSearchWords
        self.timestampTolerance = timestampTolerance
    }

    public func merge(
        chunks: [ChunkTranscript],
        plan: ChunkPlan,
        silenceMap: SilenceMap,
        provenance: Provenance
    ) throws -> Transcript {
        let byID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.chunkID, $0) })

        var segments: [TranscriptSegment] = []

        // Walk the plan rather than the results, so a chunk that failed leaves a
        // visible gap in the right place instead of silently closing up.
        for spec in plan.chunks.sorted(by: { $0.sequence < $1.sequence }) {
            guard let chunk = byID[spec.id] else {
                segments.append(gapMarker(for: spec))
                continue
            }

            var incoming = chunk.segments.sorted { $0.originalStart < $1.originalStart }
            guard !incoming.isEmpty else { continue }

            if spec.overlapLead > .zero, !segments.isEmpty {
                incoming = deduplicate(incoming, against: segments, overlapStart: spec.originalRange.start)
            }
            segments.append(contentsOf: incoming)
        }

        // Pause durations between consecutive segments drive paragraph and
        // section breaks (§7). They are measured, not guessed.
        for index in segments.indices.dropFirst() {
            let gap = segments[index].originalStart - segments[index - 1].originalEnd
            segments[index].precedingGap = gap > .zero ? gap : .zero
        }

        let transcript = Transcript(variant: .verbatim, segments: segments, provenance: provenance)

        // Ordering is the merger's core contract; a violation here would corrupt
        // every downstream export, so it fails loudly rather than shipping.
        guard transcript.isMonotonic else {
            throw VoxVerbaError.analysisFailed(
                stage: "transcript merge",
                reason: "merged segments are not in ascending time order")
        }
        return transcript
    }

    // MARK: - Overlap de-duplication

    /// Drops the leading words of `incoming` that repeat the tail of `existing`.
    ///
    /// Finds the longest suffix of the previous chunk's words that is also a
    /// prefix of this chunk's words, comparing normalized text and requiring the
    /// timestamps to agree. When no such run exists the splice falls back to a
    /// time cut and the first surviving segment is flagged `mergeAmbiguity` —
    /// surfacing the uncertainty rather than hiding it.
    func deduplicate(
        _ incoming: [TranscriptSegment],
        against existing: [TranscriptSegment],
        overlapStart: MediaTime
    ) -> [TranscriptSegment] {
        let previousTail = Array(existing.flatMap(\.words)
            .filter { $0.originalStart >= overlapStart }
            .suffix(overlapSearchWords))
        let incomingWords = Array(incoming.flatMap(\.words).prefix(overlapSearchWords))

        guard !previousTail.isEmpty, !incomingWords.isEmpty else {
            return trimByTime(incoming, before: existing.last?.originalEnd ?? overlapStart)
        }

        if let matched = longestOverlap(previousTail, incomingWords) {
            let cutoff = incomingWords[matched - 1].originalEnd
            return trimByTime(incoming, before: cutoff)
        }

        // No confident splice point. Cut by time and mark it.
        var trimmed = trimByTime(incoming, before: existing.last?.originalEnd ?? overlapStart)
        if !trimmed.isEmpty {
            trimmed[0].warnings.append(.mergeAmbiguity)
        }
        return trimmed
    }

    /// Length of the longest suffix of `previous` that is a prefix of `current`.
    func longestOverlap(_ previous: [Word], _ current: [Word]) -> Int? {
        let maxRun = Swift.min(previous.count, current.count)
        var best: Int?
        // Longer runs are stronger evidence, so search downward and take the first.
        for run in stride(from: maxRun, through: 1, by: -1) {
            let tail = previous.suffix(run)
            let head = current.prefix(run)
            let textMatches = zip(tail, head).allSatisfy {
                Self.normalize($0.text) == Self.normalize($1.text)
            }
            guard textMatches else { continue }
            let timesAgree = zip(tail, head).allSatisfy {
                abs(($0.originalStart - $1.originalStart).seconds) <= timestampTolerance.seconds
            }
            // A single matching word is a coincidence; two or more is a match.
            if textMatches && timesAgree && run >= 2 {
                best = run
                break
            }
        }
        return best
    }

    /// Removes words and segments that end at or before `time`.
    private func trimByTime(_ segments: [TranscriptSegment], before time: MediaTime) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for var segment in segments {
            let kept = segment.words.filter { $0.originalEnd > time }
            if kept.count == segment.words.count {
                out.append(segment)
                continue
            }
            guard !kept.isEmpty else { continue }
            segment.words = kept
            segment.text = kept.map(\.text).joined(separator: " ")
            segment.originalStart = kept[0].originalStart
            out.append(segment)
        }
        return out
    }

    /// A visible placeholder for a chunk that could not be transcribed.
    private func gapMarker(for spec: ChunkSpec) -> TranscriptSegment {
        TranscriptSegment(
            chunkID: spec.id,
            originalStart: spec.originalRange.start,
            originalEnd: spec.originalRange.end,
            text: "",
            words: [],
            warnings: [.transcriptionGap]
        )
    }

    /// Case- and punctuation-insensitive comparison key.
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
