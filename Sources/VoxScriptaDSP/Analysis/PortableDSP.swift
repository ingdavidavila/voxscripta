import Foundation
import VoxScriptaCore

/// The handful of Accelerate primitives this project uses, in plain Swift.
///
/// Written so the analysis stage runs where Accelerate does not — Android,
/// Windows and Linux. It is compiled on every platform, not only those, which
/// is the point: `PortableDSPParityTests` runs it against vDSP on the same
/// input, so the version those platforms rely on is the version that was
/// measured, rather than one that only ever ran where nobody could check it.
///
/// Matching vDSP exactly matters more than being mathematically tidy. The
/// spectral-flatness feature feeds silence detection, whose thresholds were
/// calibrated against synthetic ground truth with Accelerate underneath; a
/// spectrum that differed by a constant factor would quietly move every
/// boundary this project has measured.
public enum PortableDSP {

    // MARK: - Scalar reductions

    /// `vDSP_rmsqv`: the root mean square of a buffer.
    public static func rootMeanSquare(_ buffer: UnsafeBufferPointer<Float>) -> Float {
        guard !buffer.isEmpty else { return 0 }
        // Accumulated in Double. A 25 ms window at 16 kHz is 400 samples, which
        // Float would carry, but the sum is the one place where precision here
        // is free and the level feeds a dB threshold.
        var total = 0.0
        for value in buffer { total += Double(value) * Double(value) }
        return Float((total / Double(buffer.count)).squareRoot())
    }

    /// `vDSP_minv` and `vDSP_maxv` in one pass.
    public static func bounds(_ buffer: UnsafeBufferPointer<Float>) -> (min: Float, max: Float) {
        guard let first = buffer.first else { return (0, 0) }
        var low = first, high = first
        for value in buffer {
            if value < low { low = value }
            if value > high { high = value }
        }
        return (low, high)
    }

    /// `vDSP_vmul`: elementwise product into `output`.
    public static func multiply(_ a: UnsafeBufferPointer<Float>,
                                _ b: UnsafeBufferPointer<Float>,
                                into output: inout [Float]) {
        let count = Swift.min(a.count, b.count, output.count)
        output.withUnsafeMutableBufferPointer { out in
            for i in 0..<count { out[i] = a[i] * b[i] }
        }
    }

    /// `vDSP_hann_window` with `vDSP_HANN_DENORM`.
    ///
    /// The denormalized form peaks at 1 and spans the whole window, which is
    /// `0.5 · (1 − cos(2πn / N))` — the periodic definition, not the
    /// symmetric `N − 1` one. Which of the two vDSP means is not something to
    /// infer from a name; the parity test pins it.
    public static func hannWindow(count: Int) -> [Float] {
        guard count > 1 else { return [Float](repeating: count == 1 ? 1 : 0, count: count) }
        var window = [Float](repeating: 0, count: count)
        for n in 0..<count {
            window[n] = Float(0.5 * (1 - cos(2 * Double.pi * Double(n) / Double(count))))
        }
        return window
    }

    // MARK: - The transform

    /// `vDSP_fft_zrip` followed by `vDSP_zvmags`, for real input.
    ///
    /// Three conventions have to be reproduced, and none of them is the
    /// obvious choice:
    ///
    /// 1. vDSP's real FFT returns **twice** the mathematical transform.
    /// 2. It packs the two purely real bins together — DC in `realp[0]` and
    ///    Nyquist in `imagp[0]` — so the first power value is the sum of
    ///    their squares rather than the DC power alone.
    /// 3. The remaining `N/2 − 1` bins are ordinary complex values.
    ///
    /// Reproduced rather than improved on, because the thresholds downstream
    /// were measured against this and not against the textbook.
    public static func powerSpectrum(of input: [Float], into output: inout [Float]) {
        let n = input.count
        precondition(n.nonzeroBitCount == 1, "FFT size must be a power of two")
        precondition(output.count == n / 2)
        guard n >= 2 else { output = [0]; return }

        let half = n / 2

        // The standard trick vDSP's `ctoz` sets up: pack the real signal into
        // a half-length complex sequence, transform that, then untangle. It
        // halves the work and is why the input is read two samples at a time.
        var re = [Double](repeating: 0, count: half)
        var im = [Double](repeating: 0, count: half)
        for k in 0..<half {
            re[k] = Double(input[2 * k])
            im[k] = Double(input[2 * k + 1])
        }
        transform(&re, &im)

        // Untangle: the even and odd halves of the original spectrum.
        for k in 0..<half {
            let mirror = (half - k) % half
            let evenRe = (re[k] + re[mirror]) / 2
            let evenIm = (im[k] - im[mirror]) / 2
            let oddRe = (im[k] + im[mirror]) / 2
            let oddIm = -(re[k] - re[mirror]) / 2

            let angle = -2 * Double.pi * Double(k) / Double(n)
            let wr = cos(angle), wi = sin(angle)
            let rotatedRe = oddRe * wr - oddIm * wi
            let rotatedIm = oddRe * wi + oddIm * wr

            if k == 0 {
                // DC and Nyquist, both real, and both scaled by two — then
                // squared together, which is what zvmags does to vDSP's
                // packing whether or not anyone intended it.
                let dc = 2 * (evenRe + rotatedRe)
                let nyquist = 2 * (evenRe - rotatedRe)
                output[0] = Float(dc * dc + nyquist * nyquist)
            } else {
                let real = 2 * (evenRe + rotatedRe)
                let imaginary = 2 * (evenIm + rotatedIm)
                output[k] = Float(real * real + imaginary * imaginary)
            }
        }
    }

    /// In-place iterative radix-2 Cooley-Tukey, forward.
    ///
    /// Iterative rather than recursive so a six-hour recording's worth of
    /// frames costs no stack, and in Double because the untangling above
    /// subtracts nearly equal numbers, where Float would lose the quiet bins
    /// that spectral flatness is most sensitive to.
    static func transform(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        guard n > 1 else { return }

        // Bit-reversal permutation.
        var target = 0
        for position in 0..<(n - 1) {
            if position < target {
                re.swapAt(position, target)
                im.swapAt(position, target)
            }
            var mask = n >> 1
            while target & mask != 0 {
                target &= ~mask
                mask >>= 1
            }
            target |= mask
        }

        var span = 1
        while span < n {
            let step = span << 1
            let delta = -Double.pi / Double(span)
            for group in 0..<span {
                let angle = delta * Double(group)
                let wr = cos(angle), wi = sin(angle)
                var index = group
                while index < n {
                    let partner = index + span
                    let tr = re[partner] * wr - im[partner] * wi
                    let ti = re[partner] * wi + im[partner] * wr
                    re[partner] = re[index] - tr
                    im[partner] = im[index] - ti
                    re[index] += tr
                    im[index] += ti
                    index += step
                }
            }
            span = step
        }
    }
}
