import Foundation

/// A position or span on an audio timeline, stored exactly.
///
/// Audio timing is stored in integer nanoseconds rather than `Double` seconds.
/// A six-hour recording is roughly 2.16 × 10¹³ ns, comfortably inside `Int64`,
/// and integer storage means accumulating thousands of chunk offsets introduces
/// no drift. Floating-point seconds are available via ``seconds`` for display
/// and for interop with AVFoundation, but they are never the stored form.
///
/// - Important: A `MediaTime` carries no indication of *which* timeline it sits
///   on. VoxScripta maintains two — original and processed — and the invariant is
///   that persisted artifacts store original time only. See `SilenceMap` for the
///   mapping between them.
public struct MediaTime: Hashable, Sendable, Codable, Comparable {
    /// Exact position in nanoseconds.
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    /// Creates a time from floating-point seconds, rounding to the nearest nanosecond.
    public init(seconds: Double) {
        precondition(seconds.isFinite, "MediaTime requires a finite value")
        self.nanoseconds = Int64((seconds * 1_000_000_000).rounded())
    }

    /// Creates a time from a sample index at a given rate.
    ///
    /// The multiplication is performed in `Int64` before division so that the
    /// result is exact for every rate that divides evenly into a nanosecond
    /// count — which includes every rate VoxScripta canonicalizes to.
    public init(samples: Int64, sampleRate: Int) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.nanoseconds = samples * 1_000_000_000 / Int64(sampleRate)
    }

    /// The time as floating-point seconds. For display and framework interop only.
    public var seconds: Double { Double(nanoseconds) / 1_000_000_000 }

    /// The sample index this time corresponds to at `sampleRate`, truncated toward zero.
    public func samples(at sampleRate: Int) -> Int64 {
        precondition(sampleRate > 0, "sampleRate must be positive")
        return nanoseconds * Int64(sampleRate) / 1_000_000_000
    }

    public static let zero = MediaTime(nanoseconds: 0)

    public static func seconds(_ v: Double) -> MediaTime { MediaTime(seconds: v) }
    public static func milliseconds(_ v: Double) -> MediaTime { MediaTime(seconds: v / 1000) }

    public static func < (a: MediaTime, b: MediaTime) -> Bool { a.nanoseconds < b.nanoseconds }
    public static func + (a: MediaTime, b: MediaTime) -> MediaTime { .init(nanoseconds: a.nanoseconds + b.nanoseconds) }
    public static func - (a: MediaTime, b: MediaTime) -> MediaTime { .init(nanoseconds: a.nanoseconds - b.nanoseconds) }
    public static func * (a: MediaTime, k: Double) -> MediaTime { .init(nanoseconds: Int64((Double(a.nanoseconds) * k).rounded())) }

    /// The larger of two times.
    public static func max(_ a: MediaTime, _ b: MediaTime) -> MediaTime { a > b ? a : b }
    /// The smaller of two times.
    public static func min(_ a: MediaTime, _ b: MediaTime) -> MediaTime { a < b ? a : b }

    /// Clamped to a closed range.
    public func clamped(to r: ClosedRange<MediaTime>) -> MediaTime {
        self < r.lowerBound ? r.lowerBound : (self > r.upperBound ? r.upperBound : self)
    }
}

extension MediaTime: CustomStringConvertible {
    /// Formats as `h:mm:ss.mmm`, or `m:ss.mmm` under an hour. Negative times keep a leading sign.
    public var description: String {
        let negative = nanoseconds < 0
        let total = abs(nanoseconds)
        let ms = total / 1_000_000 % 1000
        let s = total / 1_000_000_000 % 60
        let m = total / 60_000_000_000 % 60
        let h = total / 3_600_000_000_000
        let sign = negative ? "-" : ""
        return h > 0
            ? String(format: "%@%d:%02d:%02d.%03d", sign, h, m, s, ms)
            : String(format: "%@%d:%02d.%03d", sign, m, s, ms)
    }
}
