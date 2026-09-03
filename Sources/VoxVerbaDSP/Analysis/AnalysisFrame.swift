import Foundation
import VoxVerbaCore

/// How the analyzer slices the signal.
///
/// 25 ms windows at a 10 ms hop is the standard speech-analysis geometry: long
/// enough for a stable spectral estimate, short enough to resolve a stop closure.
public struct FrameGeometry: Hashable, Sendable {
    public let windowDuration: MediaTime
    public let hopDuration: MediaTime
    public let sampleRate: Int

    public init(
        windowDuration: MediaTime = .milliseconds(25),
        hopDuration: MediaTime = .milliseconds(10),
        sampleRate: Int = CanonicalFormat.sampleRate
    ) {
        self.windowDuration = windowDuration
        self.hopDuration = hopDuration
        self.sampleRate = sampleRate
    }

    public static let `default` = FrameGeometry()

    public var windowSamples: Int { Int(windowDuration.samples(at: sampleRate)) }
    public var hopSamples: Int { Int(hopDuration.samples(at: sampleRate)) }

    /// Number of frames produced for a given sample count.
    public func frameCount(forSamples n: Int64) -> Int {
        n < Int64(windowSamples) ? 0 : Int((n - Int64(windowSamples)) / Int64(hopSamples)) + 1
    }

    /// The start time of frame `index` on the timeline.
    public func time(ofFrame index: Int) -> MediaTime {
        MediaTime(samples: Int64(index) * Int64(hopSamples), sampleRate: sampleRate)
    }

    /// The frame index covering `time`, clamped to zero.
    public func frame(atTime time: MediaTime) -> Int {
        Swift.max(0, Int(time.samples(at: sampleRate) / Int64(hopSamples)))
    }
}

/// Per-frame features, stored as a struct-of-arrays.
///
/// Struct-of-arrays rather than an array of structs because every consumer sweeps
/// one feature at a time, and because vDSP operates on contiguous `Float` buffers.
/// At roughly 360 bytes per second of audio, a six-hour file's full feature set is
/// about 8 MB — small enough to stay resident, which makes re-tuning thresholds in
/// the UI instant without re-reading any audio.
public struct FrameFeatures: Sendable {
    /// Short-time RMS in dBFS.
    public var rmsDB: [Float]
    /// Zero-crossing rate, normalized to `0...1`.
    public var zeroCrossingRate: [Float]
    /// Wiener entropy, `0...1`. High for broadband noise and unvoiced fricatives.
    public var spectralFlatness: [Float]
    public let geometry: FrameGeometry

    public init(
        rmsDB: [Float],
        zeroCrossingRate: [Float],
        spectralFlatness: [Float],
        geometry: FrameGeometry
    ) {
        precondition(
            rmsDB.count == zeroCrossingRate.count && rmsDB.count == spectralFlatness.count,
            "FrameFeatures requires all feature arrays to be the same length"
        )
        self.rmsDB = rmsDB
        self.zeroCrossingRate = zeroCrossingRate
        self.spectralFlatness = spectralFlatness
        self.geometry = geometry
    }

    public var count: Int { rmsDB.count }
    public var isEmpty: Bool { rmsDB.isEmpty }
    public var duration: MediaTime { geometry.time(ofFrame: count) }
}

/// Computes ``FrameFeatures`` from canonical PCM.
///
/// - Note: Phase 1 implements this with vDSP over a memory-mapped buffer,
///   advised `MADV_SEQUENTIAL`.
public protocol FrameAnalyzing: Sendable {
    func analyze(
        canonicalFile: URL,
        geometry: FrameGeometry,
        progress: @Sendable (Double) -> Void
    ) async throws -> FrameFeatures
}

/// Phase 1 implementation site.
public struct FrameAnalyzer: FrameAnalyzing {
    public init() {}

    public func analyze(
        canonicalFile: URL,
        geometry: FrameGeometry,
        progress: @Sendable (Double) -> Void
    ) async throws -> FrameFeatures {
        throw VoxVerbaError.notImplemented("FrameAnalyzer.analyze — Phase 1")
    }
}
