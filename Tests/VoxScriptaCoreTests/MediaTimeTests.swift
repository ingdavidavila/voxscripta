import Testing
import Foundation
@testable import VoxScriptaCore

@Suite("MediaTime")
struct MediaTimeTests {

    @Test("Sample conversion is exact at the canonical rate")
    func sampleRoundTrip() {
        for samples in [Int64(0), 1, 160, 16_000, 345_600_000] {
            let t = MediaTime(samples: samples, sampleRate: 16_000)
            #expect(t.samples(at: 16_000) == samples)
        }
    }

    @Test("Six hours of accumulation introduces no drift")
    func noAccumulationDrift() {
        // The whole reason timing is stored as integer nanoseconds: adding
        // thousands of chunk offsets must not wander.
        let hop = MediaTime.milliseconds(10)
        var sum = MediaTime.zero
        for _ in 0..<2_160_000 { sum = sum + hop }   // 6 hours of 10 ms frames
        #expect(sum == MediaTime.seconds(21_600))
        #expect(sum.nanoseconds == 21_600_000_000_000)
    }

    @Test("Ordering and arithmetic")
    func arithmetic() {
        let a = MediaTime.seconds(1.5)
        let b = MediaTime.milliseconds(500)
        #expect(a + b == MediaTime.seconds(2))
        #expect(a - b == MediaTime.seconds(1))
        #expect(b < a)
        #expect(MediaTime.max(a, b) == a)
        #expect(MediaTime.min(a, b) == b)
    }

    @Test("Clamping to a range")
    func clamping() {
        let range = MediaTime.zero...MediaTime.seconds(10)
        #expect(MediaTime.seconds(-5).clamped(to: range) == .zero)
        #expect(MediaTime.seconds(50).clamped(to: range) == .seconds(10))
        #expect(MediaTime.seconds(5).clamped(to: range) == .seconds(5))
    }

    @Test("Description formats for display")
    func description() {
        #expect(MediaTime.seconds(0).description == "0:00.000")
        #expect(MediaTime.seconds(65.25).description == "1:05.250")
        #expect(MediaTime.seconds(3725.5).description == "1:02:05.500")
        #expect(MediaTime.seconds(-1.5).description == "-0:01.500")
    }

    @Test("Codable round-trips exactly")
    func codable() throws {
        let t = MediaTime(nanoseconds: 123_456_789_012)
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(MediaTime.self, from: data) == t)
    }
}

@Suite("TimeRange")
struct TimeRangeTests {

    @Test("Half-open ranges tile without overlap")
    func halfOpen() {
        let a = TimeRange(start: .seconds(0), end: .seconds(10))
        let b = TimeRange(start: .seconds(10), end: .seconds(20))
        #expect(!a.overlaps(b))
        #expect(a.intersection(b) == nil)
        #expect(!a.contains(.seconds(10)))
        #expect(b.contains(.seconds(10)))
    }

    @Test("Intersection")
    func intersection() {
        let a = TimeRange(start: .seconds(0), end: .seconds(10))
        let b = TimeRange(start: .seconds(5), end: .seconds(15))
        #expect(a.intersection(b) == TimeRange(start: .seconds(5), end: .seconds(10)))
        #expect(a.overlaps(b))
    }

    @Test("Padding expands outward only and clamps to the media")
    func padding() {
        let media = TimeRange(start: .zero, end: .seconds(60))
        let r = TimeRange(start: .seconds(0.1), end: .seconds(59.9))
        let padded = r.padded(lead: .milliseconds(200), trail: .milliseconds(350), within: media)
        // Clamped at both ends rather than running off the recording.
        #expect(padded.start == .zero)
        #expect(padded.end == .seconds(60))

        let inner = TimeRange(start: .seconds(10), end: .seconds(20))
        let p2 = inner.padded(lead: .milliseconds(200), trail: .milliseconds(350), within: media)
        #expect(p2.start == .milliseconds(9800))
        #expect(p2.end == .milliseconds(20350))
        #expect(p2.duration > inner.duration)
    }

    @Test("SampleRange maps to bytes and time")
    func sampleRange() {
        let r = SampleRange(start: 16_000, count: 32_000)
        #expect(r.end == 48_000)
        #expect(r.byteRange == 64_000..<192_000)
        let t = r.timeRange(at: 16_000)
        #expect(t.start == .seconds(1))
        #expect(t.end == .seconds(3))
        #expect(t.duration == .seconds(2))
    }
}
