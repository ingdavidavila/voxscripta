import Testing
import Foundation
import VoxVerbaCore
import VoxVerbaTestSupport
@testable import VoxVerbaDSP

/// Runs a corpus case through the real analysis chain.
struct DetectionRun {
    let testCase: CorpusCase
    let features: FrameFeatures
    let map: SilenceMap

    init(_ testCase: CorpusCase, parameters: SilenceParameters = .default) async throws {
        self.testCase = testCase
        let tmp = try TempDirectory()
        let raw = try tmp.writeCanonical(testCase.render())
        features = try await FrameAnalyzer().analyze(canonicalFile: raw, geometry: .default) { _ in }
        map = try SilenceDetector().detect(
            features: features,
            parameters: parameters,
            sourceDuration: testCase.duration,
            parameterHash: "test"
        )
    }

    /// Fraction of ground-truth speech time the detector covered.
    ///
    /// Recall is the metric that matters most: missing speech loses words
    /// permanently, whereas keeping some extra silence only costs a little time.
    var speechRecall: Double {
        let truth = testCase.expectedSpeechRegions
        let total = truth.reduce(0.0) { $0 + $1.duration.seconds }
        guard total > 0 else { return 1 }
        var covered = 0.0
        for t in truth {
            for d in map.speechRegions {
                if let overlap = t.intersection(d.range) { covered += overlap.duration.seconds }
            }
        }
        return covered / total
    }

    /// Fraction of ground-truth silence the detector correctly excluded.
    var silenceRejection: Double {
        var silence: [TimeRange] = []
        var cursor = MediaTime.zero
        for r in testCase.expectedSpeechRegions {
            if r.start > cursor { silence.append(TimeRange(start: cursor, end: r.start)) }
            cursor = r.end
        }
        if cursor < testCase.duration {
            silence.append(TimeRange(start: cursor, end: testCase.duration))
        }
        let total = silence.reduce(0.0) { $0 + $1.duration.seconds }
        guard total > 0 else { return 1 }
        var kept = 0.0
        for s in silence {
            for d in map.speechRegions {
                if let overlap = s.intersection(d.range) { kept += overlap.duration.seconds }
            }
        }
        return 1 - (kept / total)
    }
}

@Suite("Silence detection against synthetic ground truth")
struct SilenceDetectorTests {

    @Test("Baseline: speech is found and silence is rejected")
    func basic() async throws {
        let run = try await DetectionRun(StandardCorpus.basic)
        #expect(run.map.speechRegions.count == 2)
        #expect(run.speechRecall > 0.99)
        // Padding deliberately keeps some silence, so this is not near 1.
        #expect(run.silenceRejection > 0.70)
    }

    @Test("A quiet speaker at -38 dBFS is not gated out")
    func quietSpeaker() async throws {
        // The case a fixed threshold fails. The adaptive floor should track down
        // to the room and still find speech 24 dB above it.
        let run = try await DetectionRun(StandardCorpus.quietSpeaker)
        #expect(run.speechRecall > 0.98)
        #expect(run.map.speechRegions.count == 2)
    }

    @Test("Trailing fricatives are not truncated")
    func fricatives() async throws {
        let withProtection = try await DetectionRun(StandardCorpus.fricatives)
        #expect(withProtection.speechRecall > 0.97)

        // The control: the same audio with stage 3 disabled must do measurably
        // worse, which is what proves the stage is doing the work rather than
        // padding masking the problem.
        var off = SilenceParameters.default
        off.fricativeProtection = false
        off.padTrail = .zero
        var on = SilenceParameters.default
        on.padTrail = .zero

        let withStage = try await DetectionRun(StandardCorpus.fricatives, parameters: on)
        let withoutStage = try await DetectionRun(StandardCorpus.fricatives, parameters: off)
        #expect(withStage.speechRecall > withoutStage.speechRecall)
    }

    @Test("Stop closures do not fragment a word")
    func stopClosures() async throws {
        // 60 ms closures every 400 ms across a 10 s span. A detector without
        // minimum-silence gating reports ~25 regions here.
        let run = try await DetectionRun(StandardCorpus.stopClosures)
        #expect(run.map.speechRegions.count == 1)
        #expect(run.speechRecall > 0.99)
    }

    @Test("A five-second pause is preserved as a boundary")
    func longPause() async throws {
        // §7: this gap has to survive, because the merger turns it into a
        // paragraph break.
        let run = try await DetectionRun(StandardCorpus.longPause)
        #expect(run.map.speechRegions.count == 2)

        let gap = run.map.gaps.first { $0.duration > .seconds(3) }
        #expect(gap != nil)
        #expect(gap!.duration > .seconds(4))
        #expect(gap!.duration < .seconds(5))   // padding eats into it from both sides
    }

    @Test("A rising noise floor is tracked rather than fixed")
    func risingNoiseFloor() async throws {
        let run = try await DetectionRun(StandardCorpus.risingNoiseFloor)
        #expect(run.speechRecall > 0.97)
        #expect(run.map.speechRegions.count == 2)
    }

    @Test("Speech survives a loud room")
    func noisyRoom() async throws {
        let run = try await DetectionRun(StandardCorpus.noisyRoom)
        #expect(run.speechRecall > 0.95)
    }

    @Test("Continuous speech yields one region covering the recording")
    func continuousSpeech() async throws {
        let run = try await DetectionRun(StandardCorpus.continuousSpeech)
        #expect(run.map.speechRegions.count == 1)
        #expect(run.map.speechFraction > 0.98)
    }

    @Test("Detection is deterministic")
    func deterministic() async throws {
        // Reproducibility is what makes resume correct and tests meaningful.
        let a = try await DetectionRun(StandardCorpus.basic)
        let b = try await DetectionRun(StandardCorpus.basic)
        #expect(a.map.speechRegions.map(\.range) == b.map.speechRegions.map(\.range))
    }

    @Test("The conservative preset never keeps less speech than the default")
    func conservativeKeepsMore() async throws {
        for testCase in [StandardCorpus.quietSpeaker, StandardCorpus.noisyRoom] {
            let d = try await DetectionRun(testCase, parameters: .default)
            let c = try await DetectionRun(testCase, parameters: .conservative)
            #expect(c.speechRecall >= d.speechRecall - 0.001)
        }
    }

    /// Mean absolute error between detected boundaries and padding-adjusted truth.
    ///
    /// Padding deliberately moves boundaries outward, so the comparison is against
    /// truth expanded by the same padding — otherwise the metric would just measure
    /// the padding constants.
    @Test("Boundary error stays within tolerance on clean material")
    func boundaryError() async throws {
        let params = SilenceParameters.default
        var errors: [Double] = []

        for testCase in [StandardCorpus.basic, StandardCorpus.longPause, StandardCorpus.quietSpeaker] {
            let run = try await DetectionRun(testCase, parameters: params)
            let media = TimeRange(start: .zero, end: testCase.duration)
            let truth = testCase.expectedSpeechRegions.map {
                $0.padded(lead: params.padLead, trail: params.padTrail, within: media)
            }
            #expect(run.map.speechRegions.count == truth.count,
                    "\(testCase.name): region count")
            guard run.map.speechRegions.count == truth.count else { continue }

            for (detected, expected) in zip(run.map.speechRegions, truth) {
                errors.append(abs((detected.range.start - expected.start).seconds))
                errors.append(abs((detected.range.end - expected.end).seconds))
            }
        }

        let mae = errors.reduce(0, +) / Double(errors.count)
        let worst = errors.max() ?? 0
        #expect(mae < 0.050, "mean boundary error \(mae)s exceeds 50 ms")
        #expect(worst < 0.150, "worst boundary error \(worst)s exceeds 150 ms")
    }

    @Test("Repeated runs produce byte-identical results")
    func repeatable() async throws {
        // Reproducibility is the property the whole resume design rests on.
        let reference = try await DetectionRun(StandardCorpus.fricatives)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(reference.map.speechRegions)

        for _ in 0..<8 {
            let run = try await DetectionRun(StandardCorpus.fricatives)
            #expect(try encoder.encode(run.map.speechRegions) == expected)
        }
    }

    @Test("A recording with no speech reports no speech")
    func roomToneOnly() async throws {
        // The regression the flatness gate exists to prevent. Loud room tone is
        // homogeneous in level exactly like pause-free speech; if the noise-floor
        // cap fired here it would drag the floor down 20 dB and report hiss as
        // speech for the full recording.
        await #expect(throws: VoxVerbaError.noSpeechDetected) {
            _ = try await DetectionRun(StandardCorpus.roomToneOnly)
        }
    }

    @Test("Every speech region carries plausible energy measurements")
    func energyMeasurements() async throws {
        let run = try await DetectionRun(StandardCorpus.basic)
        for region in run.map.speechRegions {
            #expect(region.peakEnergyDB >= region.meanEnergyDB)
            #expect(region.meanEnergyDB > -60)
            #expect(region.peakEnergyDB < 0)
        }
    }

    @Test("Regions are ordered, disjoint, and inside the recording")
    func structuralInvariants() async throws {
        for testCase in StandardCorpus.all where testCase.name != "room_tone_only" {
            let run = try await DetectionRun(testCase)
            let regions = run.map.speechRegions
            for r in regions {
                #expect(r.range.start >= .zero)
                #expect(r.range.end <= testCase.duration)
            }
            for (a, b) in zip(regions, regions.dropFirst()) {
                #expect(a.range.end <= b.range.start)
            }
            #expect(run.map.speechDuration <= testCase.duration)
        }
    }
}
