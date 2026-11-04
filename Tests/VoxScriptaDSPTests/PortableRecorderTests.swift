import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaDSP

/// What can be checked about the portable recorder without a microphone.
///
/// Opening a capture device cannot be tested on a machine that has none, and
/// faking one would test the fake — the same position the Apple recorder is
/// in. So the writer carries the properties that matter and is tested
/// directly; this covers the transport around it.
@Suite("Portable recorder")
struct PortableRecorderTests {

    @Test("An idle recorder has written nothing and holds no file open")
    func idle() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "r.m4a")
        let recorder = PortableRecorder(url: url)
        #expect(recorder.state == .idle)
        #expect(recorder.elapsed == 0)
        #expect(recorder.failure == nil)
        // Nothing started, so nothing exists.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // And stopping something that never started must not throw or create one.
        #expect(recorder.finish() == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The meter starts at silence, not at full scale")
    func meterFloor() throws {
        // Decibels full scale: zero means pegged, so an unstarted meter
        // reading zero would show a recorder that is hearing everything.
        let tmp = try TempDirectory()
        let recorder = PortableRecorder(url: tmp.url.appending(path: "r.m4a"))
        #expect(recorder.level < -100)
    }

    @Test("Pause and resume only move between the states they should")
    func transport() throws {
        let tmp = try TempDirectory()
        let recorder = PortableRecorder(url: tmp.url.appending(path: "r.m4a"))
        // Nothing is running, so neither does anything — rather than putting
        // an idle recorder into a paused state it can never leave.
        recorder.pause()
        #expect(recorder.state == .idle)
        recorder.resume()
        #expect(recorder.state == .idle)
    }

    @Test("Cancelling removes the file")
    func cancelDeletes() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "r.m4a")
        // Stand in for a recording that got as far as opening its file.
        let writer = try FragmentedWriter(url: url)
        let samples = [Float](repeating: 0.1, count: 44_100)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        writer.abandon()
        #expect(FileManager.default.fileExists(atPath: url.path))

        PortableRecorder(url: url).cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "a cancelled recording left its file behind")
    }

    @Test("It records at a rate the pipeline will not be the worse for")
    func captureFormat() {
        // The pipeline resamples everything to 16 kHz, so this only has to be
        // comfortably above it — and matching the Apple recorder means the two
        // produce the same kind of file.
        #expect(PortableRecorder.sampleRate >= CanonicalFormat.sampleRate * 2)
        #expect(PortableRecorder.sampleRate == 44_100)
    }

    @Test("A crash costs at most one fragment")
    func fragmentBudget() {
        #expect(FragmentedWriter.fragmentSeconds > 0)
        #expect(FragmentedWriter.fragmentSeconds <= 5,
                "a fragment long enough to lose a sentence defeats the point")
    }
}
