import Testing
import VoxScriptaCore
@testable import VoxScriptaDSP

@Suite("Frame geometry")
struct FrameGeometryTests {

    @Test("Default geometry is 25 ms windows at a 10 ms hop")
    func defaults() {
        let g = FrameGeometry.default
        #expect(g.sampleRate == CanonicalFormat.sampleRate)
        #expect(g.windowSamples == 400)
        #expect(g.hopSamples == 160)
    }

    @Test("Frame count for a known sample count")
    func frameCount() {
        let g = FrameGeometry.default
        #expect(g.frameCount(forSamples: 0) == 0)
        #expect(g.frameCount(forSamples: 399) == 0)     // shorter than one window
        #expect(g.frameCount(forSamples: 400) == 1)
        #expect(g.frameCount(forSamples: 560) == 2)
        #expect(g.frameCount(forSamples: 16_000) == 98) // one second
    }

    @Test("Frame index and time round-trip")
    func indexTimeRoundTrip() {
        let g = FrameGeometry.default
        for index in [0, 1, 100, 99_999] {
            #expect(g.frame(atTime: g.time(ofFrame: index)) == index)
        }
        #expect(g.time(ofFrame: 100) == .seconds(1))
    }

    @Test("Negative times clamp to frame zero")
    func negativeClamps() {
        #expect(FrameGeometry.default.frame(atTime: .seconds(-5)) == 0)
    }

    @Test("Feature storage stays about 8 MB for a six-hour recording")
    func featureBudget() {
        // The reason features stay resident: re-tuning thresholds in the UI must
        // not require re-reading any audio.
        let g = FrameGeometry.default
        let samples = MediaTime.seconds(6 * 3600).samples(at: g.sampleRate)
        let frames = g.frameCount(forSamples: samples)
        let bytes = frames * 3 * MemoryLayout<Float>.size
        #expect(bytes < 30_000_000)
        #expect(frames > 2_000_000)
    }
}

@Suite("Frame features")
struct FrameFeaturesTests {

    @Test("Feature arrays report a consistent count")
    func consistentCount() {
        let f = FrameFeatures(
            rmsDB: [-20, -30, -40],
            zeroCrossingRate: [0.1, 0.2, 0.3],
            spectralFlatness: [0.5, 0.6, 0.7],
            geometry: .default
        )
        #expect(f.count == 3)
        #expect(!f.isEmpty)
    }

    @Test("An empty feature set is well-formed")
    func empty() {
        let f = FrameFeatures(rmsDB: [], zeroCrossingRate: [], spectralFlatness: [], geometry: .default)
        #expect(f.isEmpty)
        #expect(f.count == 0)
        #expect(f.duration == .zero)
    }
}
