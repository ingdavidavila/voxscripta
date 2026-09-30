import Foundation
import Accelerate
import VoxScriptaCore

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

/// Computes per-frame features with vDSP over a memory-mapped buffer.
///
/// The file is mapped rather than read, so the kernel pages it in on demand and
/// can evict it under pressure — a six-hour recording contributes essentially
/// nothing to the process's dirty footprint.
public struct FrameAnalyzer: FrameAnalyzing {
    /// FFT length used for the spectral estimate. 512 bins at 16 kHz gives ~31 Hz
    /// resolution, ample for distinguishing broadband noise from harmonic speech.
    public let fftSize: Int

    public init(fftSize: Int = 512) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize must be a power of two")
        self.fftSize = fftSize
    }

    public func analyze(
        canonicalFile: URL,
        geometry: FrameGeometry,
        progress: @Sendable (Double) -> Void
    ) async throws -> FrameFeatures {
        let data: Data
        do {
            data = try Data(contentsOf: canonicalFile, options: [.mappedIfSafe])
        } catch {
            throw VoxScriptaError.ioFailure(path: canonicalFile.path, reason: error.localizedDescription)
        }

        let sampleCount = Int64(data.count / MemoryLayout<Float>.size)
        let frameCount = geometry.frameCount(forSamples: sampleCount)
        guard frameCount > 0 else {
            throw VoxScriptaError.analysisFailed(
                stage: "frame analysis",
                reason: "the recording is shorter than one \(geometry.windowSamples)-sample window"
            )
        }

        var rms = [Float](repeating: 0, count: frameCount)
        var zcr = [Float](repeating: 0, count: frameCount)
        var flatness = [Float](repeating: 0, count: frameCount)

        let window = hannWindow(count: geometry.windowSamples)
        let fft = try RealFFT(size: fftSize)

        try data.withUnsafeBytes { raw -> Void in
            let samples = raw.bindMemory(to: Float.self)
            var windowed = [Float](repeating: 0, count: geometry.windowSamples)
            var padded = [Float](repeating: 0, count: fftSize)
            var power = [Float](repeating: 0, count: fftSize / 2)

            for frame in 0..<frameCount {
                if frame % 4096 == 0 {
                    try Task.checkCancellation()
                    progress(Double(frame) / Double(frameCount))
                }
                let start = frame * geometry.hopSamples
                let slice = UnsafeBufferPointer(rebasing: samples[start..<(start + geometry.windowSamples)])

                rms[frame] = Self.dBFS(Self.rootMeanSquare(slice))
                zcr[frame] = Self.zeroCrossingRate(slice)

                vDSP_vmul(slice.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(windowed.count))
                let copyCount = Swift.min(windowed.count, fftSize)
                padded.withUnsafeMutableBufferPointer { dst in
                    dst.update(repeating: 0)
                    windowed.withUnsafeBufferPointer { src in
                        dst.baseAddress!.update(from: src.baseAddress!, count: copyCount)
                    }
                }
                fft.powerSpectrum(of: padded, into: &power)
                flatness[frame] = Self.spectralFlatness(power)
            }
        }

        progress(1)
        return FrameFeatures(rmsDB: rms, zeroCrossingRate: zcr,
                             spectralFlatness: flatness, geometry: geometry)
    }

    // MARK: - Feature computation

    /// Level floor. Frames quieter than this are reported at the floor rather than
    /// at negative infinity, which keeps downstream arithmetic finite.
    public static let minimumDB: Float = -120

    static func rootMeanSquare(_ buffer: UnsafeBufferPointer<Float>) -> Float {
        var result: Float = 0
        vDSP_rmsqv(buffer.baseAddress!, 1, &result, vDSP_Length(buffer.count))
        return result
    }

    static func dBFS(_ amplitude: Float) -> Float {
        amplitude <= 0 ? minimumDB : Swift.max(20 * log10(amplitude), minimumDB)
    }

    /// Fraction of adjacent sample pairs that change sign.
    ///
    /// High ZCR with low energy is the signature of an unvoiced fricative — the
    /// discriminator that keeps stage 3 from cutting sibilance.
    static func zeroCrossingRate(_ buffer: UnsafeBufferPointer<Float>) -> Float {
        guard buffer.count > 1 else { return 0 }
        var crossings = 0
        var previous = buffer[0]
        for i in 1..<buffer.count {
            let current = buffer[i]
            if (current >= 0) != (previous >= 0) { crossings += 1 }
            previous = current
        }
        return Float(crossings) / Float(buffer.count - 1)
    }

    /// Wiener entropy: geometric mean over arithmetic mean of the power spectrum.
    ///
    /// Near 1 for broadband noise and fricatives, near 0 for a harmonic stack.
    /// This is what separates "quiet but spectrally speech-like" from "quiet".
    static func spectralFlatness(_ power: [Float]) -> Float {
        guard !power.isEmpty else { return 0 }
        let epsilon: Float = 1e-12
        var logSum: Float = 0
        var linearSum: Float = 0
        for value in power {
            let v = value + epsilon
            logSum += log(v)
            linearSum += v
        }
        let geometricMean = exp(logSum / Float(power.count))
        let arithmeticMean = linearSum / Float(power.count)
        guard arithmeticMean > 0 else { return 0 }
        return Swift.min(geometricMean / arithmeticMean, 1)
    }

    private func hannWindow(count: Int) -> [Float] {
        var w = [Float](repeating: 0, count: count)
        vDSP_hann_window(&w, vDSP_Length(count), Int32(vDSP_HANN_DENORM))
        return w
    }
}

/// A real-to-complex FFT with a reusable setup.
///
/// A class because it owns an Accelerate setup that must be destroyed exactly once.
final class RealFFT {
    private let setup: FFTSetup
    private let size: Int
    private let log2n: vDSP_Length

    init(size: Int) throws {
        precondition(size.nonzeroBitCount == 1, "FFT size must be a power of two")
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw VoxScriptaError.analysisFailed(stage: "frame analysis",
                                               reason: "could not create the FFT setup")
        }
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Computes the magnitude-squared spectrum of `input` into `output`.
    func powerSpectrum(of input: [Float], into output: inout [Float]) {
        precondition(input.count == size)
        precondition(output.count == size / 2)

        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                input.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &output, 1, vDSP_Length(size / 2))
            }
        }
    }
}
