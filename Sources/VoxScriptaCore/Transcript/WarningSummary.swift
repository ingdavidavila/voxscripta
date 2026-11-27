import Foundation

/// One kind of warning on a transcript, with however many times it occurred.
public struct AggregatedWarning: Hashable, Sendable {
    /// The occurrence worth naming. See ``WarningSummary/aggregate(_:)``.
    public let warning: SegmentWarning
    public let count: Int
    /// Where the first occurrence is, or `nil` for a whole-transcript warning,
    /// which has no position at all.
    public let startSeconds: Double?

    public init(warning: SegmentWarning, count: Int, startSeconds: Double?) {
        self.warning = warning
        self.count = count
        self.startSeconds = startSeconds
    }
}

/// Everything the pipeline noticed about a transcript, in the order a reader
/// should be told it.
///
/// ## Why this is in the engine
///
/// Three callers need this list: the C ABI, for the Flutter banner; the SwiftUI
/// app, for its own; and anything later that reports on a transcript. The
/// aggregating, the ordering and the choice of which occurrence an aggregate
/// describes are all rules, and a second implementation of a rule is a second
/// answer waiting to disagree with the first — the same reason `wordCount`
/// lives on ``Transcript`` rather than being counted by each interface.
///
/// It also decides nothing about wording. Engine-side localization cannot work
/// off Apple, because `String(localized:)` is shimmed to the identity function
/// and the shim is reached only after interpolation, so the lookup key is
/// destroyed before any table could be consulted. Each interface words these
/// from its own catalogue, keyed by ``SegmentWarning/code``.
public enum WarningSummary {

    /// Every warning on a transcript, aggregated by code, most serious first.
    ///
    /// Reads both homes, because they hold different claims: ``Transcript/notes``
    /// is about the recording and a segment's `warnings` is about that segment.
    /// Reading only one of them is how the wrong-language note went missing
    /// from CLEAN in the first place.
    public static func aggregate(_ transcript: Transcript) -> [AggregatedWarning] {
        // Keyed by code, not by the case with its values in it. Grouping on the
        // whole case looks right and is not: `lowConfidence(0.42)` and
        // `lowConfidence(0.55)` are different values of the same enum, so
        // thirty doubtful segments would arrive as up to thirty entries of
        // count 1 — the opposite of aggregating them.
        var grouped: [String: AggregatedWarning] = [:]

        func record(_ warning: SegmentWarning, start: Double?) {
            guard let held = grouped[warning.code] else {
                grouped[warning.code] = AggregatedWarning(
                    warning: warning, count: 1, startSeconds: start)
                return
            }
            grouped[warning.code] = AggregatedWarning(
                warning: moreNotable(held.warning, warning),
                count: held.count + 1,
                startSeconds: [held.startSeconds, start].compactMap { $0 }.min())
        }

        for note in transcript.notes { record(note, start: nil) }
        for segment in transcript.segments {
            for warning in segment.warnings {
                record(warning, start: segment.originalStart.seconds)
            }
        }

        return grouped.values
            // Severity first, then the code, so two warnings of equal severity
            // come out in the same order every time. A dictionary's order is
            // not stable, and a banner that reshuffles between two reads of the
            // same project looks broken.
            .sorted { ($0.warning.severity, $0.warning.code)
                        < ($1.warning.severity, $1.warning.code) }
            .map {
                // A whole-transcript warning rides on no segment, so it has no
                // position. Reporting 0 would have an interface say "at 0:00"
                // about something that happened nowhere in particular.
                $0.warning.describesWholeTranscript
                    ? AggregatedWarning(warning: $0.warning, count: $0.count,
                                        startSeconds: nil)
                    : $0
            }
    }

    /// The most serious warning on a transcript, or `nil` when there is none.
    ///
    /// What a one-line banner shows. Separate from ``aggregate(_:)`` so that an
    /// interface showing one line and an interface showing a list cannot
    /// disagree about which one is the headline.
    public static func headline(_ transcript: Transcript) -> AggregatedWarning? {
        aggregate(transcript).first
    }

    /// Which of two warnings of the same code an aggregate should carry.
    ///
    /// An aggregate has one set of values and several occurrences, so it has to
    /// say which occurrence it is describing. The worst one, because a banner
    /// reporting the mildest of thirty understates what happened: lowest
    /// confidence for `lowConfidence`, and otherwise the one already held,
    /// which is the first in document order.
    static func moreNotable(_ held: SegmentWarning,
                            _ candidate: SegmentWarning) -> SegmentWarning {
        if case .lowConfidence(let a) = held, case .lowConfidence(let b) = candidate {
            return b < a ? candidate : held
        }
        return held
    }
}
