import Foundation
import Accelerate
import VoxScriptaCore

/// A downsampled min/max envelope for drawing a waveform.
///
/// Drawing from the canonical audio directly would mean touching 345 million
/// samples for a six-hour recording every time a window resizes. This reduces it
/// once to a few thousand buckets — small enough to hold, fast enough to redraw.
public struct WaveformPeaks: Sendable, Codable {
    /// Most negative sample in each bucket.
    public let minima: [Float]
    /// Most positive sample in each bucket.
    public let maxima: [Float]
    public let duration: MediaTime

    public init(minima: [Float], maxima: [Float], duration: MediaTime) {
        precondition(minima.count == maxima.count, "peak arrays must match")
        self.minima = minima
        self.maxima = maxima
        self.duration = duration
    }

    public var count: Int { minima.count }

    /// The time at the centre of bucket `index`.
    public func time(ofBucket index: Int) -> MediaTime {
        guard count > 0 else { return .zero }
        let fraction: Double = (Double(index) + 0.5) / Double(count)
        return duration * fraction
    }

    /// Builds peaks from a canonical PCM file.
    ///
    /// Streams the mapped file so a long recording costs no more memory than a
    /// short one, consistent with everything else that reads canonical audio.
    public static func build(
        canonicalFile: URL,
        bucketCount: Int = 4096
    ) throws -> WaveformPeaks {
        let data: Data
        do {
            data = try Data(contentsOf: canonicalFile, options: [.mappedIfSafe])
        } catch {
            throw VoxScriptaError.ioFailure(path: canonicalFile.path,
                                          reason: error.localizedDescription)
        }
        let sampleCount = data.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else {
            throw VoxScriptaError.analysisFailed(stage: "waveform", reason: "no samples")
        }

        let buckets = Swift.min(bucketCount, sampleCount)
        var minima = [Float](repeating: 0, count: buckets)
        var maxima = [Float](repeating: 0, count: buckets)

        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            for bucket in 0..<buckets {
                let start = sampleCount * bucket / buckets
                let end = Swift.max(start + 1, sampleCount * (bucket + 1) / buckets)
                let slice = UnsafeBufferPointer(rebasing: samples[start..<Swift.min(end, sampleCount)])
                var low: Float = 0
                var high: Float = 0
                vDSP_minv(slice.baseAddress!, 1, &low, vDSP_Length(slice.count))
                vDSP_maxv(slice.baseAddress!, 1, &high, vDSP_Length(slice.count))
                minima[bucket] = low
                maxima[bucket] = high
            }
        }

        return WaveformPeaks(
            minima: minima, maxima: maxima,
            duration: MediaTime(samples: Int64(sampleCount),
                                sampleRate: CanonicalFormat.sampleRate))
    }
}
