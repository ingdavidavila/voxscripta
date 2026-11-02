import Foundation
import VoxScriptaCore
import VoxScriptaProject
import VoxScriptaPipeline
import VoxScriptaExport

// The C ABI the non-Apple interfaces call.
//
// Android, Windows and Linux share one Flutter application, and Flutter reaches
// native code through Dart FFI, which speaks C. So the engine needs a C surface.
// This is it. The same surface serves a Kotlin or a native Win32 front end, and
// the JNI in `android/jni/` does not: that belongs to the superseded C++ spike
// and talks to `core/`, not to this engine.
//
// Five decisions shape everything below, and each one is a choice against a
// more obvious alternative.
//
// **Polling, not callbacks.** A progress callback would be the natural shape,
// and it is the wrong one here: a C function pointer invoked from a Swift
// executor thread reaches Dart on a thread Dart does not own, which needs
// `NativeCallable.listener` and a send port and is the standard way to crash a
// Flutter application. The SwiftUI app already polls its own progress at 10 Hz,
// so polling loses nothing and removes the whole class of failure.
//
// **Scalar getters, not a shared struct.** A `vs_progress` struct would be one
// call instead of four, at the price of a header whose layout three languages
// and three platforms have to agree on. Four scalar reads at 10 Hz cost
// nothing measurable, and nothing can disagree about an `Int32`.
//
// **Nothing blocks except the trivial getters.** Creating a project and running
// it are one call — `vs_job_start` — which returns immediately with a handle.
// There is no synchronous `vs_project_create` to freeze a Dart isolate.
//
// **Memory crosses the boundary one way only.** Every buffer this library
// returns was allocated by Swift and must be released by `vs_string_free` or
// `vs_bytes_free`. Callers must not call `free()`: on Windows a DLL and its
// host can hold different C runtime heaps, and freeing across them corrupts
// both. So nothing here is allocated with `malloc` either.
//
// **Errors are per-thread.** `vs_last_error_copy` reads a thread-local, so two
// Dart isolates calling in parallel cannot read each other's failure — an
// isolate is an OS thread, which is the granularity this gives. It is *not* per
// task: Swift's cooperative pool runs many tasks on one thread, so a Swift
// caller driving this surface from several tasks would see them share an error
// slot. No Swift caller needs this surface, and `VoxScriptaFFITests` pins the
// distinction so it is not rediscovered as a bug.

/// Bumped when a symbol changes meaning or disappears. The Dart side refuses to
/// run against an ABI it was not built for, rather than crashing on the first
/// mismatched call.
private let abiVersion: Int32 = 1

// MARK: - Job states

/// The integer a poll returns.
///
/// Written as an explicit switch rather than `JobState.allCases.firstIndex`, so
/// that inserting a case in the engine cannot silently renumber what a shipped
/// Flutter build already understands.
private func code(for state: JobState) -> Int32 {
    switch state {
    case .imported: 0
    case .analyzing: 1
    case .silenceProcessing: 2
    case .chunking: 3
    case .transcribing: 4
    case .merging: 5
    case .cleaning: 6
    case .polishing: 7
    case .complete: 8
    case .failed: 9
    case .cancelled: 10
    }
}

/// Accepted and started, but no stage has reported yet.
private let codeStarting: Int32 = 100
/// No such handle — released already, or never issued.
private let codeUnknownHandle: Int32 = -1

// MARK: - The registry

/// One running job, as the C side can see it.
///
/// A class behind a lock rather than an actor, because every getter below is
/// synchronous and is called from a thread this library does not control.
private final class JobBox {
    var stateCode: Int32 = codeStarting
    var fraction: Double = 0
    var detail: String = ""
    var failure: String?
    var task: Task<Void, Never>?
}

private final class JobRegistry: @unchecked Sendable {
    static let shared = JobRegistry()

    private let lock = NSLock()
    private var jobs: [Int64: JobBox] = [:]
    private var nextHandle: Int64 = 1

    func insert() -> (Int64, JobBox) {
        lock.withLock {
            let handle = nextHandle
            nextHandle += 1
            let box = JobBox()
            jobs[handle] = box
            return (handle, box)
        }
    }

    func box(_ handle: Int64) -> JobBox? {
        lock.withLock { jobs[handle] }
    }

    /// Reads one field under the lock. Every getter goes through this so no
    /// field is ever read while a stage is writing another.
    func read<T>(_ handle: Int64, _ body: (JobBox) -> T, default fallback: T) -> T {
        lock.withLock { jobs[handle].map(body) ?? fallback }
    }

    func update(_ handle: Int64, _ body: (JobBox) -> Void) {
        lock.withLock { jobs[handle].map(body) }
    }

    func remove(_ handle: Int64) -> JobBox? {
        lock.withLock { jobs.removeValue(forKey: handle) }
    }
}

// MARK: - Buffers

/// Copies `string` into a buffer the caller releases with `vs_string_free`.
///
/// Allocated through Swift rather than `strdup` so that allocation and release
/// are the same allocator on every platform — see the note on Windows C
/// runtimes above.
private func copyOut(_ string: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(string.utf8) + [0]
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    return buffer
}

private func copyOut(_ data: Data) -> UnsafeMutablePointer<UInt8>? {
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, data.count))
    data.copyBytes(to: buffer, count: data.count)
    return buffer
}

// MARK: - Errors

private let lastErrorKey = "com.voxscripta.ffi.lastError"

private func setLastError(_ message: String?) {
    if let message {
        Thread.current.threadDictionary[lastErrorKey] = message
    } else {
        Thread.current.threadDictionary.removeObject(forKey: lastErrorKey)
    }
}

private func describe(_ error: any Error) -> String {
    (error as? VoxScriptaError)?.errorDescription ?? error.localizedDescription
}

// MARK: - Exported surface

@_cdecl("vs_abi_version")
public func vs_abi_version() -> Int32 { abiVersion }

/// The last failure on *this* thread, or `nil` if the last call succeeded.
/// Caller releases it with `vs_string_free`.
@_cdecl("vs_last_error_copy")
public func vs_last_error_copy() -> UnsafeMutablePointer<CChar>? {
    guard let message = Thread.current.threadDictionary[lastErrorKey] as? String
    else { return nil }
    return copyOut(message)
}

/// Creates or opens the project at `project_path` for the audio at
/// `audio_path`, and runs the pipeline.
///
/// Returns a handle, or a negative number on refusal — in which case
/// `vs_last_error_copy` says why. Returning immediately is the point: the work
/// runs on this library's own executor and is observed through the getters.
///
/// The original audio is referenced, never copied and never modified (§5).
@_cdecl("vs_job_start")
public func vs_job_start(
    _ audio_path: UnsafePointer<CChar>?,
    _ project_path: UnsafePointer<CChar>?
) -> Int64 {
    setLastError(nil)
    guard let audio_path, let project_path else {
        setLastError("vs_job_start requires both an audio path and a project path")
        return -1
    }
    let audio = String(cString: audio_path)
    let project = String(cString: project_path)
    // Checked here rather than left to fail a stage later. An empty path is
    // never a path, and `URL(filePath: "")` turns into the working directory,
    // so the job would start and then fail with "could not be found at ." —
    // which tells a caller nothing about what it got wrong. Found by the Dart
    // bindings, which pass empty strings where a null pointer was expected.
    guard !audio.isEmpty, !project.isEmpty else {
        setLastError("vs_job_start was given an empty path")
        return -2
    }
    let audioURL = URL(filePath: audio)
    let projectURL = URL(filePath: project)

    let (handle, box) = JobRegistry.shared.insert()
    let task = Task.detached {
        do {
            let store = ProjectStore()
            let decoder = JobRunner.defaultDecoder()
            let project: Project
            if FileManager.default.fileExists(
                atPath: ProjectPackage(root: projectURL).manifestURL.path) {
                project = try await store.open(at: projectURL)
            } else {
                project = try await store.create(
                    from: audioURL, at: projectURL,
                    probe: { url in
                        (try await decoder.probe(url: url), try decoder.duration(of: url))
                    })
            }
            _ = try await JobRunner().run(project: project) { report in
                JobRegistry.shared.update(handle) {
                    $0.stateCode = code(for: report.state)
                    $0.fraction = report.fraction
                    $0.detail = report.detail
                }
            }
            JobRegistry.shared.update(handle) {
                $0.stateCode = code(for: .complete)
                $0.fraction = 1
            }
        } catch is CancellationError {
            JobRegistry.shared.update(handle) { $0.stateCode = code(for: .cancelled) }
        } catch {
            let reason = describe(error)
            JobRegistry.shared.update(handle) {
                $0.stateCode = code(for: .failed)
                $0.failure = reason
            }
        }
    }
    JobRegistry.shared.update(handle) { $0.task = task }
    // Set after the task is stored, not before: a job that finished while this
    // function was still running must not have its final state overwritten.
    _ = box
    return handle
}

/// One of the state codes, or -1 for a handle this library does not know.
@_cdecl("vs_job_state")
public func vs_job_state(_ handle: Int64) -> Int32 {
    JobRegistry.shared.read(handle, { $0.stateCode }, default: codeUnknownHandle)
}

/// Completion in `0...1`. Zero for an unknown handle, which a caller
/// distinguishes by checking ``vs_job_state`` first.
@_cdecl("vs_job_fraction")
public func vs_job_fraction(_ handle: Int64) -> Double {
    JobRegistry.shared.read(handle, { $0.fraction }, default: 0)
}

/// The progress line the interface shows. Caller releases it.
@_cdecl("vs_job_detail_copy")
public func vs_job_detail_copy(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let detail = JobRegistry.shared.read(handle, { $0.detail }, default: nil as String?)
    else { return nil }
    return copyOut(detail)
}

/// Why a job failed, or `nil` while it has not. Caller releases it.
@_cdecl("vs_job_error_copy")
public func vs_job_error_copy(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    guard let failure = JobRegistry.shared.read(handle, { $0.failure }, default: nil)
    else { return nil }
    return copyOut(failure)
}

/// Asks a job to stop. It stops at the next stage boundary, leaving the project
/// resumable, so this is not a rollback.
///
/// Returns 0 if the request was delivered, -1 for an unknown handle.
@_cdecl("vs_job_cancel")
public func vs_job_cancel(_ handle: Int64) -> Int32 {
    guard let box = JobRegistry.shared.box(handle) else { return codeUnknownHandle }
    JobRegistry.shared.update(handle) { $0.task?.cancel() }
    _ = box
    return 0
}

/// Forgets a handle. The job itself is cancelled first if it is still running,
/// because a released handle can no longer be cancelled.
@_cdecl("vs_job_release")
public func vs_job_release(_ handle: Int64) {
    guard let box = JobRegistry.shared.remove(handle) else { return }
    box.task?.cancel()
}

/// Renders a finished transcript in one of the five export formats.
///
/// - Parameters:
///   - variant: `verbatim`, `clean` or `polished`.
///   - format: a file extension — `txt`, `md`, `docx`, `srt`, `vtt`.
///   - out_bytes: receives a buffer the caller releases with `vs_bytes_free`.
/// - Returns: 0 on success, negative on failure, with the reason in
///   `vs_last_error_copy`.
///
/// Bytes rather than a string because `docx` is a ZIP. One entry point for all
/// five formats means the interface never learns how any of them is built —
/// which is the guard that keeps the two interfaces from drifting apart.
@_cdecl("vs_export")
public func vs_export(
    _ project_path: UnsafePointer<CChar>?,
    _ variant: UnsafePointer<CChar>?,
    _ format: UnsafePointer<CChar>?,
    _ out_bytes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ out_length: UnsafeMutablePointer<Int64>?
) -> Int32 {
    setLastError(nil)
    guard let project_path, let variant, let format, let out_bytes, let out_length else {
        setLastError("vs_export requires a project path, a variant, a format and two out pointers")
        return -1
    }
    let variantName = String(cString: variant)
    let formatName = String(cString: format)

    guard let kind = TranscriptVariant(rawValue: variantName) else {
        setLastError("no such transcript variant: \(variantName)")
        return -2
    }
    guard let exportFormat = ExportFormat(extension: formatName) else {
        setLastError("no such export format: \(formatName)")
        return -3
    }

    let package = ProjectPackage(root: URL(filePath: String(cString: project_path)))
    let source: URL
    switch kind {
    case .verbatim: source = package.transcriptURL
    case .clean: source = package.cleanTranscriptURL
    case .polished: source = package.polishedTranscriptURL
    }

    do {
        let transcript = try AtomicFile.readJSON(Transcript.self, from: source)
        let data = try Exporters.make(exportFormat).export(transcript, options: .default)
        out_bytes.pointee = copyOut(data)
        out_length.pointee = Int64(data.count)
        return 0
    } catch {
        setLastError(describe(error))
        return -4
    }
}

/// Releases a buffer from `vs_export`.
@_cdecl("vs_bytes_free")
public func vs_bytes_free(_ bytes: UnsafeMutablePointer<UInt8>?) {
    bytes?.deallocate()
}

/// Releases a string from any `*_copy` function.
@_cdecl("vs_string_free")
public func vs_string_free(_ string: UnsafeMutablePointer<CChar>?) {
    string?.deallocate()
}
