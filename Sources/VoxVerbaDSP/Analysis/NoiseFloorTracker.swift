import Foundation
import VoxVerbaCore

/// Tracks the noise floor so thresholds can follow a changing room.
///
/// A minimum-statistics estimator: a low percentile of frame energies over a
/// sliding window, smoothed asymmetrically so the floor rises slowly and falls
/// quickly. The asymmetry matters — a symmetric filter is dragged upward by
/// sustained speech and starts gating out the quiet talker.
///
/// - Note: Phase 1 implements the estimator. The parameters are fixed rather than
///   user-facing; they are a property of the algorithm, not a preference.
public struct NoiseFloorTracker: Sendable {
    /// Length of the sliding analysis window.
    public let windowDuration: MediaTime
    /// Percentile of windowed energy taken as the floor, `0...1`.
    public let percentile: Float
    /// Smoothing coefficient applied when the estimate rises.
    public let attackCoefficient: Float
    /// Smoothing coefficient applied when the estimate falls.
    public let releaseCoefficient: Float

    public init(
        windowDuration: MediaTime = .seconds(3),
        percentile: Float = 0.10,
        attackCoefficient: Float = 0.002,
        releaseCoefficient: Float = 0.050
    ) {
        self.windowDuration = windowDuration
        self.percentile = percentile
        self.attackCoefficient = attackCoefficient
        self.releaseCoefficient = releaseCoefficient
    }

    public static let `default` = NoiseFloorTracker()

    /// Produces a per-frame noise floor estimate in dBFS.
    ///
    /// - Returns: An array the same length as `features.rmsDB`.
    public func track(_ features: FrameFeatures) throws -> [Float] {
        throw VoxVerbaError.notImplemented("NoiseFloorTracker.track — Phase 1")
    }
}
