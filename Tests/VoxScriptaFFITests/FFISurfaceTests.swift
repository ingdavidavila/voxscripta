import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaProject
@testable import VoxScriptaFFI

/// The C ABI, exercised the way Dart will exercise it.
///
/// These tests call the `@_cdecl` entry points directly rather than through a
/// loaded library, which checks everything except the dynamic link: argument
/// marshalling, the handle lifecycle, who owns which buffer, and that a failure
/// arrives as a message rather than a crash. What they deliberately do *not*
/// re-check is transcription — `VoxScriptaPipelineTests` owns that, and routing
/// a second end-to-end run through here would buy nothing but minutes.
///
/// Every string this surface returns is released with `vs_string_free`, in the
/// tests as in a caller, because a test that leaked would be a test that never
/// exercised the contract it is meant to pin.
@Suite("FFI surface")
struct FFISurfaceTests {

    /// Reads an owned C string and releases it, which is the whole caller
    /// protocol in one function.
    private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { vs_string_free(pointer) }
        return String(cString: pointer)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ffi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Version and unknown handles

    @Test("The ABI announces a version")
    func version() {
        #expect(vs_abi_version() == 6)
    }

    @Test("An unknown handle is reported, not crashed on")
    func unknownHandle() {
        // 9_999 was never issued. Every getter has to tolerate it, because a
        // Flutter hot reload can leave Dart holding a handle this library has
        // forgotten.
        #expect(vs_job_state(9_999) == -1)
        #expect(vs_job_fraction(9_999) == 0)
        #expect(take(vs_job_detail_copy(9_999)) == nil)
        #expect(take(vs_job_error_copy(9_999)) == nil)
        #expect(vs_job_cancel(9_999) == -1)
        vs_job_release(9_999)   // must not trap
    }

    @Test("Null paths are refused with a reason rather than a signal")
    func nullPaths() {
        #expect(vs_job_start(nil, nil, nil) == -1)
        let message = take(vs_last_error_copy())
        #expect(message?.isEmpty == false)
    }

    @Test("An empty audio path resumes a project that exists, and is refused otherwise")
    func emptyAudioMeansResume() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appending(path: "p.voxscripta")

        // Nothing there yet: creating a project does need audio.
        let refused = "".withCString { audio in
            project.path.withCString { vs_job_start(audio, $0, nil) }
        }
        #expect(refused == -2)
        #expect(take(vs_last_error_copy())?.contains("needs an audio path") == true)

        // With a manifest in place it is accepted, because the package
        // references its own source — passing the project path twice to say
        // this, as the first version did, read as a lie.
        try FileManager.default.createDirectory(at: project,
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appending(path: "manifest.json"))
        let handle = "".withCString { audio in
            project.path.withCString { vs_job_start(audio, $0, nil) }
        }
        #expect(handle > 0)
        vs_job_release(handle)
    }

    @Test("An empty path is refused before any work starts")
    func emptyPaths() {
        // Found by the Dart bindings: an empty string is not a null pointer, so
        // the first version accepted it, and `URL(filePath: "")` became the
        // working directory — the job started and then failed with "could not
        // be found at .", which tells a caller nothing. Refused synchronously
        // now, with a distinct code so a caller can tell the two apart.
        let refusals: [Int64] = [
            "".withCString { a in "/tmp/p".withCString { vs_job_start(a, $0, nil) } },
            "/tmp/a.wav".withCString { a in "".withCString { vs_job_start(a, $0, nil) } },
        ]
        for refusal in refusals {
            #expect(refusal == -2)
        }
        #expect(take(vs_last_error_copy())?.contains("empty path") == true)
    }

    // MARK: - The job lifecycle

    @Test("A job that cannot start reports failure through the handle")
    func failingJobReportsThroughTheHandle() async throws {
        // Missing audio, so the job fails almost immediately. The point is not
        // the failure — it is that the failure arrives as a state code and a
        // message on the handle, which is the only channel Dart has.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appending(path: "nothing.wav").path
        let project = directory.appending(path: "p.voxscripta").path

        let handle = missing.withCString { audio in
            project.withCString { vs_job_start(audio, $0, nil) }
        }
        #expect(handle > 0)

        // Poll exactly as the interface does. A deadline rather than a fixed
        // sleep, so a slow machine does not produce a flake.
        var state = vs_job_state(handle)
        let deadline = Date().addingTimeInterval(10)
        while state != 9, state != 8, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            state = vs_job_state(handle)
        }
        #expect(state == 9, "expected failed (9), got \(state)")
        let reason = take(vs_job_error_copy(handle))
        #expect(reason?.isEmpty == false)

        vs_job_release(handle)
        #expect(vs_job_state(handle) == -1)
    }

    @Test("Handles are distinct and releasing one leaves the other alone")
    func handlesAreIndependent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "nothing.wav").path

        func start(_ name: String) -> Int64 {
            let project = directory.appending(path: name).path
            return missing.withCString { audio in
                project.withCString { vs_job_start(audio, $0, nil) }
            }
        }
        let first = start("a.voxscripta")
        let second = start("b.voxscripta")
        #expect(first != second)

        vs_job_release(first)
        #expect(vs_job_state(first) == -1)
        #expect(vs_job_state(second) != -1)
        vs_job_release(second)
    }

    // MARK: - Export

    /// A transcript with one segment, written where the exporter will look.
    private func writeTranscript(to package: ProjectPackage) throws {
        try FileManager.default.createDirectory(
            at: package.outputDirectory, withIntermediateDirectories: true)
        let segment = TranscriptSegment(
            originalStart: .seconds(0), originalEnd: .seconds(2),
            text: "The harbour was quiet.", words: [], confidence: 0.9)
        let transcript = Transcript(variant: .verbatim, segments: [segment],
                                    provenance: Provenance())
        try AtomicFile.writeJSON(transcript, to: package.transcriptURL)
    }

    @Test("A transcript exports to bytes the caller owns")
    func exportRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "p.voxscripta")
        let package = ProjectPackage(root: root)
        try writeTranscript(to: package)

        var bytes: UnsafeMutablePointer<UInt8>?
        var length: Int64 = 0
        let status = root.path.withCString { project in
            "verbatim".withCString { variant in
                "txt".withCString { format in
                    vs_export(project, variant, format, nil, &bytes, &length)
                }
            }
        }
        #expect(status == 0)
        let buffer = try #require(bytes)
        defer { vs_bytes_free(buffer) }
        #expect(length > 0)

        let text = String(decoding: UnsafeBufferPointer(start: buffer, count: Int(length)),
                          as: UTF8.self)
        #expect(text.contains("The harbour was quiet."))
    }

    @Test("Every format the engine has is reachable by extension")
    func allFormatsReachable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "p.voxscripta")
        try writeTranscript(to: ProjectPackage(root: root))

        // srt and vtt need timing, which the fixture has. docx is a ZIP, which
        // is why the surface returns bytes rather than a string — a text-only
        // boundary would have quietly excluded it.
        for format in ["txt", "md", "docx", "srt", "vtt"] {
            var bytes: UnsafeMutablePointer<UInt8>?
            var length: Int64 = 0
            let status = root.path.withCString { project in
                "verbatim".withCString { variant in
                    format.withCString { vs_export(project, variant, $0, nil, &bytes, &length) }
                }
            }
            #expect(status == 0, "\(format) failed: \(take(vs_last_error_copy()) ?? "—")")
            if let bytes { vs_bytes_free(bytes) }
            #expect(length > 0, "\(format) produced nothing")
        }
    }

    @Test("A misspelled variant or format is named, not guessed at")
    func badArgumentsAreNamed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "p.voxscripta").path

        var bytes: UnsafeMutablePointer<UInt8>?
        var length: Int64 = 0

        let badVariant = root.withCString { p in
            "pollished".withCString { v in
                "txt".withCString { vs_export(p, v, $0, nil, &bytes, &length) }
            }
        }
        #expect(badVariant == -2)
        #expect(take(vs_last_error_copy())?.contains("pollished") == true)

        let badFormat = root.withCString { p in
            "verbatim".withCString { v in
                "pdf".withCString { vs_export(p, v, $0, nil, &bytes, &length) }
            }
        }
        #expect(badFormat == -3)
        #expect(take(vs_last_error_copy())?.contains("pdf") == true)
    }

    @Test("Exporting a transcript that was never produced fails with a reason")
    func missingTranscript() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appending(path: "empty.voxscripta").path

        var bytes: UnsafeMutablePointer<UInt8>?
        var length: Int64 = 0
        let status = root.withCString { p in
            "polished".withCString { v in
                "txt".withCString { vs_export(p, v, $0, nil, &bytes, &length) }
            }
        }
        #expect(status == -4)
        #expect(take(vs_last_error_copy())?.isEmpty == false)
    }

    // MARK: - Error isolation

    @Test("The last error belongs to the calling thread")
    func errorIsPerThread() throws {
        // Two Dart isolates are two OS threads. If the last error were a global,
        // one isolate's failure would surface as the other's.
        //
        // The second reader is a real `Thread` and not a `Task.detached`, which
        // was the first thing tried and does not work: Swift's cooperative pool
        // can run a detached task on the thread that spawned it, so the task saw
        // the same thread dictionary and read the error back. That is worth
        // knowing rather than working around — the isolation here is per OS
        // thread, which is what an isolate is, and not per task.
        _ = vs_job_start(nil, nil, nil)
        #expect(take(vs_last_error_copy())?.isEmpty == false)

        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            if let p = vs_last_error_copy() {
                box.value = String(cString: p)
                vs_string_free(p)
            }
            done.signal()
        }
        thread.start()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(box.value == nil)

        // And the original thread still has its own.
        #expect(take(vs_last_error_copy())?.isEmpty == false)
    }
}
