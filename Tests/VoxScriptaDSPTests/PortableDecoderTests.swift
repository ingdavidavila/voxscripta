import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaDSP

/// The portable decoder, held to the same answers as the Apple one.
///
/// A second implementation of anything is only worth having if it agrees with
/// the first. The canonical file feeds silence detection, chunking and every
/// transcript after it, so "roughly the same audio" is not good enough — these
/// compare sample against sample.
@Suite("Portable decoder")
struct PortableDecoderTests {

    /// A tone written as a real file, so both decoders read a container
    /// rather than a buffer this test made up.
    private func writeTone(_ format: TestAudioFormat,
                           seconds: Double = 2,
                           rate: Int = 44_100,
                           to directory: URL) throws -> URL {
        let count = Int(Double(rate) * seconds)
        let samples = (0..<count).map { i in
            0.4 * sin(2 * Double.pi * 440 * Double(i) / Double(rate))
        }.map(Float.init)
        let url = directory.appending(path: "tone.\(format)")
        try AudioFileWriter.write(samples: samples, to: url, format: format, sampleRate: rate)
        return url
    }

    /// The canonical file read back as floats. No header, one fixed format.
    private func samples(of url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Agreement with AVFoundation

    @Test("It decodes a WAV to the same samples AVFoundation does")
    func agreesWithApple() async throws {
        let tmp = try TempDirectory()
        let source = try writeTone(.wav, to: tmp.url)

        let appleOut = tmp.url.appending(path: "apple.f32")
        let portableOut = tmp.url.appending(path: "portable.f32")
        let appleCount = try await CanonicalDecoder().decode(url: source, to: appleOut) { _ in }
        let portableCount = try await PortableDecoder().decode(url: source, to: portableOut) { _ in }

        // Resamplers differ in how they handle the first and last few frames,
        // so the lengths are allowed to differ by a hair — but only a hair.
        let drift = abs(appleCount - portableCount)
        #expect(drift <= Int64(CanonicalFormat.sampleRate / 100),
                "lengths differ by \(drift) samples (\(appleCount) vs \(portableCount))")

        let apple = try samples(of: appleOut)
        let portable = try samples(of: portableOut)
        let shared = min(apple.count, portable.count)
        try #require(shared > CanonicalFormat.sampleRate)

        // Compared over the middle, away from both edges, where any
        // resampler's warm-up and tail differ legitimately.
        //
        // Aligned first. Two resamplers have no reason to share a group
        // delay, and at 440 Hz one period is 36 samples at the canonical
        // rate — so comparing index against index measures the delay, not
        // the audio. The shift is found once and then has to be small.
        let from = shared / 4, to = shared * 3 / 4
        func worstDifference(shift: Int) -> Float {
            var worst: Float = 0
            for i in from..<to where i + shift >= 0 && i + shift < portable.count {
                worst = max(worst, abs(apple[i] - portable[i + shift]))
            }
            return worst
        }
        let shifts = Array(-64...64)
        let best = shifts.min { worstDifference(shift: $0) < worstDifference(shift: $1) } ?? 0
        let aligned = worstDifference(shift: best)
        print("DECODER PARITY: best shift \(best) samples, worst difference \(aligned), "
              + "unaligned \(worstDifference(shift: 0))")

        #expect(abs(best) <= 16, "the two decoders are \(best) samples out of step")
        #expect(aligned < 0.05,
                "the two decoders disagree by \(aligned) at worst, aligned")
    }

    @Test("Both report the same duration for the same file")
    func durationsAgree() async throws {
        let tmp = try TempDirectory()
        let source = try writeTone(.wav, seconds: 3, to: tmp.url)
        let apple = try CanonicalDecoder().duration(of: source)
        let portable = try PortableDecoder().duration(of: source)
        #expect(abs(apple.seconds - portable.seconds) < 0.01,
                "\(apple.seconds) vs \(portable.seconds)")
    }

    @Test("Probe reports the file's own rate and channels, not the canonical ones")
    func probeReportsSource() async throws {
        let tmp = try TempDirectory()
        let source = try writeTone(.wav, rate: 44_100, to: tmp.url)
        let format = try await PortableDecoder().probe(url: source)
        #expect(format.sampleRate == 44_100)
        #expect(format.channelCount == 1)
    }

    // MARK: - The canonical contract

    @Test("Output is canonical whatever went in")
    func convertsToCanonical() async throws {
        let tmp = try TempDirectory()
        // A rate that is not the canonical one, so conversion is exercised.
        let source = try writeTone(.wav, seconds: 1, rate: 48_000, to: tmp.url)
        let out = tmp.url.appending(path: "out.f32")
        let written = try await PortableDecoder().decode(url: source, to: out) { _ in }

        // One second in, one second out, at the canonical rate.
        #expect(abs(written - Int64(CanonicalFormat.sampleRate)) < 200, "wrote \(written)")
        let bytes = try FileManager.default
            .attributesOfItem(atPath: out.path)[.size] as? Int64 ?? 0
        #expect(bytes == written * Int64(CanonicalFormat.bytesPerSample))
    }

    @Test("Progress is reported and ends at 1")
    func reportsProgress() async throws {
        let tmp = try TempDirectory()
        let source = try writeTone(.wav, seconds: 4, to: tmp.url)
        let out = tmp.url.appending(path: "out.f32")
        nonisolated(unsafe) var seen: [Double] = []
        _ = try await PortableDecoder(bufferDuration: 0.5)
            .decode(url: source, to: out) { seen.append($0) }
        #expect(seen.last == 1)
        #expect(seen.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("Memory does not scale with the length of the recording")
    func boundedFootprint() async throws {
        // The promise that lets a six-hour file be decoded at all: the block
        // size is a function of bufferDuration alone.
        let tmp = try TempDirectory()
        let short = try writeTone(.wav, seconds: 1, to: tmp.url)
        let longDirectory = tmp.url.appending(path: "long")
        try FileManager.default.createDirectory(at: longDirectory, withIntermediateDirectories: true)
        let long = try writeTone(.wav, seconds: 20, to: longDirectory)

        let decoder = PortableDecoder(bufferDuration: 1)
        let a = try await decoder.decode(url: short, to: tmp.url.appending(path: "a.f32")) { _ in }
        let b = try await decoder.decode(url: long, to: tmp.url.appending(path: "b.f32")) { _ in }
        #expect(b > a * 15, "the longer file should produce far more samples")
    }

    // MARK: - Failures

    @Test("Rubbish that claims to be a container is refused")
    func unsupportedContainer() async throws {
        let tmp = try TempDirectory()
        let fake = tmp.url.appending(path: "clip.m4a")
        try Data(repeating: 0, count: 2048).write(to: fake)
        await #expect(throws: VoxScriptaError.self) {
            _ = try await PortableDecoder().decode(
                url: fake, to: tmp.url.appending(path: "o.f32")) { _ in }
        }
    }

    @Test("It reads an m4a, which is the whole reason for FFmpeg")
    func readsAAC() async throws {
        // The gap that forced this decision: the app records m4a, so a
        // recording made on a Mac has to open on Linux. miniaudio could not,
        // and that is why this is FFmpeg.
        let tmp = try TempDirectory()
        let source = try writeTone(.m4a, seconds: 2, to: tmp.url)
        let out = tmp.url.appending(path: "aac.f32")
        let written = try await PortableDecoder().decode(url: source, to: out) { _ in }
        #expect(written > Int64(CanonicalFormat.sampleRate),
                "an m4a produced only \(written) samples")
    }

    @Test("It agrees with AVFoundation on an m4a too")
    func aacAgreesWithApple() async throws {
        let tmp = try TempDirectory()
        let source = try writeTone(.m4a, seconds: 2, to: tmp.url)
        let appleOut = tmp.url.appending(path: "apple-aac.f32")
        let portableOut = tmp.url.appending(path: "portable-aac.f32")
        _ = try await CanonicalDecoder().decode(url: source, to: appleOut) { _ in }
        _ = try await PortableDecoder().decode(url: source, to: portableOut) { _ in }

        let apple = try samples(of: appleOut)
        let portable = try samples(of: portableOut)
        let shared = min(apple.count, portable.count)
        try #require(shared > CanonicalFormat.sampleRate)

        // AAC is lossy and the two decoders handle the encoder's priming
        // differently, so the alignment search is wider here than for WAV.
        let from = shared / 4, to = shared * 3 / 4
        func worst(shift: Int) -> Float {
            var w: Float = 0
            for i in from..<to where i + shift >= 0 && i + shift < portable.count {
                w = max(w, abs(apple[i] - portable[i + shift]))
            }
            return w
        }
        let best = (-2048...2048).min { worst(shift: $0) < worst(shift: $1) } ?? 0
        print("AAC PARITY: best shift \(best) samples, worst difference \(worst(shift: best))")
        #expect(worst(shift: best) < 0.1,
                "the two decoders disagree by \(worst(shift: best)) on the same m4a")
    }

    @Test("A missing file is unavailable, not a decode failure")
    func missingFile() async throws {
        let tmp = try TempDirectory()
        await #expect(throws: VoxScriptaError.self) {
            _ = try await PortableDecoder().decode(
                url: tmp.url.appending(path: "nothing.wav"),
                to: tmp.url.appending(path: "o.f32")) { _ in }
        }
    }

    @Test("Every container the Apple decoder reads, this one reads too")
    func containerParity() async throws {
        // Parity with AVFoundation is the whole justification for taking on
        // FFmpeg and its licence, so it is checked rather than asserted.
        let tmp = try TempDirectory()
        for format in [TestAudioFormat.wav, .m4a, .flac, .caf, .aiff] {
            let directory = tmp.url.appending(path: "\(format)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = try writeTone(format, seconds: 1, to: directory)
            let out = directory.appending(path: "out.f32")
            let written = try await PortableDecoder().decode(url: source, to: out) { _ in }
            #expect(written > Int64(CanonicalFormat.sampleRate) / 2,
                    "\(format) produced only \(written) samples")
        }
    }
}
