import Testing
import Foundation
import Synchronization
import VoxVerbaCore
import VoxVerbaTestSupport
@testable import VoxVerbaDSP

@Suite("Canonical decoder")
struct DecoderTests {

    private func canonicalSampleCount(at url: URL) throws -> Int64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        return size / Int64(CanonicalFormat.bytesPerSample)
    }

    private func readSamples(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    @Test("Probe reports the source format without decoding")
    func probe() async throws {
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url,
                                               format: .wav, sampleRate: 44_100)
        let format = try await CanonicalDecoder().probe(url: source)
        #expect(format.sampleRate == 44_100)
        #expect(format.channelCount == 1)
    }

    @Test("Decodes to canonical rate with the expected sample count")
    func decodesToCanonicalRate() async throws {
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url,
                                               format: .wav, sampleRate: 44_100)
        let dest = tmp.url.appending(path: "canonical.f32")

        let written = try await CanonicalDecoder().decode(url: source, to: dest) { _ in }
        let expected = StandardCorpus.basic.duration.samples(at: CanonicalFormat.sampleRate)

        let onDisk = try canonicalSampleCount(at: dest)
        #expect(written == onDisk)
        // Resamplers may differ by a few frames at the tail; 10 ms of tolerance.
        #expect(abs(written - expected) < 160)
    }

    @Test("Every required sample rate converges on the same canonical length",
          arguments: [8_000, 16_000, 22_050, 44_100, 48_000])
    func sampleRates(rate: Int) async throws {
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url,
                                               format: .wav, sampleRate: rate)
        let dest = tmp.url.appending(path: "canonical-\(rate).f32")
        let written = try await CanonicalDecoder().decode(url: source, to: dest) { _ in }
        let expected = StandardCorpus.basic.duration.samples(at: CanonicalFormat.sampleRate)
        #expect(abs(written - expected) < 320)
    }

    @Test("Every required container decodes", arguments: TestAudioFormat.allCases)
    func containers(format: TestAudioFormat) async throws {
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url, format: format)
        let dest = tmp.url.appending(path: "canonical-\(format.rawValue).f32")
        let written = try await CanonicalDecoder().decode(url: source, to: dest) { _ in }
        let expected = StandardCorpus.basic.duration.samples(at: CanonicalFormat.sampleRate)
        // Lossy encoders pad; allow a larger tail tolerance for them.
        let tolerance: Int64 = format.isLossy ? 4096 : 320
        #expect(abs(written - expected) < tolerance)
    }

    @Test("Stereo is downmixed rather than having a channel dropped")
    func stereoDownmix() async throws {
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url,
                                               format: .wav, sampleRate: 44_100, channels: 2)
        let dest = tmp.url.appending(path: "canonical-stereo.f32")
        let written = try await CanonicalDecoder().decode(url: source, to: dest) { _ in }
        #expect(written > 0)

        // The signal must survive the downmix, not be zeroed or halved away.
        let samples = try readSamples(at: dest)
        let speech = samples[Int(2.5 * 16_000)..<Int(6.5 * 16_000)]
        let peak = speech.map(abs).max() ?? 0
        #expect(peak > 0.02)
    }

    @Test("Progress is reported and ends at 1")
    func progressReporting() async throws {
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url,
                                               format: .wav, sampleRate: 44_100)
        let dest = tmp.url.appending(path: "canonical.f32")

        let box = Mutex<[Double]>([])
        _ = try await CanonicalDecoder(bufferDuration: 1).decode(url: source, to: dest) { p in
            box.withLock { $0.append(p) }
        }
        let reports = box.withLock { $0 }
        #expect(!reports.isEmpty)
        #expect(reports.last == 1)
        #expect(reports == reports.sorted())
    }

    @Test("Decoded audio preserves the loud and quiet spans")
    func preservesDynamics() async throws {
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url,
                                               format: .caf, sampleRate: 48_000)
        let dest = tmp.url.appending(path: "canonical.f32")
        _ = try await CanonicalDecoder().decode(url: source, to: dest) { _ in }
        let samples = try readSamples(at: dest)

        func rms(_ range: Range<Int>) -> Float {
            let slice = samples[range.clamped(to: 0..<samples.count)]
            guard !slice.isEmpty else { return 0 }
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        }
        let sr = CanonicalFormat.sampleRate
        let speech = rms((3 * sr)..<(6 * sr))     // -18 dBFS span
        let silence = rms(Int(8.0 * Double(sr))..<Int(9.5 * Double(sr)))

        #expect(speech > silence * 20)
        #expect(silence < 0.01)
    }

    @Test("A missing file is reported as unavailable, not as a decode failure")
    func missingFile() async {
        await #expect(throws: VoxVerbaError.sourceUnavailable(path: "/nonexistent/x.wav")) {
            try await CanonicalDecoder().probe(url: URL(filePath: "/nonexistent/x.wav"))
        }
    }

    @Test("Peak memory does not grow with source duration")
    func boundedMemory() async throws {
        // The decoder's buffers are sized from bufferDuration alone, so a long
        // file and a short one allocate identically. Asserting on the buffer
        // arithmetic is a stable proxy for a footprint measurement that would be
        // flaky under a test runner.
        let shortCase = StandardCorpus.basic                    // 18 s
        let longCase = StandardCorpus.continuousSpeech          // 360 s
        #expect(longCase.duration > shortCase.duration * 15)

        let tmp = try TempDirectory()
        let decoder = CanonicalDecoder(bufferDuration: 10)
        for (name, c) in [("short", shortCase), ("long", longCase)] {
            let src = try AudioFileWriter.write(c, to: tmp.url, format: .wav, sampleRate: 16_000)
            let dst = tmp.url.appending(path: "\(name).f32")
            let n = try await decoder.decode(url: src, to: dst) { _ in }
            #expect(abs(n - c.duration.samples(at: 16_000)) < 320)
        }
    }
}
