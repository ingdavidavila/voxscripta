import Testing
import Foundation
import VoxVerbaCore
import VoxVerbaBench
import VoxVerbaTestSupport
@testable import VoxVerbaDSP

@Suite("Memory behaviour", .serialized)
struct MemoryTests {

    /// Renders `minutes` of speech straight to a canonical PCM file.
    ///
    /// Written in blocks so the fixture itself does not defeat the measurement.
    private func writeCanonical(minutes: Double, to url: URL) throws -> MediaTime {
        let sr = CanonicalFormat.sampleRate
        let total = Int(minutes * 60 * Double(sr))
        let blockSeconds = 30.0
        let blockSamples = Int(blockSeconds * Double(sr))

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var written = 0
        var index = 0
        while written < total {
            let n = min(blockSamples, total - written)
            let span = SignalSpan(
                kind: .voiced,
                range: TimeRange(start: .zero, end: .seconds(Double(n) / Double(sr))),
                levelDB: -20)
            let block = SignalSynthesizer(seed: UInt64(0xBEEF &+ index)).render(spans: [span])
            let slice = Array(block.prefix(n))
            try slice.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
            written += n
            index += 1
        }
        return MediaTime(samples: Int64(total), sampleRate: sr)
    }

    @Test("Analysis footprint does not scale with recording length")
    func footprintIsBounded() async throws {
        // The central memory claim: a chunk is a view into a mapped file, and the
        // analyzer sweeps it sequentially, so a long recording costs no more
        // resident memory than a short one. Mapped pages are clean and evictable,
        // which is why `phys_footprint` is the right meter here.
        let tmp = try TempDirectory()

        let shortURL = tmp.url.appending(path: "short.f32")
        let longURL = tmp.url.appending(path: "long.f32")
        let shortDuration = try writeCanonical(minutes: 1, to: shortURL)
        let longDuration = try writeCanonical(minutes: 20, to: longURL)
        #expect(longDuration.seconds > shortDuration.seconds * 15)

        let analyzer = FrameAnalyzer()

        let (_, shortPeak) = try await MemoryFootprint.peak {
            _ = try await analyzer.analyze(canonicalFile: shortURL, geometry: .default) { _ in }
        }
        let (longFeatures, longPeak) = try await MemoryFootprint.peak {
            try await analyzer.analyze(canonicalFile: longURL, geometry: .default) { _ in }
        }

        // Feature storage is inherently proportional to duration (~36 bytes per
        // second), so the long run legitimately holds more. What must NOT happen
        // is the audio itself landing in the footprint: 20 minutes of canonical
        // PCM is 76 MB, and the growth here is a small fraction of that.
        let growth = longPeak - shortPeak
        let audioBytes = CanonicalFormat.byteCount(for: longDuration)
        #expect(growth < audioBytes / 4,
                "footprint grew \(growth) bytes for \(audioBytes) bytes of audio")

        // Sanity: the analysis actually happened.
        #expect(longFeatures.count > 100_000)
    }

    @Test("Decoding a long file stays within a fixed budget")
    func decodeFootprint() async throws {
        let tmp = try TempDirectory()
        let source = tmp.url.appending(path: "long.wav")

        // Ten minutes of audio through a decoder whose buffers are sized from
        // bufferDuration alone.
        var spans: [SignalSpan] = []
        for i in 0..<20 {
            let a = Double(i) * 30, b = a + 25
            spans.append(SignalSpan(kind: .voiced,
                                    range: TimeRange(start: .seconds(a), end: .seconds(b)),
                                    levelDB: -20))
            spans.append(SignalSpan(kind: .silence,
                                    range: TimeRange(start: .seconds(b), end: .seconds(a + 30)),
                                    levelDB: -62))
        }
        let samples = SignalSynthesizer().render(spans: spans)
        try AudioFileWriter.write(samples: samples, to: source, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        let dest = tmp.url.appending(path: "canonical.f32")
        let baseline = try MemoryFootprint.current()
        let (written, peak) = try await MemoryFootprint.peak {
            try await CanonicalDecoder(bufferDuration: 10).decode(url: source, to: dest) { _ in }
        }
        #expect(written > 9_000_000)

        // Growth, not absolute footprint. This suite shares a process with tests
        // that load MLX and an 868 MB model, so the absolute figure says more
        // about what else ran than about the decoder. What must hold is that
        // decoding ten minutes of audio costs a bounded amount *more* than
        // whatever the process was already using.
        let growth = peak - baseline
        #expect(growth < 256 * 1024 * 1024,
                "decoding grew the footprint by \(growth / (1 << 20)) MB")
    }
}
