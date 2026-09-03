import Foundation
import VoxVerbaCore

/// One test recording, with the ground truth used to grade the detector.
///
/// The whole point of synthesizing the corpus is that ``expectedSpeechRegions``
/// is exact by construction rather than transcribed by a person — which makes
/// boundary error an automatable measurement instead of a judgement call.
public struct CorpusCase: Sendable, Codable {
    public let name: String
    /// What this case is designed to catch, recorded so a future failure is legible.
    public let purpose: String
    public let spans: [SignalSpan]
    public let noiseFloorDB: Double
    /// When set, the room tone ramps linearly to this level across the recording.
    public let noiseFloorEndDB: Double?
    public let seed: UInt64

    public init(
        name: String,
        purpose: String,
        spans: [SignalSpan],
        noiseFloorDB: Double = -62,
        noiseFloorEndDB: Double? = nil,
        seed: UInt64 = 0x0C7A_5EED
    ) {
        self.name = name
        self.purpose = purpose
        self.spans = spans
        self.noiseFloorDB = noiseFloorDB
        self.noiseFloorEndDB = noiseFloorEndDB
        self.seed = seed
    }

    public var duration: MediaTime { spans.last?.range.end ?? .zero }

    /// The spans a correct detector should report as speech, with adjacent spans
    /// coalesced — a fricative immediately following a vowel is one region, not two.
    public var expectedSpeechRegions: [TimeRange] {
        var out: [TimeRange] = []
        for span in spans where span.isSpeech {
            if let last = out.last, last.end == span.range.start {
                out[out.count - 1] = TimeRange(start: last.start, end: span.range.end)
            } else {
                out.append(span.range)
            }
        }
        return out
    }

    /// Renders this case to canonical-rate samples.
    public func render(sampleRate: Int = CanonicalFormat.sampleRate) -> [Float] {
        SignalSynthesizer(sampleRate: sampleRate, seed: seed)
            .render(spans: spans, noiseFloorDB: noiseFloorDB, noiseFloorEndDB: noiseFloorEndDB)
    }
}

// MARK: - Builders

private func span(_ kind: SignalKind, _ from: Double, _ to: Double, _ db: Double) -> SignalSpan {
    SignalSpan(kind: kind, range: TimeRange(start: .seconds(from), end: .seconds(to)), levelDB: db)
}

/// The standard corpus.
///
/// Each case isolates one documented failure mode of naive silence detection, so
/// a regression names its own cause.
public enum StandardCorpus {

    /// Plain alternation. The baseline every other case is measured against.
    public static let basic = CorpusCase(
        name: "basic_speech_silence",
        purpose: "Baseline: clear speech alternating with clear silence.",
        spans: [
            span(.silence, 0, 2, -62),
            span(.voiced, 2, 7, -18),
            span(.silence, 7, 10, -62),
            span(.voiced, 10, 16, -18),
            span(.silence, 16, 18, -62),
        ]
    )

    /// A speaker well below normal level. A fixed threshold gates this out entirely.
    public static let quietSpeaker = CorpusCase(
        name: "quiet_speaker",
        purpose: "Speech at -38 dBFS must still register. Fixed thresholds fail here.",
        spans: [
            span(.silence, 0, 2, -62),
            span(.voiced, 2, 8, -38),
            span(.silence, 8, 11, -62),
            span(.voiced, 11, 16, -38),
            span(.silence, 16, 18, -62),
        ]
    )

    /// Sibilance at the tail of a word. Stage 3 exists for this case.
    public static let fricatives = CorpusCase(
        name: "fricatives",
        purpose: "Fricatives trail each voiced span *below* the energy exit threshold; only spectral discrimination keeps them, and losing them costs plurals and possessives.",
        spans: [
            span(.silence, 0, 2, -62),
            span(.voiced, 2, 6, -18),
            span(.fricative, 6, 6.4, -57),
            span(.silence, 6.4, 9, -62),
            span(.voiced, 9, 13, -18),
            span(.fricative, 13, 13.45, -56),
            span(.silence, 13.45, 16, -62),
        ]
    )

    /// Stop closures inside words. Stage 4's ordering exists for this case.
    public static let stopClosures = CorpusCase(
        name: "stop_closures",
        purpose: "60 ms closures every 400 ms are inside words, not pauses; the region must not fragment.",
        spans: [
            span(.silence, 0, 2, -62),
            span(.voicedWithClosures, 2, 12, -20),
            span(.silence, 12, 15, -62),
        ]
    )

    /// The §7 case: a long pause that must survive as structure.
    public static let longPause = CorpusCase(
        name: "long_pause",
        purpose: "A 5 s pause must be detected so the merger can make it a paragraph break.",
        spans: [
            span(.voiced, 0, 4, -18),
            span(.silence, 4, 9, -62),
            span(.voiced, 9, 14, -18),
        ]
    )

    /// A room whose noise floor climbs mid-recording. Stage 1 exists for this case.
    public static let risingNoiseFloor = CorpusCase(
        name: "rising_noise_floor",
        purpose: "Room tone climbs 20 dB across the file; a static threshold either over-cuts early or under-cuts late.",
        spans: [
            span(.silence, 0, 2, -62),
            span(.voiced, 2, 7, -20),
            span(.silence, 7, 10, -62),
            span(.voiced, 10, 15, -20),
            span(.silence, 15, 17, -62),
        ],
        noiseFloorDB: -62,
        noiseFloorEndDB: -42
    )

    /// Speech in broadband noise at roughly 12 dB SNR.
    public static let noisyRoom = CorpusCase(
        name: "noisy_room",
        purpose: "Speech ~12 dB above a loud floor. Absolute thresholds mis-fire; adaptive ones should not.",
        spans: [
            span(.silence, 0, 2, -34),
            span(.voiced, 2, 8, -22),
            span(.silence, 8, 11, -34),
            span(.voiced, 11, 16, -22),
            span(.silence, 16, 18, -34),
        ],
        noiseFloorDB: -34
    )

    /// Uninterrupted speech, long enough to force the planner's hard-cut path.
    public static let continuousSpeech = CorpusCase(
        name: "continuous_speech",
        purpose: "Six minutes without a usable pause; the chunk planner must fall back to a hard cut with overlap.",
        spans: [
            span(.voiced, 0, 360, -20),
        ]
    )

    /// Room tone and nothing else, at a level loud enough to look like signal.
    ///
    /// The counterpart to `continuousSpeech`: both are homogeneous in level, and
    /// only spectral flatness separates them. If the noise-floor cap were applied
    /// here it would drag the floor 20 dB down and report hiss as speech.
    public static let roomToneOnly = CorpusCase(
        name: "room_tone_only",
        purpose: "A recording with no speech must yield no speech, even when the room tone is loud.",
        spans: [span(.silence, 0, 20, -34)],
        noiseFloorDB: -34
    )

    /// Every case, in a stable order.
    public static let all: [CorpusCase] = [
        basic, quietSpeaker, fricatives, stopClosures,
        longPause, risingNoiseFloor, noisyRoom, continuousSpeech, roomToneOnly,
    ]

    public static func named(_ name: String) -> CorpusCase? {
        all.first { $0.name == name }
    }
}
