import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaDSP
@testable import VoxScriptaFFI

/// The recording surface.
///
/// Everything here except opening a device, which is deliberate: a test suite
/// that asked for the microphone would prompt on a developer's machine and
/// fail on a build server, and neither outcome says anything about the code.
/// So the transport is checked against handles the engine does not know, the
/// naming and level rules are checked against their definitions, and the
/// device path is exercised by hand — `Tools/record-check.sh` — on a machine
/// with a microphone.
@Suite("FFI recording")
struct FFIRecordingTests {

    private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { vs_string_free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - Where recordings go

    @Test("The directory is the engine's, not a copy of it")
    func directoryIsShared() {
        #expect(take(vs_recording_directory()) == RecordingDestination.directory.path)
        // Which is the same answer the SwiftUI recorder gets, because it now
        // asks the engine rather than building the path again.
        #expect(take(vs_recording_directory())?.contains("Recordings") == true)
    }

    @Test("A new path lands in that directory and ends in m4a")
    func newPathIsInTheDirectory() throws {
        let path = try #require(take(vs_recording_new_path()))
        #expect(path.hasPrefix(RecordingDestination.directory.path))
        #expect(path.hasSuffix(".m4a"))
    }

    @Test("Names sort chronologically and avoid collisions")
    func namesSortAndDoNotCollide() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(3600)

        let first = RecordingDestination.newRecordingURL(now: earlier, existsAt: { _ in false })
        let second = RecordingDestination.newRecordingURL(now: later, existsAt: { _ in false })
        #expect(first.lastPathComponent < second.lastPathComponent)

        // A localized date contains slashes in most of the world, and a slash
        // in a filename is a path separator.
        #expect(!first.lastPathComponent.contains("/"))

        // Two recordings in the same second get distinct names.
        var taken: Set<String> = [first.path]
        let third = RecordingDestination.newRecordingURL(
            now: earlier, existsAt: { taken.contains($0.path) })
        #expect(third.path != first.path)
        taken.insert(third.path)
        let fourth = RecordingDestination.newRecordingURL(
            now: earlier, existsAt: { taken.contains($0.path) })
        #expect(fourth.path != first.path)
        #expect(fourth.path != third.path)
    }

    // MARK: - The meter

    @Test("The level curve is the measured one, on both sides of the boundary")
    func levelCurveMatchesTheRule() {
        // Digital silence reads empty, full scale reads full.
        #expect(RecordingLevel.normalize(-160) == 0)
        #expect(abs(RecordingLevel.normalize(0) - 1) < 1e-9)
        // The floor is −50 dB — a quiet room, not digital silence — so anything
        // below it reads the same as nothing.
        #expect(RecordingLevel.normalize(-50) == 0)
        #expect(RecordingLevel.normalize(-80) == 0)
        // And the bottom of the scale is opened out: a voice 25 dB down sits
        // well above the midpoint rather than at it, which is the whole point
        // of the exponent.
        #expect(RecordingLevel.normalize(-25) > 0.6)
        #expect(RecordingLevel.normalize(-25) < 0.8)
    }

    @Test("The level is monotonic, so a meter never moves the wrong way")
    func levelIsMonotonic() {
        var previous = -1.0
        for decibels in stride(from: -60.0, through: 0.0, by: 1.0) {
            let value = RecordingLevel.normalize(decibels)
            #expect(value >= previous, "fell at \(decibels) dB")
            previous = value
        }
    }

    // MARK: - Handles the engine does not know

    @Test("An unknown handle is reported rather than crashed on")
    func unknownHandle() {
        // 9_999 was never issued. A hot reload can leave an interface holding
        // a handle the engine has forgotten.
        #expect(vs_recording_state(9_999) == -1)
        #expect(vs_recording_elapsed(9_999) == 0)
        #expect(vs_recording_level(9_999) == 0)
        #expect(take(vs_recording_failure_copy(9_999)) == nil)
        #expect(vs_recording_pause(9_999) == -1)
        #expect(vs_recording_resume(9_999) == -1)
        #expect(vs_recording_discard(9_999) == -1)

        var out: UnsafeMutablePointer<CChar>?
        #expect(vs_recording_finish(9_999, &out) == -1)
        #expect(out == nil)
    }

    @Test("Finishing without an out pointer is refused, not ignored")
    func finishNeedsSomewhereToReport() {
        #expect(vs_recording_finish(1, nil) == -1)
        #expect(take(vs_last_error_copy())?.isEmpty == false)
    }

    @Test("Starting somewhere unwritable fails with a reason")
    func unwritableDestinationFails() {
        // A path under a file rather than a directory, so creating the parent
        // fails before any device is touched.
        let blocked = "/dev/null/nope/recording.m4a"
        let handle = blocked.withCString { vs_recording_start($0) }
        #expect(handle < 0)
        #expect(take(vs_last_error_copy())?.isEmpty == false)
    }
}
