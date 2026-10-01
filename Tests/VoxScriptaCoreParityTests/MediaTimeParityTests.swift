import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaCoreCxx

/// Holds the C++ port and the Swift original to the same answers.
///
/// Porting by eye is how a migration acquires silent behaviour changes: a
/// rounding mode that differs on ties, an integer division that truncates the
/// other way, a format string off by a digit. None of those show up in a unit
/// test written against the port alone, because the port's own tests encode
/// whatever the port does.
///
/// So both implementations run side by side over the same inputs, including
/// adversarial ones, and any disagreement is a failure. These tests exist only
/// for the duration of the migration and are deleted with the Swift module they
/// check.
@Suite("MediaTime parity")
struct MediaTimeParityTests {

    /// Values chosen to catch the ways two implementations usually diverge:
    /// zero, signs, tie-rounding, and magnitudes near the limits of the type.
    private static let nanosecondCases: [Int64] = [
        0, 1, -1, 999, 1_000, 1_500, -1_500,
        500_000, 1_000_000, 999_999_999, 1_000_000_000,
        21_600_000_000_000,              // six hours
        -21_600_000_000_000,
        3_725_500_000_000,               // 1:02:05.500
        123_456_789_012,
        Int64(Int32.max), Int64(Int32.min),
        172_800_000_000_000,             // 48 hours
        -172_800_000_000_000,
    ]

    /// Beyond this the two implementations stop agreeing, and the test says so
    /// rather than avoiding the subject. `samples(at:)` multiplies nanoseconds
    /// by the rate before dividing, which overflows Int64 past roughly 53 hours
    /// at 48 kHz. Swift traps; the C++ port throws std::overflow_error, because
    /// signed overflow is undefined behaviour in C++ and a core that a bridge
    /// calls into must not hand the optimiser a free hand. Six-hour recordings,
    /// the longest the app targets, sit three orders of magnitude inside the
    /// limit. Parity is therefore asserted over the representable domain only.

    @Test("Seconds conversion agrees", arguments: nanosecondCases)
    func secondsAgree(nanoseconds: Int64) {
        let swift = MediaTime(nanoseconds: nanoseconds)
        let cxx = voxscripta.MediaTime(nanoseconds)
        #expect(swift.seconds == cxx.seconds())
    }

    @Test("Sample conversion agrees at every rate the app uses",
          arguments: nanosecondCases, [16_000, 44_100, 48_000])
    func samplesAgree(nanoseconds: Int64, rate: Int) {
        let swift = MediaTime(nanoseconds: nanoseconds)
        let cxx = voxscripta.MediaTime(nanoseconds)
        #expect(swift.samples(at: rate) == cxx.samples_at(Int32(rate)))
    }

    @Test("Construction from seconds agrees, ties included")
    func fromSecondsAgrees() {
        // 0.0005 and friends sit exactly on a tie, which is where a rounding
        // mode mismatch would show.
        let values: [Double] = [0, 1, -1, 0.5, -0.5, 1.5, -1.5, 0.0005, -0.0005,
                                0.1, 1.0 / 3.0, 59.9, 3725.5, 21_600, -21_600]
        for value in values {
            let swift = MediaTime(seconds: value)
            let cxx = voxscripta.MediaTime.from_seconds(value)
            #expect(swift.nanoseconds == cxx.nanoseconds(),
                    "disagreement at \(value) s")
        }
    }

    @Test("Construction from samples agrees")
    func fromSamplesAgrees() {
        for samples: Int64 in [0, 1, 160, 16_000, 345_600_000, 1_000_000_007] {
            for rate in [16_000, 44_100, 48_000] {
                let swift = MediaTime(samples: samples, sampleRate: rate)
                let cxx = voxscripta.MediaTime.from_samples(samples, Int32(rate))
                #expect(swift.nanoseconds == cxx.nanoseconds(),
                        "disagreement at \(samples) @ \(rate)")
            }
        }
    }

    @Test("Display formatting agrees", arguments: nanosecondCases)
    func descriptionAgrees(nanoseconds: Int64) {
        let swift = MediaTime(nanoseconds: nanoseconds)
        let cxx = voxscripta.MediaTime(nanoseconds)
        #expect(swift.description == String(cxx.to_string()))
    }

    @Test("Arithmetic agrees over random pairs")
    func arithmeticAgrees() {
        // Seeded so a failure is reproducible from the message alone.
        var generator = SystemRandomNumberGenerator()
        var seed: UInt64 = 0x766F_7873_6372_7074
        func next() -> Int64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int64(bitPattern: seed >> 16) % 100_000_000_000_000
        }
        _ = generator

        for _ in 0..<2_000 {
            let a = next(), b = next()
            let swiftA = MediaTime(nanoseconds: a), swiftB = MediaTime(nanoseconds: b)
            let cxxA = voxscripta.MediaTime(a), cxxB = voxscripta.MediaTime(b)

            #expect((swiftA + swiftB).nanoseconds == (cxxA + cxxB).nanoseconds())
            #expect((swiftA - swiftB).nanoseconds == (cxxA - cxxB).nanoseconds())
            #expect((swiftA < swiftB) == (cxxA < cxxB))
            #expect(MediaTime.max(swiftA, swiftB).nanoseconds
                    == voxscripta.MediaTime.max(cxxA, cxxB).nanoseconds())
            #expect(MediaTime.min(swiftA, swiftB).nanoseconds
                    == voxscripta.MediaTime.min(cxxA, cxxB).nanoseconds())
        }
    }

    @Test("Scaling agrees")
    func scalingAgrees() {
        for nanoseconds: Int64 in [0, 1_000_000_000, -1_000_000_000, 21_600_000_000_000] {
            for factor in [0.0, 0.5, 1.0, 1.5, 2.0, -1.0, 0.333] {
                let swift = MediaTime(nanoseconds: nanoseconds) * factor
                let cxx = voxscripta.MediaTime(nanoseconds) * factor
                #expect(swift.nanoseconds == cxx.nanoseconds(),
                        "disagreement scaling \(nanoseconds) by \(factor)")
            }
        }
    }

    @Test("Clamping agrees")
    func clampingAgrees() {
        let lower = MediaTime.zero, upper = MediaTime.seconds(10)
        let cxxLower = voxscripta.MediaTime(0)
        let cxxUpper = voxscripta.MediaTime(10_000_000_000)
        for nanoseconds: Int64 in [-5_000_000_000, 0, 5_000_000_000, 10_000_000_000,
                                   50_000_000_000] {
            let swift = MediaTime(nanoseconds: nanoseconds).clamped(to: lower...upper)
            let cxx = voxscripta.MediaTime(nanoseconds).clamped(cxxLower, cxxUpper)
            #expect(swift.nanoseconds == cxx.nanoseconds())
        }
    }
}

@Suite("TimeRange parity")
struct TimeRangeParityTests {

    private func pair(_ a: Int64, _ b: Int64) -> (TimeRange, voxscripta.TimeRange) {
        (TimeRange(start: MediaTime(nanoseconds: a), end: MediaTime(nanoseconds: b)),
         voxscripta.TimeRange(voxscripta.MediaTime(a), voxscripta.MediaTime(b)))
    }

    @Test("Containment and overlap agree")
    func containmentAgrees() {
        let (swiftA, cxxA) = pair(0, 10_000_000_000)
        let (swiftB, cxxB) = pair(5_000_000_000, 15_000_000_000)
        let (swiftC, cxxC) = pair(10_000_000_000, 20_000_000_000)

        #expect(swiftA.overlaps(swiftB) == cxxA.overlaps(cxxB))
        #expect(swiftA.overlaps(swiftC) == cxxA.overlaps(cxxC))

        for probe: Int64 in [-1, 0, 5_000_000_000, 10_000_000_000, 11_000_000_000] {
            #expect(swiftA.contains(MediaTime(nanoseconds: probe))
                    == cxxA.contains(voxscripta.MediaTime(probe)))
        }
    }

    @Test("Intersection agrees, including the touching case")
    func intersectionAgrees() {
        let cases: [(Int64, Int64, Int64, Int64)] = [
            (0, 10, 5, 15),      // overlapping
            (0, 10, 10, 20),     // touching, must be empty in both
            (0, 10, 20, 30),     // disjoint
            (0, 100, 10, 20),    // contained
        ]
        for (a, b, c, d) in cases {
            let scale: Int64 = 1_000_000_000
            let (swiftX, cxxX) = pair(a * scale, b * scale)
            let (swiftY, cxxY) = pair(c * scale, d * scale)

            let swiftResult = swiftX.intersection(swiftY)
            let cxxResult = cxxX.intersection(cxxY)

            #expect((swiftResult == nil) == !cxxResult.hasValue,
                    "presence disagreement for \(a)-\(b) vs \(c)-\(d)")
            if let swiftResult, cxxResult.hasValue {
                let value = cxxResult.pointee
                #expect(swiftResult.start.nanoseconds == value.start_time().nanoseconds())
                #expect(swiftResult.end.nanoseconds == value.end_time().nanoseconds())
            }
        }
    }

    @Test("Asymmetric padding agrees, clamping included")
    func paddingAgrees() {
        let scale: Int64 = 1_000_000_000
        let (swiftLimit, cxxLimit) = pair(0, 60 * scale)
        let cases: [(Int64, Int64)] = [(100_000_000, 59_900_000_000),
                                       (10 * scale, 20 * scale),
                                       (0, 60 * scale),
                                       (30 * scale, 30 * scale)]
        for (start, end) in cases {
            let (swiftRange, cxxRange) = pair(start, end)
            let swiftPadded = swiftRange.padded(lead: .milliseconds(200),
                                                trail: .milliseconds(350),
                                                within: swiftLimit)
            let cxxPadded = cxxRange.padded(voxscripta.MediaTime.milliseconds(200),
                                            voxscripta.MediaTime.milliseconds(350),
                                            cxxLimit)
            #expect(swiftPadded.start.nanoseconds == cxxPadded.start_time().nanoseconds())
            #expect(swiftPadded.end.nanoseconds == cxxPadded.end_time().nanoseconds())
        }
    }

    @Test("SampleRange agrees on bytes and time")
    func sampleRangeAgrees() {
        for (start, count) in [(Int64(0), Int64(0)), (16_000, 32_000),
                               (1, 1), (345_600_000, 16_000)] {
            let swift = SampleRange(start: start, count: count)
            let cxx = voxscripta.SampleRange(start, count)

            #expect(swift.end == cxx.end_index())
            #expect(swift.byteRange.lowerBound == Int(cxx.byte_begin()))
            #expect(swift.byteRange.upperBound == Int(cxx.byte_end()))

            let swiftTime = swift.timeRange(at: 16_000)
            let cxxTime = cxx.time_range_at(16_000)
            #expect(swiftTime.start.nanoseconds == cxxTime.start_time().nanoseconds())
            #expect(swiftTime.end.nanoseconds == cxxTime.end_time().nanoseconds())
        }
    }
}
