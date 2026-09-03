import Foundation
import VoxVerbaCore

/// The five-stage deterministic silence detector (§6).
///
/// No model participates in this decision, by requirement and by design. The
/// stages run in a fixed order, and the order is load-bearing:
///
/// 1. **Noise floor estimation** — minimum-statistics tracking, so thresholds
///    follow a changing room rather than a fixed guess.
/// 2. **Adaptive dual thresholds** — an enter level and a lower exit level,
///    both floating with the noise floor and clamped to an absolute floor.
/// 3. **Fricative protection** — low-energy frames adjacent to speech are held
///    when they show high ZCR *and* high spectral flatness. This is what keeps
///    `/s/`, `/f/`, `/ʃ/` and `/θ/` from being truncated, which otherwise costs
///    the transcript its plurals and possessives.
/// 4. **Duration gating** — short speech runs demoted first, then short silence
///    runs promoted. Reversing the order merges noise into speech.
/// 5. **Asymmetric padding** — outward only, more after than before.
///
/// - Note: Phase 1 implements all five stages against the synthetic ground-truth
///   corpus, which is what makes the boundary-error assertions meaningful.
public protocol SilenceDetecting: Sendable {
    func detect(
        features: FrameFeatures,
        parameters: SilenceParameters,
        sourceDuration: MediaTime,
        parameterHash: String
    ) throws -> SilenceMap
}

/// Phase 1 implementation site.
public struct SilenceDetector: SilenceDetecting {
    public let noiseFloorTracker: NoiseFloorTracker

    public init(noiseFloorTracker: NoiseFloorTracker = .default) {
        self.noiseFloorTracker = noiseFloorTracker
    }

    public func detect(
        features: FrameFeatures,
        parameters: SilenceParameters,
        sourceDuration: MediaTime,
        parameterHash: String
    ) throws -> SilenceMap {
        throw VoxVerbaError.notImplemented("SilenceDetector.detect — Phase 1")
    }
}
