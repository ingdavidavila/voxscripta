import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaCoreCxx
import VoxScriptaCxxShim
import VoxScriptaDSP

/// Holds the C++ silence detector and the Swift original to the same answers.
///
/// This is the stage that most needs it. §6 says silence is found by
/// deterministic DSP and never by a model, which makes the result reproducible
/// — and reproducible is only a virtue if both implementations reproduce the
/// *same* thing. The Swift side has 96 DSP tests behind it; the C++ side has
/// its own, written against the port. Neither suite can catch the port
/// disagreeing with the original, because each encodes whatever its own side
/// does.
///
/// What is compared, and why in this order:
///
///  1. **Region and gap boundaries, exactly.** These are `MediaTime`, which is
///     integer nanoseconds, so there is no tolerance to argue about. They are
///     also what everything downstream consumes — a boundary that moves by one
///     frame moves a chunk, which moves a transcript.
///  2. **Energies and the noise floor, within a tolerance.** Floats, computed
///     through `log10` and `powf`, so bit-equality is not a reasonable demand.
///     The tolerance is far below anything that could change a decision; a
///     disagreement larger than it means the arithmetic differs, not the
///     rounding.
@Suite("Silence detection parity")
struct SilenceParityTests {

    /// Below anything that can change a classification, above libm noise.
    private static let tolerance: Float = 1e-3

    // ── Synthetic input ─────────────────────────────────────────────────────

    /// Frame features for a recording that alternates speech and quiet.
    ///
    /// Deterministic and seeded: a parity failure has to be reproducible or it
    /// cannot be investigated. The shape matters more than realism — what the
    /// detector has to get right is where the energy crosses the floor, how
    /// long it stays there, and what happens at the edges.
    struct Signal {
        let rms: [Float]
        let zcr: [Float]
        let flatness: [Float]

        /// - Parameters:
        ///   - pattern: alternating (loud frames, quiet frames) counts.
        ///   - seed: for the jitter laid over each plateau.
        init(pattern: [(loud: Int, quiet: Int)], seed: UInt64, fricatives: Bool = false) {
            var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            func next() -> Float {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float((state >> 33) % 1000) / 1000
            }

            var rms: [Float] = []
            var zcr: [Float] = []
            var flatness: [Float] = []
            for (loud, quiet) in pattern {
                for _ in 0..<loud {
                    rms.append(-24 + next() * 6)
                    zcr.append(0.04 + next() * 0.05)
                    flatness.append(0.05 + next() * 0.08)
                }
                for i in 0..<quiet {
                    // Optionally put a fricative-shaped frame — quiet, flat,
                    // high zero-crossing — at the head of each silence, which
                    // is exactly where fricative protection has to decide.
                    let isFricative = fricatives && i == 0
                    rms.append(isFricative ? -52 + next() : -68 + next() * 3)
                    zcr.append(isFricative ? 0.30 + next() * 0.1 : 0.02 + next() * 0.02)
                    flatness.append(isFricative ? 0.40 + next() * 0.1 : 0.03 + next() * 0.03)
                }
            }
            self.rms = rms
            self.zcr = zcr
            self.flatness = flatness
        }

        var count: Int { rms.count }
    }

    /// Signals chosen for the shapes that usually separate two ports: a clean
    /// alternation, pauses either side of the minimum durations, a recording
    /// that opens and closes in speech, and one that is silent throughout.
    /// Looked up by name rather than passed by value.
    ///
    /// Swift Testing prints every argument into the failure message, and a
    /// Signal is three arrays of several hundred floats — which buried the
    /// one line saying what actually disagreed under 80 KB of numbers.
    static func signal(_ name: String) -> Signal {
        signals.first { $0.name == name }!.signal
    }

    static var names: [String] { signals.map(\.name) }

    static let signals: [(name: String, signal: Signal)] = [
        ("steady alternation",
         Signal(pattern: Array(repeating: (loud: 120, quiet: 80), count: 5), seed: 1)),
        ("pauses around the minimum",
         Signal(pattern: [(100, 45), (100, 49), (100, 51), (100, 55), (100, 200)], seed: 2)),
        ("speech at both edges",
         Signal(pattern: [(60, 70), (90, 60), (75, 0)], seed: 3)),
        ("brief speech bursts",
         // 30 frames is 300 ms, comfortably over the 200 ms floor. At 18 it
         // was under, every burst was discarded, and the case tested only
         // that both sides find nothing.
         Signal(pattern: Array(repeating: (loud: 30, quiet: 90), count: 6), seed: 4)),
        ("fricative onsets",
         Signal(pattern: Array(repeating: (loud: 100, quiet: 70), count: 4), seed: 5,
                fricatives: true)),
        ("silent throughout",
         Signal(pattern: [(0, 400)], seed: 6)),
    ]

    static let parameterSets: [(name: String, swift: SilenceParameters)] = [
        ("default", SilenceParameters()),
        ("conservative", {
            var p = SilenceParameters()
            p.marginDB = 5
            p.minSilenceDuration = .milliseconds(800)
            p.padLead = .milliseconds(300)
            p.padTrail = .milliseconds(500)
            return p
        }()),
        ("tight", {
            var p = SilenceParameters()
            p.marginDB = 12
            p.hysteresisDB = 2
            p.minSpeechDuration = .milliseconds(100)
            p.minSilenceDuration = .milliseconds(250)
            p.padLead = .zero
            p.padTrail = .zero
            return p
        }()),
        ("no fricative protection", {
            var p = SilenceParameters()
            p.fricativeProtection = false
            return p
        }()),
    ]

    // ── Bridging ────────────────────────────────────────────────────────────

    private func swiftFeatures(_ s: Signal) -> FrameFeatures {
        FrameFeatures(rmsDB: s.rms, zeroCrossingRate: s.zcr,
                      spectralFlatness: s.flatness, geometry: .default)
    }

    private func cxxFeatures(_ s: Signal) -> voxscripta.FrameFeatures {
        s.rms.withUnsafeBufferPointer { r in
            s.zcr.withUnsafeBufferPointer { z in
                s.flatness.withUnsafeBufferPointer { f in
                    voxscripta.shim.features(r.baseAddress, z.baseAddress, f.baseAddress,
                                             Int32(s.count), voxscripta.FrameGeometry())
                }
            }
        }
    }

    private func cxxParameters(_ p: SilenceParameters) -> voxscripta.SilenceParameters {
        var c = voxscripta.SilenceParameters()
        c.margin_db = p.marginDB
        c.hysteresis_db = p.hysteresisDB
        c.absolute_floor_db = p.absoluteFloorDB
        c.min_speech_duration = voxscripta.MediaTime(p.minSpeechDuration.nanoseconds)
        c.min_silence_duration = voxscripta.MediaTime(p.minSilenceDuration.nanoseconds)
        c.pad_lead = voxscripta.MediaTime(p.padLead.nanoseconds)
        c.pad_trail = voxscripta.MediaTime(p.padTrail.nanoseconds)
        c.paragraph_pause_threshold = voxscripta.MediaTime(p.paragraphPauseThreshold.nanoseconds)
        c.section_pause_threshold = voxscripta.MediaTime(p.sectionPauseThreshold.nanoseconds)
        c.fricative_protection = p.fricativeProtection
        return c
    }

    private func sourceDuration(_ s: Signal) -> MediaTime {
        FrameGeometry.default.time(ofFrame: s.count)
    }

    /// Runs both detectors and insists they agree about whether there is any
    /// speech at all, returning the Swift map only when there is.
    ///
    /// Refusing the same inputs is a parity property in its own right. A port
    /// that returned an empty map where the original threw would look correct
    /// in every boundary comparison here and be wrong in the one way that
    /// reaches a user: a recording the Mac rejects and Android silently
    /// accepts, producing an empty transcript instead of an explanation.
    private func agreedMap(
        _ signal: Signal, _ parameters: SilenceParameters, _ label: String
    ) throws -> (swift: SilenceMap, cxx: voxscripta.SilenceMap)? {
        let duration = sourceDuration(signal)
        let features = cxxFeatures(signal)
        let cxxParams = cxxParameters(parameters)
        let status = voxscripta.shim.detect_status(
            voxscripta.SilenceDetector(), features, cxxParams,
            voxscripta.MediaTime(duration.nanoseconds))

        do {
            let swiftMap = try SilenceDetector().detect(
                features: swiftFeatures(signal), parameters: parameters,
                sourceDuration: duration, parameterHash: "parity")
            #expect(status == 0, "\(label): Swift found speech, C++ did not (status \(status))")
            guard status == 0 else { return nil }
            let cxxMap = voxscripta.SilenceDetector().detect(
                features, cxxParams, voxscripta.MediaTime(duration.nanoseconds),
                std.string("parity"))
            return (swiftMap, cxxMap)
        } catch VoxScriptaError.noSpeechDetected {
            #expect(status == 1, "\(label): Swift found no speech, C++ returned status \(status)")
            return nil
        }
    }

    // ── The noise floor, on its own ─────────────────────────────────────────

    @Test("The noise floor tracker agrees frame for frame", arguments: names)
    func noiseFloorAgrees(named: String) throws {
        let signal = Self.signal(named)
        let swift = try NoiseFloorTracker.default.track(swiftFeatures(signal))
        let cxx = voxscripta.NoiseFloorTracker().track(cxxFeatures(signal))

        #expect(swift.count == voxscripta.shim.size_of(cxx), "\(named): frame count")
        for i in 0..<Swift.min(swift.count, Int(voxscripta.shim.size_of(cxx))) {
            let theirs = voxscripta.shim.at(cxx, Int32(i))
            #expect(abs(swift[i] - theirs) < Self.tolerance,
                    "\(named): frame \(i) — Swift \(swift[i]), C++ \(theirs)")
        }
    }

    // ── The detector ────────────────────────────────────────────────────────

    @Test("Speech regions land on the same boundaries",
          arguments: names, parameterSets)
    func speechRegionsAgree(
        named: String,
        parameters: (name: String, swift: SilenceParameters)
    ) throws {
        let signal = Self.signal(named)
        let label = "\(named) / \(parameters.name)"
        guard let (swiftMap, cxxMap) =
                try agreedMap(signal, parameters.swift, label) else { return }

        let theirCount = Int(voxscripta.shim.speech_count(cxxMap))
        #expect(swiftMap.speechRegions.count == theirCount, "\(label): region count")
        // Two empty lists agree perfectly. Anything that got past agreedMap
        // has speech in it, so a zero here means the fixture stopped testing
        // what it was written for.
        #expect(theirCount > 0, "\(label): no regions — fixture is vacuous")

        for i in 0..<Swift.min(swiftMap.speechRegions.count, theirCount) {
            let mine = swiftMap.speechRegions[i]
            let theirs = voxscripta.shim.speech_range(cxxMap, Int32(i))
            // Exact: MediaTime is integer nanoseconds, and these boundaries
            // are what chunking consumes.
            #expect(mine.range.start.nanoseconds == theirs.start_time().nanoseconds(),
                    "\(label): region \(i) start")
            #expect(mine.range.end.nanoseconds == theirs.end_time().nanoseconds(),
                    "\(label): region \(i) end")

            let mean = voxscripta.shim.speech_mean_db(cxxMap, Int32(i))
            let peak = voxscripta.shim.speech_peak_db(cxxMap, Int32(i))
            #expect(abs(mine.meanEnergyDB - mean) < Self.tolerance, "\(label): region \(i) mean")
            #expect(abs(mine.peakEnergyDB - peak) < Self.tolerance, "\(label): region \(i) peak")
        }
    }

    @Test("Gaps land on the same boundaries", arguments: names, parameterSets)
    func gapsAgree(
        named: String,
        parameters: (name: String, swift: SilenceParameters)
    ) throws {
        let signal = Self.signal(named)
        let label = "\(named) / \(parameters.name)"
        guard let (swiftMap, cxxMap) =
                try agreedMap(signal, parameters.swift, label) else { return }

        let theirCount = Int(voxscripta.shim.gap_count(cxxMap))
        #expect(swiftMap.gaps.count == theirCount, "\(label): gap count")

        for i in 0..<Swift.min(swiftMap.gaps.count, theirCount) {
            let mine = swiftMap.gaps[i]
            let theirs = voxscripta.shim.gap_range(cxxMap, Int32(i))
            #expect(mine.range.start.nanoseconds == theirs.start_time().nanoseconds(),
                    "\(label): gap \(i) start")
            #expect(mine.range.end.nanoseconds == theirs.end_time().nanoseconds(),
                    "\(label): gap \(i) end")
            let mean = voxscripta.shim.gap_mean_db(cxxMap, Int32(i))
            #expect(abs(mine.meanEnergyDB - mean) < Self.tolerance, "\(label): gap \(i) mean")
        }
    }

    @Test("The noise floor profile in the map agrees", arguments: names)
    func profileAgrees(named: String) throws {
        let signal = Self.signal(named)
        guard let (swiftMap, cxxMap) =
                try agreedMap(signal, SilenceParameters(), named) else { return }

        let theirCount = Int(voxscripta.shim.floor_count(cxxMap))
        #expect(swiftMap.noiseFloorProfile.count == theirCount, "\(named): profile length")
        for i in 0..<Swift.min(swiftMap.noiseFloorProfile.count, theirCount) {
            let theirs = voxscripta.shim.floor_at(cxxMap, Int32(i))
            #expect(abs(swiftMap.noiseFloorProfile[i] - theirs) < Self.tolerance,
                    "\(named): profile \(i)")
        }
    }

    // ── Randomised ──────────────────────────────────────────────────────────

    @Test("Two hundred random signals agree, boundaries exactly")
    func randomSignalsAgree() throws {
        // Hand-picked cases test the shapes someone thought of. A port
        // usually diverges on the one nobody did — a plateau that ends one
        // frame before a threshold, a run of exactly the minimum length.
        // Seeded, so any failure is reproducible from the seed in the
        // message.
        var disagreements: [String] = []

        for seed in 1...200 {
            var state = UInt64(seed) &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            func nextInt(_ bound: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((state >> 33) % UInt64(bound))
            }

            var pattern: [(loud: Int, quiet: Int)] = []
            for _ in 0..<(2 + nextInt(5)) {
                // Spans straddling the 200 ms and 500 ms minimums on purpose.
                pattern.append((loud: 5 + nextInt(60), quiet: 5 + nextInt(120)))
            }
            let signal = Signal(pattern: pattern, seed: UInt64(seed),
                                fricatives: seed % 3 == 0)
            let parameters = Self.parameterSets[seed % Self.parameterSets.count].swift
            let label = "seed \(seed)"

            guard let (swiftMap, cxxMap) =
                    try agreedMap(signal, parameters, label) else { continue }

            let regions = Int(voxscripta.shim.speech_count(cxxMap))
            if swiftMap.speechRegions.count != regions {
                disagreements.append(
                    "\(label): \(swiftMap.speechRegions.count) regions vs \(regions)")
                continue
            }
            for i in 0..<regions {
                let mine = swiftMap.speechRegions[i].range
                let theirs = voxscripta.shim.speech_range(cxxMap, Int32(i))
                if mine.start.nanoseconds != theirs.start_time().nanoseconds()
                    || mine.end.nanoseconds != theirs.end_time().nanoseconds() {
                    disagreements.append(
                        "\(label): region \(i) "
                        + "[\(mine.start.nanoseconds), \(mine.end.nanoseconds)] vs "
                        + "[\(theirs.start_time().nanoseconds()), "
                        + "\(theirs.end_time().nanoseconds())]")
                }
            }

            let gaps = Int(voxscripta.shim.gap_count(cxxMap))
            if swiftMap.gaps.count != gaps {
                disagreements.append("\(label): \(swiftMap.gaps.count) gaps vs \(gaps)")
            }
        }

        let summary = "\(disagreements.count) disagreements: "
            + disagreements.prefix(5).joined(separator: "; ")
        #expect(disagreements.isEmpty, "\(summary)")
    }

    // ── Frame geometry, which everything above is indexed by ────────────────

    @Test("Frame geometry agrees on counts and times",
          arguments: [0, 1, 399, 400, 401, 16_000, 160_000, 1_036_800_000] as [Int64])
    func geometryAgrees(samples: Int64) {
        let swift = FrameGeometry.default
        let cxx = voxscripta.FrameGeometry()

        #expect(swift.windowSamples == Int(cxx.window_samples()))
        #expect(swift.hopSamples == Int(cxx.hop_samples()))
        #expect(swift.frameCount(forSamples: samples) == Int(cxx.frame_count_for_samples(samples)))

        let index = Int(swift.frameCount(forSamples: samples))
        #expect(swift.time(ofFrame: index).nanoseconds
                == cxx.time_of_frame(Int32(index)).nanoseconds())
    }
}
