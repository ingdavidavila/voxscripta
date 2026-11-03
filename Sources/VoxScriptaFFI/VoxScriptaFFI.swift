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
/// 2 added the library, job options and export options. 3 adds
/// `vs_project_summary`, which the transcript screen needs: which variants
/// exist, their word and segment counts, and what POLISH did. 4 adds
/// `vs_capabilities`, which the settings screen needs. 5 adds the audio
/// facts to `vs_project_summary` and `vs_waveform` beside it, for the
/// processing screen. 6 adds recording. 7 adds the sign-up password rules,
/// so both interfaces accept exactly the same passwords. The previous version
/// could run a job and read the result, which proved the boundary and was
/// nowhere near enough to build an interface on — see `Docs/PARITY.md`.
/// `vs_job_start` and `vs_export` each gained a JSON parameter rather than
/// growing a second entry point beside them, because nothing has shipped
/// against version 1 and a legacy variant kept forever costs more than a
/// break that nobody can observe.
private let abiVersion: Int32 = 7

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
func copyOut(_ string: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(string.utf8) + [0]
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    return buffer
}

func copyOut(_ data: Data) -> UnsafeMutablePointer<UInt8>? {
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, data.count))
    data.copyBytes(to: buffer, count: data.count)
    return buffer
}

// MARK: - Errors

let lastErrorKey = "com.voxscripta.ffi.lastError"

func setLastError(_ message: String?) {
    if let message {
        Thread.current.threadDictionary[lastErrorKey] = message
    } else {
        Thread.current.threadDictionary.removeObject(forKey: lastErrorKey)
    }
}

func describe(_ error: any Error) -> String {
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
    _ project_path: UnsafePointer<CChar>?,
    _ options_json: UnsafePointer<CChar>?
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
    guard !project.isEmpty else {
        setLastError("vs_job_start was given an empty path")
        return -2
    }
    // An empty audio path means "resume what is already there", which is a real
    // request rather than a mistake: a project package references its own
    // source, so re-running one needs no audio path at all. The first version
    // had callers pass the project path twice to express this, which worked
    // only because the audio argument is ignored once a manifest exists — a
    // call that reads as a lie.
    let resuming = audio.isEmpty
    if resuming,
       !FileManager.default.fileExists(
            atPath: ProjectPackage(root: URL(filePath: project)).manifestURL.path) {
        setLastError("vs_job_start needs an audio path to create a new project")
        return -2
    }
    let audioURL = resuming ? nil : URL(filePath: audio)
    let projectURL = URL(filePath: project)

    // Decoded before the handle is issued, so a malformed settings blob is a
    // refusal rather than a job that starts and then fails. The caller gets the
    // decoder's own complaint, which names the offending key.
    //
    // Silence and chunking are kept as the wire type rather than folded into
    // JobOptions, because they are not job settings: they are fixed on the
    // manifest when a project is created, since both feed the content hash that
    // decides what a resume may reuse.
    let options: JobOptions
    let wire: JobOptionsWire
    do {
        wire = try Wire.decode(JobOptionsWire.self,
                               from: options_json.map { String(cString: $0) })
            ?? JobOptionsWire()
        options = try wire.resolved()
    } catch {
        setLastError(describe(error))
        return -3
    }

    let (handle, box) = JobRegistry.shared.insert()
    let task = Task.detached {
        do {
            let store = ProjectStore()
            let decoder = JobRunner.defaultDecoder()
            let project: Project
            if resuming || FileManager.default.fileExists(
                atPath: ProjectPackage(root: projectURL).manifestURL.path) {
                project = try await store.open(at: projectURL)
            } else {
                project = try await store.create(
                    from: audioURL!, at: projectURL,
                    silence: wire.silence ?? .default,
                    chunking: wire.chunking ?? .default,
                    locale: options.transcription.locale,
                    concurrency: options.transcription.concurrency,
                    probe: { url in
                        (try await decoder.probe(url: url), try decoder.duration(of: url))
                    })
            }
            _ = try await JobRunner().run(project: project, options: options) { report in
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
    _ options_json: UnsafePointer<CChar>?,
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
        let wire = try Wire.decode(ExportOptionsWire.self,
                                   from: options_json.map { String(cString: $0) })
        let transcript = try AtomicFile.readJSON(Transcript.self, from: source)
        let data = try Exporters.make(exportFormat)
            .export(transcript, options: (wire ?? ExportOptionsWire()).resolved())
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

// MARK: - The library

/// Where projects live when nobody says otherwise. Caller releases it.
///
/// Read from the engine rather than rebuilt in Dart, because the two interfaces
/// disagreeing about where the library is would make them two applications.
@_cdecl("vs_library_default_directory")
public func vs_library_default_directory() -> UnsafeMutablePointer<CChar>? {
    copyOut(ProjectStore.defaultLibraryDirectory.path)
}

/// Lists the projects in `directory` as a JSON array, newest first.
///
/// Returns `[]` for a directory with nothing in it, which is not an error — a
/// fresh install has an empty library and an interface should show an empty
/// library, not a failure. Caller releases the string.
@_cdecl("vs_library_list")
public func vs_library_list(
    _ directory: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    setLastError(nil)
    let path = directory.map { String(cString: $0) }
    let url = (path?.isEmpty == false)
        ? URL(filePath: path!)
        : ProjectStore.defaultLibraryDirectory
    do {
        return copyOut(try Wire.encode(Wire.library(at: url)))
    } catch {
        setLastError(describe(error))
        return nil
    }
}

/// Deletes a project, recoverably.
///
/// §5 is the reason this is not a delete. On a Mac the project goes to the
/// Trash; elsewhere it moves to a `Deleted` folder beside the library, because
/// there is no system Trash to hand it to and a folder the app owns is honest
/// about what it is. Either way the original audio survives, which is the
/// promise that matters.
///
/// Returns JSON `{"movedTo": "<path>"}`, or `{"movedTo": null}` when the
/// platform could not say where it went. Negative on failure, with the reason
/// in `vs_last_error_copy`; the out pointer is left untouched then.
@_cdecl("vs_project_delete")
public func vs_project_delete(
    _ project_path: UnsafePointer<CChar>?,
    _ out_json: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    setLastError(nil)
    guard let project_path, let out_json else {
        setLastError("vs_project_delete requires a project path and an out pointer")
        return -1
    }
    let path = String(cString: project_path)
    guard !path.isEmpty else {
        setLastError("vs_project_delete was given an empty path")
        return -2
    }

    // Called directly. `delete` is not actually async — it is a move — and the
    // first version wrapped it in `Synchronously.run` anyway, which the
    // compiler pointed out by way of an `await` with nothing to wait for. A
    // move has no progress to report and nothing an interface could do with a
    // handle, so there is nothing to wrap.
    do {
        let moved = try ProjectStore().delete(at: URL(filePath: path))
        out_json.pointee = copyOut(try Wire.encode(["movedTo": moved?.path]))
        return 0
    } catch {
        setLastError(describe(error))
        return -4
    }
}

// MARK: - Defaults

/// The engine's own job settings, as JSON. Caller releases it.
///
/// Exists so an interface shows the engine's numbers instead of a second copy
/// of them. A settings screen with its own hardcoded default silence margin is
/// a rule living in an interface, and the moment the engine's changes the two
/// disagree — which is exactly the drift `Docs/PARITY.md` is written to stop.
@_cdecl("vs_job_options_defaults")
public func vs_job_options_defaults() -> UnsafeMutablePointer<CChar>? {
    setLastError(nil)
    do {
        return copyOut(try Wire.encode(JobOptionsWire.defaults))
    } catch {
        setLastError(describe(error))
        return nil
    }
}

/// The engine's own export settings, as JSON. Caller releases it.
@_cdecl("vs_export_options_defaults")
public func vs_export_options_defaults() -> UnsafeMutablePointer<CChar>? {
    setLastError(nil)
    do {
        return copyOut(try Wire.encode(ExportOptionsWire.defaults))
    } catch {
        setLastError(describe(error))
        return nil
    }
}

/// Runs async work from a synchronous C entry point.
///
/// Only for operations that are genuinely quick — a directory move, a manifest
/// read. Anything that does real work gets a handle and is polled instead, so
/// that nothing here can block a Dart isolate for longer than a filesystem
/// call. A semaphore rather than a task group because the caller is a C
/// function and has no async context to suspend in.
private enum Synchronously {
    static func run<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let signal = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            signal.signal()
        }
        signal.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}

/// What a finished project contains, as JSON. Caller releases it.
///
/// One call rather than four, because a transcript screen needs all of it at
/// once to draw a single frame: which of the three transcripts exist, how long
/// each is, and whether POLISH ran and what it decided. Four round trips would
/// each re-open the package.
///
/// Returns `{"variants": [], "polish": {"ran": false, …}}` for a project with
/// nothing finished yet, which is not an error — a job that is still running
/// has no outputs and the screen should say so rather than fail.
@_cdecl("vs_project_summary")
public func vs_project_summary(
    _ project_path: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    setLastError(nil)
    guard let project_path else {
        setLastError("vs_project_summary requires a project path")
        return nil
    }
    let path = String(cString: project_path)
    guard !path.isEmpty else {
        setLastError("vs_project_summary was given an empty path")
        return nil
    }
    do {
        let package = ProjectPackage(root: URL(filePath: path))
        return copyOut(try Wire.encode(Wire.summary(of: package)))
    } catch {
        setLastError(describe(error))
        return nil
    }
}

/// What this build on this machine can do, as JSON. Caller releases it.
///
/// The transcription languages it offers, which of them the text stages
/// understand, which have enough defence for POLISH to be permitted, and which
/// model POLISH would actually use. Every line of that is a rule, which is why
/// it is answered here: a settings screen that worked any of it out for itself
/// would be a second copy of the engine's judgement, free to disagree.
///
/// Blocks briefly — asking the recogniser which locales it supports is a call
/// into a system service. A caller on a UI thread should treat it like reading
/// a file, which is roughly what it costs.
@_cdecl("vs_capabilities")
public func vs_capabilities() -> UnsafeMutablePointer<CChar>? {
    setLastError(nil)
    let capabilities = Synchronously.run { await Wire.capabilities() }
    do {
        return copyOut(try Wire.encode(capabilities))
    } catch {
        setLastError(describe(error))
        return nil
    }
}

/// The waveform, as interleaved little-endian Float32 min/max pairs.
///
/// `buckets` is how many pairs are wanted — pass the pixel width of the view
/// that will draw it, or 0 for every bucket the analysis produced. The result
/// is `2 * buckets * 4` bytes, released with `vs_bytes_free`.
///
/// Bytes rather than JSON because a few thousand buckets as decimal text is
/// twenty times the size, for a drawing that is redrawn on every resize.
/// Downsampling happens here because picking each span's extremes is the only
/// reduction that keeps a waveform looking like the audio — averaging, which
/// is what an interface would reach for, flattens every transient.
///
/// Returns -5 before the analysis stage has run, which is a state to show
/// rather than an error: the processing screen displays "reading audio" until
/// there is a waveform to draw.
@_cdecl("vs_waveform")
public func vs_waveform(
    _ project_path: UnsafePointer<CChar>?,
    _ buckets: Int32,
    _ out_bytes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ out_length: UnsafeMutablePointer<Int64>?
) -> Int32 {
    setLastError(nil)
    guard let project_path, let out_bytes, let out_length else {
        setLastError("vs_waveform requires a project path and two out pointers")
        return -1
    }
    let path = String(cString: project_path)
    guard !path.isEmpty else {
        setLastError("vs_waveform was given an empty path")
        return -2
    }

    let package = ProjectPackage(root: URL(filePath: path))
    guard let data = Wire.waveform(in: package, buckets: Int(buckets)) else {
        setLastError("no waveform yet — the analysis stage has not run")
        return -5
    }
    out_bytes.pointee = copyOut(data)
    out_length.pointee = Int64(data.count)
    return 0
}

/// The sign-up password rules, each marked met or not for `password`.
///
/// Read rather than reimplemented, for the reason every rule in this surface
/// is: a password that passed on a phone and failed on a desktop would be a
/// bug the user is right to report, and one definition is the only way to
/// prevent it.
///
/// Returns a JSON array, caller releases it:
///
///     [{"id": "length", "demand": "At least 8 characters", "satisfied": false}, …]
///
/// Every rule is returned every time, not only the failures, so a form can
/// show the whole checklist filling in as someone types.
@_cdecl("vs_password_rules")
public func vs_password_rules(
    _ password: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    setLastError(nil)
    let text = password.map { String(cString: $0) } ?? ""
    do {
        return copyOut(try Wire.encode(PasswordPolicy.evaluate(text)))
    } catch {
        setLastError(describe(error))
        return nil
    }
}

/// Whether a string could be an email address. 1 yes, 0 no.
///
/// Deliberately permissive — the only authority on an address is whether mail
/// to it arrives. See `EmailAddress` for why a stricter test would be worse.
@_cdecl("vs_email_looks_valid")
public func vs_email_looks_valid(_ address: UnsafePointer<CChar>?) -> Int32 {
    guard let address else { return 0 }
    return EmailAddress.looksValid(String(cString: address)) ? 1 : 0
}
