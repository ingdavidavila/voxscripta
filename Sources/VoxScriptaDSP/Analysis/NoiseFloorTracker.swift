import Foundation
import VoxScriptaCore

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
    /// Speech is assumed to sit at least this far above the noise floor.
    ///
    /// Percentile tracking silently fails when a window contains no silence at
    /// all — a lecture without pauses makes the estimator track speech, which
    /// pushes the thresholds above the speech and detects nothing. Capping the
    /// estimate this far below the file's loud level makes that impossible.
    public let minimumSpeechToFloorDB: Float
    /// Spectral flatness below which the loudest content is taken to be speech.
    ///
    /// Deciding whether to apply the cap means telling "this file is entirely
    /// speech" from "this file is entirely room tone" — and both are homogeneous
    /// in level, so energy alone cannot separate them. Flatness can: voiced speech
    /// is a harmonic stack and measures near zero, while room tone is broadband
    /// and measures high. Capping an all-noise file would drag its floor down and
    /// turn hiss into speech, so the cap is withheld there.
    public let speechFlatnessCeiling: Float

    public init(
        windowDuration: MediaTime = .seconds(3),
        percentile: Float = 0.10,
        attackCoefficient: Float = 0.002,
        releaseCoefficient: Float = 0.050,
        minimumSpeechToFloorDB: Float = 20,
        speechFlatnessCeiling: Float = 0.20
    ) {
        self.windowDuration = windowDuration
        self.percentile = percentile
        self.attackCoefficient = attackCoefficient
        self.releaseCoefficient = releaseCoefficient
        self.minimumSpeechToFloorDB = minimumSpeechToFloorDB
        self.speechFlatnessCeiling = speechFlatnessCeiling
    }

    public static let `default` = NoiseFloorTracker()

    /// Produces a per-frame noise floor estimate in dBFS.
    ///
    /// A true sliding-window percentile over millions of frames would cost a sort
    /// per frame. Instead the signal is divided into non-overlapping blocks one
    /// window long, a percentile is taken per block, and per-frame values are
    /// linearly interpolated between block centres before smoothing. The estimate
    /// is indistinguishable in practice — the floor moves on the scale of seconds,
    /// not milliseconds — and the cost drops by the window length.
    ///
    /// - Returns: An array the same length as `features.rmsDB`.
    public func track(_ features: FrameFeatures) throws -> [Float] {
        let n = features.count
        guard n > 0 else {
            throw VoxScriptaError.analysisFailed(stage: "noise floor", reason: "no analysis frames")
        }

        let hop = features.geometry.hopDuration
        guard hop.nanoseconds > 0 else {
            throw VoxScriptaError.analysisFailed(stage: "noise floor", reason: "hop duration is zero")
        }
        let windowFrames = Swift.max(1, Int(windowDuration.nanoseconds / hop.nanoseconds))

        // Global anchor. When the file's loudest content is harmonic, speech is
        // present, and no local estimate may then claim a floor within
        // `minimumSpeechToFloorDB` of that loud level — which is what stops a
        // pause-free lecture from having its thresholds pushed above its speech.
        var sorted = features.rmsDB
        sorted.sort()
        let globalHigh = sorted[Swift.min(sorted.count - 1, Int(Float(sorted.count - 1) * 0.95))]

        var loudFlatness: [Float] = []
        loudFlatness.reserveCapacity(n / 8)
        for i in 0..<n where features.rmsDB[i] >= globalHigh - 6 {
            loudFlatness.append(features.spectralFlatness[i])
        }
        loudFlatness.sort()
        let medianLoudFlatness = loudFlatness.isEmpty
            ? 1
            : loudFlatness[loudFlatness.count / 2]

        let cap: Float? = medianLoudFlatness < speechFlatnessCeiling
            ? globalHigh - minimumSpeechToFloorDB
            : nil

        // Per-block percentile.
        var blockCentres: [Int] = []
        var blockValues: [Float] = []
        var start = 0
        while start < n {
            let end = Swift.min(start + windowFrames, n)
            var block = Array(features.rmsDB[start..<end])
            block.sort()
            let index = Swift.min(block.count - 1,
                                  Swift.max(0, Int(Float(block.count - 1) * percentile)))
            blockCentres.append((start + end) / 2)
            blockValues.append(cap.map { Swift.min(block[index], $0) } ?? block[index])
            start = end
        }

        // Interpolate between block centres.
        var raw = [Float](repeating: blockValues[0], count: n)
        if blockValues.count == 1 {
            raw = [Float](repeating: blockValues[0], count: n)
        } else {
            for i in 0..<n {
                if i <= blockCentres[0] { raw[i] = blockValues[0]; continue }
                if i >= blockCentres[blockCentres.count - 1] {
                    raw[i] = blockValues[blockValues.count - 1]; continue
                }
                var b = 0
                while b + 1 < blockCentres.count && blockCentres[b + 1] < i { b += 1 }
                let x0 = blockCentres[b], x1 = blockCentres[b + 1]
                let span = Float(x1 - x0)
                let t = span > 0 ? Float(i - x0) / span : 0
                raw[i] = blockValues[b] + (blockValues[b + 1] - blockValues[b]) * t
            }
        }

        // Asymmetric one-pole smoothing: the floor rises slowly and falls quickly,
        // so sustained speech cannot drag the estimate up and gate out a quiet
        // talker, while a genuinely quieter room is tracked promptly.
        var smoothed = [Float](repeating: 0, count: n)
        var state = raw[0]
        for i in 0..<n {
            let coefficient = raw[i] > state ? attackCoefficient : releaseCoefficient
            state += (raw[i] - state) * coefficient
            smoothed[i] = state
        }
        return smoothed
    }
}
