import Testing
import Foundation
import VoxVerbaCore
@testable import VoxVerbaDSP

/// The DSP stages are implemented as of Phase 1, so what matters here is that
/// malformed input produces a specific, actionable error rather than a crash or a
/// silently empty result.
@Suite("DSP error handling")
struct DSPErrorTests {

    @Test("A missing file is reported as unavailable")
    func missingFile() async {
        await #expect(throws: VoxVerbaError.sourceUnavailable(path: "/nope/a.wav")) {
            try await CanonicalDecoder().probe(url: URL(filePath: "/nope/a.wav"))
        }
        await #expect(throws: VoxVerbaError.sourceUnavailable(path: "/nope/a.wav")) {
            _ = try await CanonicalDecoder().decode(url: URL(filePath: "/nope/a.wav"),
                                                    to: URL(filePath: "/tmp/out.f32")) { _ in }
        }
    }

    @Test("A file that is not audio is reported as an unsupported format")
    func notAudio() async throws {
        let tmp = try TempDirectory()
        let bogus = tmp.url.appending(path: "notaudio.wav")
        try Data("this is not a wave file".utf8).write(to: bogus)
        await #expect(throws: VoxVerbaError.self) {
            try await CanonicalDecoder().probe(url: bogus)
        }
    }

    @Test("Audio shorter than one analysis window is rejected with a reason")
    func tooShortToAnalyze() async throws {
        let tmp = try TempDirectory()
        let raw = tmp.url.appending(path: "tiny.f32")
        try [Float](repeating: 0, count: 100).withUnsafeBufferPointer {
            try Data(buffer: $0).write(to: raw)
        }
        await #expect(throws: VoxVerbaError.self) {
            _ = try await FrameAnalyzer().analyze(canonicalFile: raw, geometry: .default) { _ in }
        }
    }

    @Test("An empty feature set is rejected by the noise floor tracker")
    func emptyFeatures() {
        let empty = FrameFeatures(rmsDB: [], zeroCrossingRate: [], spectralFlatness: [],
                                  geometry: .default)
        #expect(throws: VoxVerbaError.self) {
            try NoiseFloorTracker.default.track(empty)
        }
        #expect(throws: VoxVerbaError.self) {
            try SilenceDetector().detect(features: empty, parameters: .default,
                                         sourceDuration: .seconds(1), parameterHash: "x")
        }
    }

    @Test("Inverted chunk bounds are rejected rather than looping")
    func invertedChunkBounds() throws {
        let map = randomSilenceMap(seed: 3, regionCount: 5)
        let bad = ChunkParameters(minDuration: .seconds(300), maxDuration: .seconds(60),
                                  targetDuration: .seconds(120))
        #expect(throws: VoxVerbaError.self) {
            try ChunkPlanner().plan(silenceMap: map, parameters: bad, parameterHash: "x")
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
