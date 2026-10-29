import Testing
import Foundation
import AVFoundation
@testable import VoxScriptaUI

/// The parts of recording that can be checked without a microphone.
///
/// Capture itself cannot be tested here — there is no input device on a test
/// runner, and faking one would test the fake. What is tested is everything
/// around it: the naming that decides where a §5 original lands, the meter
/// mapping that is the only warning a recording is silent, and the clock.
@Suite("Recording")
@MainActor
struct RecordingTests {

    // MARK: - File naming

    @Test("A recording is named for when it was made, with no path separators")
    func nameIsSortableAndSafe() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 9
        components.hour = 14; components.minute = 5; components.second = 7
        let date = Calendar.current.date(from: components)!

        let url = AudioRecorder.newRecordingURL(now: date, existsAt: { _ in false })
        let name = url.deletingPathExtension().lastPathComponent

        #expect(url.pathExtension == "m4a")
        #expect(name.hasSuffix("2026-03-09 14.05.07"))
        // A localized date would put slashes in most of the world's locales,
        // and a slash in a filename is a directory.
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test("A name already in use gets a suffix rather than overwriting")
    func namesDoNotCollide() {
        // §5 in its smallest form: starting a second recording in the same
        // second must not write over the first one.
        let date = Date(timeIntervalSince1970: 1_772_000_000)
        let first = AudioRecorder.newRecordingURL(now: date, existsAt: { _ in false })

        var taken: Set<String> = [first.path]
        let second = AudioRecorder.newRecordingURL(now: date,
                                                   existsAt: { taken.contains($0.path) })
        #expect(second != first)
        taken.insert(second.path)
        let third = AudioRecorder.newRecordingURL(now: date,
                                                  existsAt: { taken.contains($0.path) })
        #expect(third != first)
        #expect(third != second)
    }

    @Test("Recordings are written outside any project package")
    func recordingsLiveOnTheirOwn() {
        // They are referenced by a project, not held inside one, so deleting
        // the project leaves the original where it is.
        let directory = AudioRecorder.recordingsDirectory.path
        #expect(directory.hasSuffix("Recordings"))
        #expect(!directory.contains(".voxscripta"))
    }

    // MARK: - The level meter

    @Test("Silence reads as empty and a loud signal reads as full")
    func meterSpansItsRange() {
        #expect(AudioRecorder.normalize(-160) == 0)
        #expect(AudioRecorder.normalize(-50) == 0)
        #expect(AudioRecorder.normalize(0) == 1)
    }

    @Test("The meter rises monotonically and opens out the quiet end")
    func meterCurve() {
        let samples: [Float] = [-50, -40, -30, -20, -10, 0]
        let mapped = samples.map(AudioRecorder.normalize)
        for (lower, higher) in zip(mapped, mapped.dropFirst()) {
            #expect(higher > lower)
        }
        // The point of the curve: a quiet voice at -30 dB must be visibly off
        // the floor, which a linear map over -50…0 would leave at 0.4 and a
        // map over -160…0 would leave at 0.8 of nothing.
        #expect(AudioRecorder.normalize(-30) > 0.5)
    }

    @Test("Out-of-range readings are clamped rather than wrapping")
    func meterClamps() {
        #expect(AudioRecorder.normalize(12) == 1)
        #expect(AudioRecorder.normalize(-.infinity) == 0)
    }

    // MARK: - The clock

    @Test("The hour place appears only once there is an hour")
    func clockFormat() {
        #expect(RecordingView.clock(0) == "0:00")
        #expect(RecordingView.clock(9) == "0:09")
        #expect(RecordingView.clock(65) == "1:05")
        #expect(RecordingView.clock(599) == "9:59")
        #expect(RecordingView.clock(3600) == "1:00:00")
        #expect(RecordingView.clock(3661) == "1:01:01")
        #expect(RecordingView.clock(36_000) == "10:00:00")
    }

    @Test("A part-second does not round the clock forwards")
    func clockTruncates() {
        // Showing 0:01 before a second has elapsed makes the number a lie,
        // and it is the only measure of how long a recording is.
        #expect(RecordingView.clock(0.9) == "0:00")
        #expect(RecordingView.clock(59.99) == "0:59")
    }

    // MARK: - Encoder settings

    @Test("Recording is mono, so nothing is captured twice")
    func encoderIsMono() {
        let settings = AudioRecorder.encoderSettings
        #expect(settings[AVNumberOfChannelsKey] as? Int == 1)
        #expect(settings[AVFormatIDKey] as? Int == Int(kAudioFormatMPEG4AAC))
        // Well above the 16 kHz the pipeline resamples to, so the recording is
        // never the limiting factor in what gets recognised.
        #expect((settings[AVSampleRateKey] as? Double ?? 0) >= 16_000)
    }

    // MARK: - State

    @Test("An idle recorder reports nothing in progress")
    func idleState() {
        let recorder = AudioRecorder()
        #expect(recorder.state == .idle)
        #expect(!recorder.state.isActive)
        #expect(recorder.fileURL == nil)
        #expect(recorder.elapsed == 0)
        #expect(recorder.levels.isEmpty)
        // Nothing to stop, and asking must not produce a file.
        #expect(recorder.finish() == nil)
    }
}
