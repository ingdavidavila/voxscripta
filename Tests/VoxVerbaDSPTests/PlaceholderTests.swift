import Testing
import Foundation
import VoxVerbaCore
@testable import VoxVerbaDSP

/// Phase 0 ships API surfaces, not implementations.
///
/// These tests assert that every unimplemented entry point fails loudly and names
/// the phase that fills it in — so nothing in the scaffold can be mistaken for
/// working code, and so the tests turn red the moment an implementation lands
/// without its own coverage.
@Suite("DSP placeholders announce themselves")
struct DSPPlaceholderTests {

    @Test("Decoder")
    func decoder() async {
        let d = CanonicalDecoder()
        await #expect(throws: VoxVerbaError.self) {
            try await d.probe(url: URL(filePath: "/dev/null"))
        }
        await #expect(throws: VoxVerbaError.self) {
            try await d.decode(url: URL(filePath: "/dev/null"),
                               to: URL(filePath: "/dev/null")) { _ in }
        }
    }

    @Test("Analyzer and noise floor tracker")
    func analysis() async {
        await #expect(throws: VoxVerbaError.self) {
            try await FrameAnalyzer().analyze(canonicalFile: URL(filePath: "/dev/null"),
                                              geometry: .default) { _ in }
        }
        let empty = FrameFeatures(rmsDB: [], zeroCrossingRate: [], spectralFlatness: [], geometry: .default)
        #expect(throws: VoxVerbaError.self) {
            try NoiseFloorTracker.default.track(empty)
        }
    }

    @Test("Silence detector")
    func silence() {
        let empty = FrameFeatures(rmsDB: [], zeroCrossingRate: [], spectralFlatness: [], geometry: .default)
        #expect(throws: VoxVerbaError.self) {
            try SilenceDetector().detect(features: empty, parameters: .default,
                                         sourceDuration: .seconds(1), parameterHash: "x")
        }
    }

    @Test("Chunk planner")
    func planner() {
        let map = SilenceMap(speechRegions: [], gaps: [], noiseFloorProfile: [],
                             parameters: .default, parameterHash: "x", sourceDuration: .seconds(1))
        #expect(throws: VoxVerbaError.self) {
            try ChunkPlanner().plan(silenceMap: map, parameters: .default, parameterHash: "x")
        }
    }
}

@Suite("DSP parameter defaults")
struct DSPParameterTests {

    @Test("Silence defaults encode the documented cascade")
    func silenceDefaults() {
        let p = SilenceParameters.default
        // Hysteresis: entering speech is harder than staying in it.
        #expect(p.hysteresisDB > 0)
        // Trailing padding exceeds leading, because word-final decay outlasts onset.
        #expect(p.padTrail > p.padLead)
        // A stop closure is shorter than a real pause.
        #expect(p.minSilenceDuration > p.minSpeechDuration)
        #expect(p.sectionPauseThreshold > p.paragraphPauseThreshold)
        #expect(p.fricativeProtection)
    }

    @Test("The conservative preset cuts less than the default")
    func conservativeIsSafer() {
        let d = SilenceParameters.default
        let c = SilenceParameters.conservative
        #expect(c.marginDB < d.marginDB)             // gates in quieter audio
        #expect(c.minSilenceDuration > d.minSilenceDuration)  // needs longer silence to cut
        #expect(c.padLead > d.padLead)
        #expect(c.padTrail > d.padTrail)
    }

    @Test("Chunk defaults sit in the documented 2–5 minute band")
    func chunkDefaults() {
        let p = ChunkParameters.default
        #expect(p.minDuration == .seconds(120))
        #expect(p.maxDuration == .seconds(300))
        #expect(p.minDuration < p.targetDuration)
        #expect(p.targetDuration < p.maxDuration)
        #expect(p.overlapDuration > .zero)
    }
}
