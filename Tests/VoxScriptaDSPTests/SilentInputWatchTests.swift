import Testing
import Foundation
@testable import VoxScriptaDSP

/// An input that runs without ever delivering audio.
///
/// The condition is narrow on purpose, and the tests that matter most are the
/// ones pinning what it must *not* report: silence is ordinary in a recording,
/// and a warning that cried wolf during a pause would be turned off by the
/// first person who met it, taking the real case with it.
@Suite("Silent input")
struct SilentInputWatchTests {

    private let silence = RecordingLevel.digitalSilenceDB
    private let speech = -18.0

    // ── The case it exists for ──────────────────────────────────────────────

    @Test("An input that never delivers anything is reported")
    func deadInputIsReported() {
        var watch = SilentInputWatch()
        var warned = false
        for second in stride(from: 0.0, through: 12.0, by: 0.5) {
            warned = watch.observe(level: silence, elapsed: second)
        }
        #expect(warned)
        #expect(watch.isSilent)
        #expect(!watch.hasHeardAudio)
    }

    @Test("Nothing is said before the patience has run out")
    func silenceIsGivenTime() {
        // Someone who presses Record and then gathers their thoughts must not
        // be told their microphone is broken.
        var watch = SilentInputWatch()
        for second in stride(from: 0.0, to: SilentInputWatch.patience, by: 0.5) {
            let warned = watch.observe(level: silence, elapsed: second)
            #expect(!warned)
        }
        #expect(!watch.isSilent)
    }

    // ── What it must never report ───────────────────────────────────────────

    @Test("A pause in the middle of a recording is not a fault")
    func midRecordingSilenceIsNotAFault() {
        // The premise of the application is finding and removing silence. A
        // long gap is the normal case, not a broken microphone.
        var watch = SilentInputWatch()
        watch.observe(level: speech, elapsed: 0.5)
        var warned = false
        for second in stride(from: 1.0, through: 600.0, by: 0.5) {
            warned = watch.observe(level: silence, elapsed: second)
        }
        #expect(!warned)
        #expect(!watch.isSilent)
        #expect(watch.hasHeardAudio)
    }

    @Test("One sample of audio settles it for the whole recording")
    func beingHeardOnceIsEnough() {
        var watch = SilentInputWatch()
        for second in stride(from: 0.0, through: 7.0, by: 0.5) {
            watch.observe(level: silence, elapsed: second)
        }
        #expect(!watch.hasHeardAudio)
        watch.observe(level: speech, elapsed: 7.5)
        #expect(watch.hasHeardAudio)
        let afterwards = watch.observe(level: silence, elapsed: 60)
        #expect(!afterwards)
    }

    @Test("A quiet room is not digital silence")
    func aQuietRoomIsNotSilence() {
        // The quietest nonzero sample 16-bit audio can carry is about −90 dB,
        // and a room has a noise floor well above that. Everything here must
        // read as a live microphone, or the warning fires on a real recording
        // made somewhere quiet.
        for level in [-90.3, -80.0, -70.0, -60.0, -50.0] {
            var watch = SilentInputWatch()
            let warned = watch.observe(level: level, elapsed: 30)
            #expect(!warned)
            #expect(watch.hasHeardAudio, "\(level) dB should read as audio")
        }
    }

    @Test("Nothing a microphone can hear is counted as silence")
    func theBoundaryIsBelowAnyRealSignal() {
        // Keyed to exact zero this would never fire on an input that hands
        // over dither instead — a tested warning that silently does nothing,
        // which is worse than not having written it.
        for level in [RecordingLevel.digitalSilenceDB, -150.0, -130.0, -121.0] {
            var watch = SilentInputWatch()
            let silent = watch.observe(level: level, elapsed: 30)
            #expect(silent, "\(level) dB should count as nothing")
        }
        // And the other side of the line is a live microphone, however quiet.
        for level in [-119.0, -100.0, -90.3, -60.0] {
            var watch = SilentInputWatch()
            let silent = watch.observe(level: level, elapsed: 30)
            #expect(!silent, "\(level) dB should count as audio")
            #expect(watch.hasHeardAudio)
        }
    }

    // ── The clock it counts against ─────────────────────────────────────────

    @Test("A stopped clock does not accumulate towards a warning")
    func aStoppedClockDoesNotAccumulate() {
        // A clock that has stopped is a writer failure, which is reported on
        // its own terms. Counting it here too would put two warnings on screen
        // for one fault, and the wrong one first.
        var watch = SilentInputWatch()
        for _ in 0..<100 {
            let warned = watch.observe(level: silence, elapsed: 2.0)
            #expect(!warned)
        }
        #expect(!watch.isSilent)
    }

    @Test("The meter rule and the silence sentinel agree")
    func normalizeAgreesWithTheSentinel() {
        // Digital silence must sit at the bottom of the meter, or the screen
        // would show a bar for an input delivering nothing.
        #expect(RecordingLevel.normalize(RecordingLevel.digitalSilenceDB) == 0)
        #expect(RecordingLevel.normalize(-50) == 0)
        #expect(RecordingLevel.normalize(0) == 1)
    }
}
