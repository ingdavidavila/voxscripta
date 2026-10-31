import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaDSP

/// The portable recorder's file format, held to the promise the Apple one makes.
///
/// A recording that is lost because the app died is the failure this exists to
/// prevent, so it is tested by abandoning a half-written file and reading it
/// back — not by checking that a flag was set.
@Suite("Fragmented writer")
struct FragmentedWriterTests {

    private func tone(seconds: Double, rate: Int = 44_100) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map {
            Float(0.4 * sin(2 * Double.pi * 440 * Double($0) / Double(rate)))
        }
    }

    /// Writes `seconds` of tone, then either finalizes or walks away.
    private func write(seconds: Double, to url: URL, finish: Bool) throws {
        let writer = try FragmentedWriter(url: url)
        let samples = tone(seconds: seconds)
        // In blocks, as a capture callback delivers them.
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 441, samples.count)
            try samples[offset..<end].withUnsafeBufferPointer { try writer.append($0) }
            offset = end
        }
        if finish { _ = writer.finish() } else { writer.abandon() }
    }

    @Test("A recording abandoned mid-write is still readable")
    func abandonedIsReadable() async throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "abandoned.m4a")
        try write(seconds: 6, to: url, finish: false)

        // Read with this project's own decoder, which is what would have to
        // open it for real.
        let out = tmp.url.appending(path: "out.f32")
        let written = try await PortableDecoder().decode(url: url, to: out) { _ in }
        let seconds = Double(written) / Double(CanonicalFormat.sampleRate)
        print("ABANDONED RECORDING: \(String(format: "%.2f", seconds))s recovered of 6s")

        // Everything but the fragment still in flight.
        #expect(seconds > 3,
                "only \(seconds)s survived of 6 — fragmenting is not working")
    }

    @Test("Without fragmenting, the same file is unreadable")
    func theControl() async throws {
        // The other half of the measurement, so the test proves the mechanism
        // rather than a coincidence. Written through FFmpeg with the default
        // flags, abandoned the same way.
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "plain.m4a")
        try UnfragmentedWriterForTesting.write(tone(seconds: 6), to: url)

        let out = tmp.url.appending(path: "out.f32")
        let recovered = try? await PortableDecoder().decode(url: url, to: out) { _ in }
        let seconds = Double(recovered ?? 0) / Double(CanonicalFormat.sampleRate)
        print("UNFRAGMENTED CONTROL: \(String(format: "%.2f", seconds))s recovered of 6s")
        let note = "an unfragmented abandoned file read back \(seconds)s — if this"
            + " now works, fragmenting is no longer what saves the recording"
        #expect(seconds < 1, "\(note)")
    }

    @Test("A finished recording holds all of the audio")
    func finishedIsComplete() async throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "finished.m4a")
        try write(seconds: 3, to: url, finish: true)

        let out = tmp.url.appending(path: "out.f32")
        let written = try await PortableDecoder().decode(url: url, to: out) { _ in }
        let seconds = Double(written) / Double(CanonicalFormat.sampleRate)
        // AAC adds priming at the front, so this is close rather than exact.
        #expect(abs(seconds - 3) < 0.25, "wrote 3s, read back \(seconds)s")
    }

    @Test("It reports how much it has written")
    func reportsElapsed() throws {
        let tmp = try TempDirectory()
        let writer = try FragmentedWriter(url: tmp.url.appending(path: "e.m4a"))
        #expect(writer.elapsed == 0)
        let samples = tone(seconds: 2)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        // Within one AAC frame of two seconds: the encoder takes 1024 at a
        // time and the remainder waits for the next block.
        #expect(abs(writer.elapsed - 2) < 0.03, "reported \(writer.elapsed)s")
        writer.abandon()
    }

    @Test("The tail of a recording is not dropped")
    func keepsThePartialFrame() async throws {
        // AAC only takes whole 1024-sample frames, so a naive writer loses
        // whatever is left over — up to 23 ms off the end of every recording.
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "tail.m4a")
        let writer = try FragmentedWriter(url: url)
        // Deliberately not a multiple of the frame size.
        let samples = tone(seconds: 1.0 + 500.0 / 44_100.0)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        let reported = writer.finish()
        #expect(reported > 1.0, "the leftover samples were dropped: \(reported)s")
    }

    @Test("It writes the same kind of file the Apple recorder does")
    func samePlatformFormat() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "format.m4a")
        try write(seconds: 3, to: url, finish: true)

        let raw = try Data(contentsOf: url)
        // mvex is what marks a movie as fragmented, and is exactly what
        // distinguished the new Apple recordings from the old ones.
        #expect(raw.range(of: Data("mvex".utf8)) != nil,
                "no mvex box — this is not a fragmented movie")
        #expect(raw.range(of: Data("ftyp".utf8)) != nil)
    }
}

/// An ordinary MPEG-4 writer, for the control case only.
enum UnfragmentedWriterForTesting {
    static func write(_ samples: [Float], to url: URL) throws {
        // Deliberately a plain file: no movflags, so the index is written only
        // by the trailer — which is never reached here.
        let writer = try FragmentedWriter(url: url, fragmenting: false)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        writer.abandon()
    }
}
