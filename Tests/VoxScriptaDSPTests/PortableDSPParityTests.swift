import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaDSP
#if canImport(Accelerate)
import Accelerate
#endif

/// The plain-Swift DSP primitives, held to Accelerate's answers.
///
/// These run on Android, Windows and Linux, where nothing can check them. So
/// they are checked here, against the vDSP calls they replace, on the same
/// input — because the alternative is code that only ever executes where
/// nobody is looking.
///
/// Exactness is not the goal; agreement is. Silence detection's thresholds
/// were calibrated with Accelerate underneath, and a spectrum off by a
/// constant would move every boundary this project has measured.
@Suite("Portable DSP parity")
struct PortableDSPParityTests {

    private func signal(_ count: Int, seed: UInt64 = 42) -> [Float] {
        // Tone plus noise plus offset: a pure tone would hide a scale error
        // in the quiet bins, which is exactly where flatness is sensitive.
        var state = seed
        func random() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 33) / Double(UInt32.max)) - 0.5
        }
        return (0..<count).map { i in
            0.6 * sin(2 * .pi * 440 * Float(i) / 16_000)
                + 0.2 * sin(2 * .pi * 3_300 * Float(i) / 16_000)
                + 0.05 * random() + 0.01
        }
    }

    #if canImport(Accelerate)

    @Test("The power spectrum matches vDSP bin for bin")
    func spectrumMatchesAccelerate() throws {
        for size in [256, 512, 1024] {
            let input = signal(size)
            var mine = [Float](repeating: 0, count: size / 2)
            var theirs = [Float](repeating: 0, count: size / 2)

            PortableDSP.powerSpectrum(of: input, into: &mine)
            try RealFFT(size: size).powerSpectrum(of: input, into: &theirs)

            // Relative, because the bins span many orders of magnitude and an
            // absolute tolerance would be meaningless at both ends.
            var worst = 0.0
            var worstBin = 0
            for bin in 0..<(size / 2) {
                let scale = Swift.max(Double(abs(theirs[bin])), 1e-9)
                let error = Double(abs(mine[bin] - theirs[bin])) / scale
                if error > worst { worst = error; worstBin = bin }
            }
            print("FFT \(size): worst relative error \(worst) at bin \(worstBin)")
            #expect(worst < 1e-4,
                    "size \(size): bin \(worstBin) differs by \(worst) relative")
        }
    }

    @Test("Spectral flatness comes out the same, which is what is used")
    func flatnessMatches() throws {
        // The spectrum is an intermediate; this is the number that reaches
        // silence detection, so it is the one that must agree.
        for size in [256, 1024] {
            let input = signal(size, seed: 7)
            var mine = [Float](repeating: 0, count: size / 2)
            var theirs = [Float](repeating: 0, count: size / 2)
            PortableDSP.powerSpectrum(of: input, into: &mine)
            try RealFFT(size: size).powerSpectrum(of: input, into: &theirs)

            let a = FrameAnalyzer.spectralFlatness(mine)
            let b = FrameAnalyzer.spectralFlatness(theirs)
            print("FLATNESS \(size): portable \(a) vs vDSP \(b)")
            #expect(abs(a - b) < 1e-5, "flatness differs: \(a) vs \(b)")
        }
    }

    @Test("Silence looks like silence to both")
    func silenceMatches() throws {
        // The case the feature exists to judge, and the one where a scale
        // error against the epsilon floor would show.
        let size = 512
        let input = [Float](repeating: 0, count: size)
        var mine = [Float](repeating: 0, count: size / 2)
        var theirs = [Float](repeating: 0, count: size / 2)
        PortableDSP.powerSpectrum(of: input, into: &mine)
        try RealFFT(size: size).powerSpectrum(of: input, into: &theirs)
        #expect(FrameAnalyzer.spectralFlatness(mine)
                == FrameAnalyzer.spectralFlatness(theirs))
    }

    @Test("The Hann window matches vDSP's denormalized one")
    func hannMatchesAccelerate() {
        for count in [64, 400, 1024] {
            var theirs = [Float](repeating: 0, count: count)
            vDSP_hann_window(&theirs, vDSP_Length(count), Int32(vDSP_HANN_DENORM))
            let mine = PortableDSP.hannWindow(count: count)
            var worst: Float = 0
            for i in 0..<count { worst = Swift.max(worst, abs(mine[i] - theirs[i])) }
            print("HANN \(count): worst absolute difference \(worst)")
            #expect(worst < 1e-6, "window of \(count) differs by \(worst)")
        }
    }

    @Test("Root mean square matches vDSP")
    func rmsMatchesAccelerate() {
        for count in [1, 7, 400, 4096] {
            let input = signal(count, seed: 3)
            var theirs: Float = 0
            input.withUnsafeBufferPointer {
                vDSP_rmsqv($0.baseAddress!, 1, &theirs, vDSP_Length(count))
            }
            let mine = input.withUnsafeBufferPointer { PortableDSP.rootMeanSquare($0) }
            #expect(abs(mine - theirs) < 1e-6, "count \(count): \(mine) vs \(theirs)")
        }
    }

    @Test("Minimum and maximum match vDSP")
    func boundsMatchAccelerate() {
        let input = signal(1000, seed: 11)
        var low: Float = 0, high: Float = 0
        input.withUnsafeBufferPointer {
            vDSP_minv($0.baseAddress!, 1, &low, vDSP_Length(input.count))
            vDSP_maxv($0.baseAddress!, 1, &high, vDSP_Length(input.count))
        }
        let mine = input.withUnsafeBufferPointer { PortableDSP.bounds($0) }
        #expect(mine.min == low)
        #expect(mine.max == high)
    }

    @Test("Elementwise multiply matches vDSP")
    func multiplyMatchesAccelerate() {
        let count = 400
        let a = signal(count, seed: 5)
        let b = PortableDSP.hannWindow(count: count)
        var theirs = [Float](repeating: 0, count: count)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                vDSP_vmul(ap.baseAddress!, 1, bp.baseAddress!, 1,
                          &theirs, 1, vDSP_Length(count))
            }
        }
        var mine = [Float](repeating: 0, count: count)
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                PortableDSP.multiply(ap, bp, into: &mine)
            }
        }
        #expect(mine == theirs)
    }

    #endif

    // MARK: - True on every platform

    @Test("The transform inverts to what went in")
    func transformIsCorrect() {
        // Independent of vDSP: a forward transform followed by a conjugate
        // transform and a divide must return the original, which catches a
        // wrong twiddle or a broken bit-reversal on its own terms.
        var re = (0..<64).map { Double(sin(Double($0) * 0.3) + 0.2) }
        var im = [Double](repeating: 0, count: 64)
        let original = re

        PortableDSP.transform(&re, &im)
        // Inverse by the swap identity: IFFT(X) = swap(FFT(swap(X))) / N.
        // Passing the arrays the other way round is the first swap; the
        // second is reading the result back from `re`, which is where the
        // real part lands — not `im`, which is what this test checked first.
        PortableDSP.transform(&im, &re)
        for i in 0..<64 { re[i] /= 64; im[i] /= 64 }

        for i in 0..<64 {
            #expect(abs(re[i] - original[i]) < 1e-9, "sample \(i) came back as \(re[i])")
        }
    }

    @Test("A pure tone lands in the bin it belongs in")
    func toneLandsInItsBin() {
        let size = 512
        let bin = 40
        let input = (0..<size).map {
            Float(sin(2 * Double.pi * Double(bin) * Double($0) / Double(size)))
        }
        var power = [Float](repeating: 0, count: size / 2)
        PortableDSP.powerSpectrum(of: input, into: &power)
        let peak = power.enumerated().max { $0.element < $1.element }?.offset
        #expect(peak == bin, "a tone at bin \(bin) peaked at \(peak ?? -1)")
    }
}
