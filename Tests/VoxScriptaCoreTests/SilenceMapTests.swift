import Testing
import Foundation
@testable import VoxScriptaCore

@Suite("SilenceMap timeline mapping")
struct SilenceMapTests {

    /// Speech at 10–20 s and 30–50 s, in a 60 s recording.
    private func makeMap() -> SilenceMap {
        SilenceMap(
            speechRegions: [
                SpeechRegion(range: TimeRange(start: .seconds(10), end: .seconds(20)),
                             meanEnergyDB: -20, peakEnergyDB: -12),
                SpeechRegion(range: TimeRange(start: .seconds(30), end: .seconds(50)),
                             meanEnergyDB: -22, peakEnergyDB: -14),
            ],
            gaps: [
                SilenceGap(range: TimeRange(start: .zero, end: .seconds(10)), meanEnergyDB: -60),
                SilenceGap(range: TimeRange(start: .seconds(20), end: .seconds(30)), meanEnergyDB: -58),
                SilenceGap(range: TimeRange(start: .seconds(50), end: .seconds(60)), meanEnergyDB: -61),
            ],
            noiseFloorProfile: [],
            parameters: .default,
            parameterHash: "test",
            sourceDuration: .seconds(60)
        )
    }

    @Test("Speech duration and fraction")
    func totals() {
        let m = makeMap()
        #expect(m.speechDuration == .seconds(30))
        #expect(abs(m.speechFraction - 0.5) < 1e-9)
    }

    @Test("Original to processed skips the gaps")
    func originalToProcessed() {
        let m = makeMap()
        #expect(m.processedTime(forOriginal: .seconds(10)) == .zero)
        #expect(m.processedTime(forOriginal: .seconds(15)) == .seconds(5))
        #expect(m.processedTime(forOriginal: .seconds(30)) == .seconds(10))
        #expect(m.processedTime(forOriginal: .seconds(35)) == .seconds(15))
    }

    @Test("A position inside a gap has no processed counterpart")
    func gapsReturnNil() {
        let m = makeMap()
        // Returning nil rather than a plausible-looking number is deliberate:
        // the caller must decide what a silent instant means.
        #expect(m.processedTime(forOriginal: .seconds(5)) == nil)
        #expect(m.processedTime(forOriginal: .seconds(25)) == nil)
        #expect(m.processedTime(forOriginal: .seconds(55)) == nil)
    }

    @Test("Processed to original")
    func processedToOriginal() {
        let m = makeMap()
        #expect(m.originalTime(forProcessed: .zero) == .seconds(10))
        #expect(m.originalTime(forProcessed: .seconds(5)) == .seconds(15))
        #expect(m.originalTime(forProcessed: .seconds(10)) == .seconds(30))
        #expect(m.originalTime(forProcessed: .seconds(15)) == .seconds(35))
    }

    @Test("Mapping round-trips for every speech position")
    func roundTrip() {
        let m = makeMap()
        let speechTenths = Array(100...199) + Array(300...499)
        for tenths in speechTenths {
            let original = MediaTime.milliseconds(Double(tenths) * 100)
            guard let processed = m.processedTime(forOriginal: original) else {
                Issue.record("speech position \(original) should map to processed time")
                continue
            }
            #expect(m.originalTime(forProcessed: processed) == original)
        }
    }

    @Test("Processed time past the end clamps to the last speech region")
    func pastEnd() {
        let m = makeMap()
        #expect(m.originalTime(forProcessed: .seconds(1000)) == .seconds(50))
    }
}
