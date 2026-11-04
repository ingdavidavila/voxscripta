import Foundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaProject

// Recording, for the interfaces that are not SwiftUI.
//
// The transport is the same shape as a job — a handle, then polling — for the
// same reason: a level meter that called back into Dart sixty times a second
// from a capture thread is the crash the job surface was designed to avoid.
// Four scalar reads at 20 Hz cost nothing.
//
// What is behind it is `PortableRecorder`: miniaudio opening the capture device
// — WASAPI on Windows, ALSA or PulseAudio on Linux, AAudio on Android — writing
// fragmented m4a through FFmpeg, which is the same container the Apple recorder
// produces. **Never run on a machine that is not a Mac.** The writer is tested
// on both paths and the device layer is not, because it cannot be: opening a
// microphone needs a microphone. That is recorded here rather than discovered.

/// One recording in progress, as the C side sees it.
private final class RecordingBox {
    let recorder: PortableRecorder
    let url: URL

    init(recorder: PortableRecorder, url: URL) {
        self.recorder = recorder
        self.url = url
    }
}

private final class RecordingRegistry: @unchecked Sendable {
    static let shared = RecordingRegistry()

    private let lock = NSLock()
    private var recordings: [Int64: RecordingBox] = [:]
    private var nextHandle: Int64 = 1

    func insert(_ box: RecordingBox) -> Int64 {
        lock.withLock {
            let handle = nextHandle
            nextHandle += 1
            recordings[handle] = box
            return handle
        }
    }

    func box(_ handle: Int64) -> RecordingBox? {
        lock.withLock { recordings[handle] }
    }

    func remove(_ handle: Int64) -> RecordingBox? {
        lock.withLock { recordings.removeValue(forKey: handle) }
    }
}

// MARK: - Where recordings go

/// The folder recordings are written to. Caller releases it.
///
/// Read from the engine so both interfaces write to the same place.
@_cdecl("vs_recording_directory")
public func vs_recording_directory() -> UnsafeMutablePointer<CChar>? {
    copyOut(RecordingDestination.directory.path)
}

/// A new, non-colliding recording path. Caller releases it.
///
/// The name sorts chronologically and is fixed-format rather than localized: a
/// localized date contains slashes in most of the world, and a slash in a
/// filename is a path separator.
@_cdecl("vs_recording_new_path")
public func vs_recording_new_path() -> UnsafeMutablePointer<CChar>? {
    copyOut(RecordingDestination.newRecordingURL().path)
}

// MARK: - Transport

/// Opens the microphone and begins writing to `destination_path`, or to a new
/// generated path when it is NULL or empty.
///
/// Returns a handle, or a negative number with the reason in
/// `vs_last_error_copy`. The file is readable while it is being written: the
/// writer emits fragments, so a crash costs the last fragment rather than the
/// recording.
@_cdecl("vs_recording_start")
public func vs_recording_start(
    _ destination_path: UnsafePointer<CChar>?
) -> Int64 {
    recordingStart(destination_path, gate: entitlements)
}

/// The body of ``vs_recording_start``, with the paywall as a parameter. See
/// ``jobStart(_:_:_:gate:)`` for why it is a parameter.
func recordingStart(
    _ destination_path: UnsafePointer<CChar>?,
    gate: EntitlementStore
) -> Int64 {
    setLastError(nil)
    // The same wall as `vs_job_start`, and -3 for the same reason: recording
    // audio the app will not then transcribe is not a useful half-measure.
    if entitlementRefuses(.startRecording, in: gate) { return -3 }
    let requested = destination_path.map { String(cString: $0) } ?? ""
    let url = requested.isEmpty
        ? RecordingDestination.newRecordingURL()
        : URL(filePath: requested)

    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recorder = PortableRecorder(url: url)
        // Blocks while the device opens, which is milliseconds — unlike the
        // Apple path, where `record()` has been seen to block forever on a
        // machine with no usable input. miniaudio returns an error instead.
        try recorder.start()
        return RecordingRegistry.shared.insert(
            RecordingBox(recorder: recorder, url: url))
    } catch {
        setLastError(describe(error))
        return -1
    }
}

/// 0 idle, 1 recording, 2 paused, -1 for a handle the engine does not know.
@_cdecl("vs_recording_state")
public func vs_recording_state(_ handle: Int64) -> Int32 {
    guard let box = RecordingRegistry.shared.box(handle) else { return -1 }
    return switch box.recorder.state {
    case .idle: 0
    case .recording: 1
    case .paused: 2
    }
}

/// Seconds of audio actually written, excluding anything paused.
@_cdecl("vs_recording_elapsed")
public func vs_recording_elapsed(_ handle: Int64) -> Double {
    RecordingRegistry.shared.box(handle)?.recorder.elapsed ?? 0
}

/// The meter, already mapped onto `0...1`.
///
/// Normalized here rather than in the interface: the mapping is a measured
/// curve, and two meters that moved differently for the same microphone would
/// be describing two different recordings.
@_cdecl("vs_recording_level")
public func vs_recording_level(_ handle: Int64) -> Double {
    guard let box = RecordingRegistry.shared.box(handle) else { return 0 }
    return RecordingLevel.normalize(box.recorder.level)
}

/// Why capture or writing failed part-way through, or NULL. Caller releases it.
///
/// A recording can fail after it has started — a disk filling, a device
/// disappearing — and the file written so far is still good. So this is a
/// report rather than a state: the transport keeps working and the interface
/// decides what to say.
@_cdecl("vs_recording_failure_copy")
public func vs_recording_failure_copy(
    _ handle: Int64
) -> UnsafeMutablePointer<CChar>? {
    guard let failure = RecordingRegistry.shared.box(handle)?.recorder.failure
    else { return nil }
    return copyOut(failure)
}

@_cdecl("vs_recording_pause")
public func vs_recording_pause(_ handle: Int64) -> Int32 {
    guard let box = RecordingRegistry.shared.box(handle) else { return -1 }
    box.recorder.pause()
    return 0
}

@_cdecl("vs_recording_resume")
public func vs_recording_resume(_ handle: Int64) -> Int32 {
    guard let box = RecordingRegistry.shared.box(handle) else { return -1 }
    box.recorder.resume()
    return 0
}

/// Stops, finalizes, and forgets the handle.
///
/// Writes `{"path": "...", "seconds": 0.0}` to `out_json`, which the caller
/// releases with `vs_string_free`. The file was already readable before this;
/// finishing tidies it.
@_cdecl("vs_recording_finish")
public func vs_recording_finish(
    _ handle: Int64,
    _ out_json: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    setLastError(nil)
    guard let out_json else {
        setLastError("vs_recording_finish requires an out pointer")
        return -1
    }
    guard let box = RecordingRegistry.shared.remove(handle) else { return -1 }

    let seconds = box.recorder.finish()
    do {
        out_json.pointee = copyOut(try Wire.encode(
            RecordingResultWire(path: box.url.path, seconds: seconds)))
        return 0
    } catch {
        setLastError(describe(error))
        return -4
    }
}

/// Stops and deletes what was written, and forgets the handle.
///
/// The one place in this surface that destroys audio, and it does so only
/// because the user asked: §5 protects *original* files, and a recording the
/// person just chose to throw away is not one yet.
@_cdecl("vs_recording_discard")
public func vs_recording_discard(_ handle: Int64) -> Int32 {
    guard let box = RecordingRegistry.shared.remove(handle) else { return -1 }
    box.recorder.cancel()
    return 0
}

/// What a finished recording produced.
struct RecordingResultWire: Codable {
    let path: String
    let seconds: Double
}
