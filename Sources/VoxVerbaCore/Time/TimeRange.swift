import Foundation

/// A half-open span `[start, end)` on an audio timeline.
///
/// Half-open is deliberate: adjacent ranges that share an endpoint do not
/// overlap, so a chunk plan can tile a recording exactly with no double-counted
/// sample and no gap.
public struct TimeRange: Hashable, Sendable, Codable {
    public let start: MediaTime
    public let end: MediaTime

    public init(start: MediaTime, end: MediaTime) {
        precondition(start <= end, "TimeRange requires start <= end (got \(start) > \(end))")
        self.start = start
        self.end = end
    }

    public init(start: MediaTime, duration: MediaTime) {
        self.init(start: start, end: start + duration)
    }

    public var duration: MediaTime { end - start }
    public var isEmpty: Bool { start == end }

    public func contains(_ t: MediaTime) -> Bool { t >= start && t < end }
    public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }

    /// The overlapping span, or `nil` when the ranges are disjoint or merely touch.
    public func intersection(_ other: TimeRange) -> TimeRange? {
        let lo = MediaTime.max(start, other.start)
        let hi = MediaTime.min(end, other.end)
        return lo < hi ? TimeRange(start: lo, end: hi) : nil
    }

    /// Expanded by `lead` before the start and `trail` after the end, clamped to `limit`.
    ///
    /// Used for the asymmetric speech padding in the silence detector, where
    /// trailing padding is larger than leading because word-final decay outlasts
    /// word-initial onset.
    public func padded(lead: MediaTime, trail: MediaTime, within limit: TimeRange) -> TimeRange {
        TimeRange(
            start: MediaTime.max(start - lead, limit.start),
            end: MediaTime.min(end + trail, limit.end)
        )
    }
}

extension TimeRange: CustomStringConvertible {
    public var description: String { "[\(start) → \(end)]" }
}

/// A half-open span of sample indices into a canonical PCM buffer.
///
/// This is what a "chunk" actually is at the storage layer: a view into the
/// single memory-mapped `canonical.f32`, not a separate audio file.
public struct SampleRange: Hashable, Sendable, Codable {
    public let start: Int64
    public let count: Int64

    public init(start: Int64, count: Int64) {
        precondition(start >= 0, "sample start must be non-negative")
        precondition(count >= 0, "sample count must be non-negative")
        self.start = start
        self.count = count
    }

    public var end: Int64 { start + count }
    public var isEmpty: Bool { count == 0 }

    /// The byte span this range occupies in a 32-bit float PCM file.
    public var byteRange: Range<Int> { Int(start) * 4 ..< Int(end) * 4 }

    public func timeRange(at sampleRate: Int) -> TimeRange {
        TimeRange(
            start: MediaTime(samples: start, sampleRate: sampleRate),
            end: MediaTime(samples: end, sampleRate: sampleRate)
        )
    }
}
