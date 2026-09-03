import Foundation

/// Tunable parameters for the five-stage silence detector.
///
/// Every value here is user-facing (§29) and every value participates in
/// ``parameterHash``, so changing one invalidates the silence map and everything
/// downstream of it — but never the expensive canonical decode.
public struct SilenceParameters: Hashable, Sendable, Codable {
    /// How far above the tracked noise floor a frame must sit to *leave* silence.
    public var marginDB: Float
    /// Additional level required to *enter* speech. This is the hysteresis band.
    public var hysteresisDB: Float
    /// Threshold floor, so a near-silent studio recording does not chase dither.
    public var absoluteFloorDB: Float
    /// Speech runs shorter than this are demoted to silence (removes clicks).
    public var minSpeechDuration: MediaTime
    /// Silence runs shorter than this are promoted to speech (protects stop closures).
    public var minSilenceDuration: MediaTime
    /// Padding added before a speech region.
    public var padLead: MediaTime
    /// Padding added after a speech region. Larger than `padLead` by design.
    public var padTrail: MediaTime
    /// Gaps at least this long become paragraph breaks in the merged transcript.
    public var paragraphPauseThreshold: MediaTime
    /// Gaps at least this long become section breaks.
    public var sectionPauseThreshold: MediaTime
    /// Whether to hold low-energy frames that look like unvoiced fricatives.
    public var fricativeProtection: Bool

    public init(
        marginDB: Float = 8,
        hysteresisDB: Float = 4,
        absoluteFloorDB: Float = -65,
        minSpeechDuration: MediaTime = .milliseconds(200),
        minSilenceDuration: MediaTime = .milliseconds(500),
        padLead: MediaTime = .milliseconds(200),
        padTrail: MediaTime = .milliseconds(350),
        paragraphPauseThreshold: MediaTime = .milliseconds(1500),
        sectionPauseThreshold: MediaTime = .seconds(4),
        fricativeProtection: Bool = true
    ) {
        self.marginDB = marginDB
        self.hysteresisDB = hysteresisDB
        self.absoluteFloorDB = absoluteFloorDB
        self.minSpeechDuration = minSpeechDuration
        self.minSilenceDuration = minSilenceDuration
        self.padLead = padLead
        self.padTrail = padTrail
        self.paragraphPauseThreshold = paragraphPauseThreshold
        self.sectionPauseThreshold = sectionPauseThreshold
        self.fricativeProtection = fricativeProtection
    }

    public static let `default` = SilenceParameters()

    /// Conservative preset: keeps more audio, cuts less. For quiet or noisy material.
    public static let conservative = SilenceParameters(
        marginDB: 5,
        minSilenceDuration: .milliseconds(800),
        padLead: .milliseconds(300),
        padTrail: .milliseconds(500)
    )
}

/// A contiguous span the detector classified as speech, on the original timeline.
public struct SpeechRegion: Hashable, Sendable, Codable {
    public let range: TimeRange
    public let meanEnergyDB: Float
    public let peakEnergyDB: Float

    public init(range: TimeRange, meanEnergyDB: Float, peakEnergyDB: Float) {
        self.range = range
        self.meanEnergyDB = meanEnergyDB
        self.peakEnergyDB = peakEnergyDB
    }
}

/// A gap between speech regions.
///
/// Gaps are retained rather than discarded because their durations carry the
/// §7 pause semantics: the merger turns a long gap into a paragraph or section
/// break instead of silently joining two unrelated utterances.
public struct SilenceGap: Hashable, Sendable, Codable {
    public let range: TimeRange
    public let meanEnergyDB: Float

    public init(range: TimeRange, meanEnergyDB: Float) {
        self.range = range
        self.meanEnergyDB = meanEnergyDB
    }

    public var duration: MediaTime { range.duration }
}

/// The output of the silence detector: where speech is, where it is not, and how
/// the detector reached that conclusion.
///
/// Nothing here modifies audio. The map is consumed by the chunk planner (to pick
/// cut points), the scheduler (to skip silent spans), and the merger (to place
/// paragraph breaks).
public struct SilenceMap: Sendable, Codable {
    /// Ordered, disjoint, non-empty speech spans on the original timeline.
    public let speechRegions: [SpeechRegion]
    /// Ordered gaps between and around those regions.
    public let gaps: [SilenceGap]
    /// Tracked noise floor in dBFS, one value per analysis frame.
    public let noiseFloorProfile: [Float]
    public let parameters: SilenceParameters
    /// Hash over the parameters and the source content hash. The invalidation key.
    public let parameterHash: String
    /// Full duration of the source, so processed↔original mapping is total.
    public let sourceDuration: MediaTime

    public init(
        speechRegions: [SpeechRegion],
        gaps: [SilenceGap],
        noiseFloorProfile: [Float],
        parameters: SilenceParameters,
        parameterHash: String,
        sourceDuration: MediaTime
    ) {
        self.speechRegions = speechRegions
        self.gaps = gaps
        self.noiseFloorProfile = noiseFloorProfile
        self.parameters = parameters
        self.parameterHash = parameterHash
        self.sourceDuration = sourceDuration
    }

    /// Total speech duration — what actually gets sent to the ASR engine.
    public var speechDuration: MediaTime {
        speechRegions.reduce(MediaTime.zero) { $0 + $1.range.duration }
    }

    /// Fraction of the recording that is speech, in `0...1`.
    public var speechFraction: Double {
        sourceDuration.nanoseconds > 0
            ? Double(speechDuration.nanoseconds) / Double(sourceDuration.nanoseconds)
            : 0
    }

    /// Converts a position on the silence-skipped timeline back to original time.
    ///
    /// - Returns: The original-timeline position, clamped to the end of the last
    ///   speech region when `processed` runs past the end.
    public func originalTime(forProcessed processed: MediaTime) -> MediaTime {
        var remaining = processed
        for region in speechRegions {
            let d = region.range.duration
            if remaining < d { return region.range.start + remaining }
            remaining = remaining - d
        }
        return speechRegions.last?.range.end ?? .zero
    }

    /// Converts an original-timeline position to the silence-skipped timeline.
    ///
    /// - Returns: `nil` when `original` falls inside a gap — it has no processed
    ///   counterpart, and callers must decide what that means rather than being
    ///   handed a silently wrong number.
    public func processedTime(forOriginal original: MediaTime) -> MediaTime? {
        var accumulated = MediaTime.zero
        for region in speechRegions {
            if region.range.contains(original) {
                return accumulated + (original - region.range.start)
            }
            if original < region.range.start { return nil }
            accumulated = accumulated + region.range.duration
        }
        return nil
    }
}
