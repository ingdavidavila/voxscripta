import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaProject
import VoxScriptaTranscription
import VoxScriptaPipeline
import VoxScriptaLanguage
@testable import VoxScriptaFFI

/// The library, settings and defaults halves of the ABI.
///
/// Separate from `FFISurfaceTests` because these answer a different question.
/// That suite asks whether the boundary works at all — handles, ownership,
/// signals. This one asks whether the JSON the interface will be built on is
/// the shape it claims, which is the part that a wrong answer makes a Flutter
/// screen silently empty rather than crash.
@Suite("FFI library and options")
struct FFILibraryTests {

    private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { vs_string_free(pointer) }
        return String(cString: pointer)
    }

    private func json(_ text: String?) throws -> Any {
        let data = try #require(text?.data(using: .utf8))
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// A path from the ABI, made comparable with one built here.
    private func resolved(_ value: Any?) -> String? {
        guard let path = value as? String else { return nil }
        return URL(filePath: path).resolvingSymlinksInPath().path
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ffi-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Defaults

    @Test("Job defaults are the engine's own, in the shape the input takes")
    func jobDefaults() throws {
        let decoded = try json(take(vs_job_options_defaults()))
        let object = try #require(decoded as? [String: Any])

        // Every key the wire type offers is present, so an interface can render
        // a settings screen from this alone rather than from a second list.
        for key in ["locale", "detectLanguage", "concurrency", "silence", "chunking",
                    "clean", "polish", "polishEnabled", "polishBackend",
                    "keepIntermediates"] {
            #expect(object[key] != nil, "missing \(key)")
        }
        // Spot-checked against the engine rather than against a literal, which
        // is the whole point of the call existing.
        #expect(object["concurrency"] as? Int == TranscriptionOptions.default.concurrency)
        #expect(object["locale"] as? String == TranscriptionOptions.default.locale)

        // And it round-trips: the defaults are valid input.
        let wire = try #require(
            try Wire.decode(JobOptionsWire.self, from: take(vs_job_options_defaults())))
        _ = try wire.resolved()
    }

    @Test("Export defaults round-trip too")
    func exportDefaults() throws {
        let text = take(vs_export_options_defaults())
        let object = try #require(try json(text) as? [String: Any])
        #expect(object["includeTimestamps"] as? Bool == false)
        #expect(object["maximumCueLength"] as? Int == 84)
        let wire = try #require(try Wire.decode(ExportOptionsWire.self, from: text))
        #expect(wire.resolved().maximumCueLength == 84)
    }

    @Test("A named backend that does not exist is refused, not substituted")
    func unknownBackendRefused() throws {
        let options = #"{"polishBackend":"gpt"}"#
        let handle = "/tmp/a.wav".withCString { audio in
            "/tmp/p.voxscripta".withCString { project in
                options.withCString { vs_job_start(audio, project, $0) }
            }
        }
        #expect(handle == -3)
        #expect(take(vs_last_error_copy())?.contains("gpt") == true)
    }

    @Test("Malformed settings are refused before a handle is issued")
    func malformedOptionsRefused() throws {
        let handle = "/tmp/a.wav".withCString { audio in
            "/tmp/p.voxscripta".withCString { project in
                "{not json".withCString { vs_job_start(audio, project, $0) }
            }
        }
        #expect(handle == -3)
        #expect(take(vs_last_error_copy())?.isEmpty == false)
    }

    // MARK: - The library

    @Test("The default library directory is the one the engine uses")
    func defaultDirectory() {
        let path = take(vs_library_default_directory())
        #expect(path == ProjectStore.defaultLibraryDirectory.path)
        // Which is the same answer the SwiftUI app gets, because it now asks
        // the engine too rather than building the path again.
        #expect(path?.hasSuffix("VoxScripta/Projects") == true)
    }

    @Test("An empty library lists as empty rather than as a failure")
    func emptyLibrary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = directory.path.withCString { take(vs_library_list($0)) }
        #expect(text == "[]")
        #expect(take(vs_last_error_copy()) == nil)
    }

    @Test("A directory that does not exist yet lists as empty, having been made")
    func missingLibraryIsCreated() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appending(path: "not-there-yet")

        let text = directory.path.withCString { take(vs_library_list($0)) }
        #expect(text == "[]")
        // A fresh install has no library folder, and an interface should see an
        // empty shelf rather than an error on first launch.
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Projects list newest first, with the fields the header documents")
    func listsProjects() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = try await makeProject(in: directory, named: "older")
        try await Task.sleep(for: .milliseconds(20))
        let newer = try await makeProject(in: directory, named: "newer")

        let text = directory.path.withCString { take(vs_library_list($0)) }
        let rows = try #require(try json(text) as? [[String: Any]])
        #expect(rows.count == 2)

        // Compared through resolved paths, because on a Mac /var is a symlink to
        // /private/var: NSTemporaryDirectory() hands back the former and
        // contentsOfDirectory reports the latter, so the raw strings differ for
        // the same directory. The first version of this test compared them
        // directly and failed with the ordering perfectly correct.
        #expect(resolved(rows[0]["path"]) == newer.resolvingSymlinksInPath().path)
        #expect(resolved(rows[1]["path"]) == older.resolvingSymlinksInPath().path)
        for key in ["id", "path", "displayName", "durationSeconds", "state", "modifiedAt"] {
            #expect(rows[0][key] != nil, "missing \(key)")
        }
        #expect(rows[0]["state"] as? String == JobState.complete.rawValue)
        #expect((rows[0]["modifiedAt"] as? Double ?? 0) > 0)
    }

    @Test("A folder with nothing a manifest in it is skipped, not fatal")
    func skipsRubbish() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Right extension, no manifest. A half-copied project should cost one
        // row, not the whole list.
        let junk = directory.appending(path: "broken.\(ProjectPackage.fileExtension)")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("not a manifest".utf8).write(to: junk.appending(path: "manifest.json"))

        let text = directory.path.withCString { take(vs_library_list($0)) }
        #expect(text == "[]")
    }

    // MARK: - Deleting

    @Test("Deleting moves the project somewhere recoverable")
    func deleteIsRecoverable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await makeProject(in: directory, named: "doomed")

        var out: UnsafeMutablePointer<CChar>?
        let status = project.path.withCString { vs_project_delete($0, &out) }
        #expect(status == 0)

        let object = try #require(try json(take(out)) as? [String: Any])
        // §5: the audio is never destroyed. Where it went depends on the
        // platform — the Trash on a Mac, a Deleted folder elsewhere — so the
        // test asserts it moved, not where to.
        #expect(object.keys.contains("movedTo"))
        #expect(FileManager.default.fileExists(atPath: project.path) == false)

        let remaining = directory.path.withCString { take(vs_library_list($0)) }
        #expect(remaining == "[]")
    }

    @Test("Deleting something that is not a project is refused")
    func deleteRefusesRubbish() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var out: UnsafeMutablePointer<CChar>?
        let status = directory.path.withCString { vs_project_delete($0, &out) }
        #expect(status == -4)
        #expect(take(vs_last_error_copy())?.isEmpty == false)
        #expect(out == nil)
    }

    @Test("An empty path is refused with its own code")
    func deleteRefusesEmptyPath() {
        var out: UnsafeMutablePointer<CChar>?
        #expect("".withCString { vs_project_delete($0, &out) } == -2)
        #expect(vs_project_delete(nil, nil) == -1)
    }

    // MARK: - Fixtures

    /// A real project package, made through the store so the manifest is one
    /// the engine wrote rather than one this test invented.
    private func makeProject(in directory: URL, named name: String) async throws -> URL {
        let audio = directory.appending(path: "\(name).wav")
        try writeSilentWAV(to: audio)
        let root = directory.appending(path: "\(name).\(ProjectPackage.fileExtension)")
        let decoder = JobRunner.defaultDecoder()
        _ = try await ProjectStore().create(
            from: audio, at: root,
            probe: { url in
                (try await decoder.probe(url: url), try decoder.duration(of: url))
            })
        return root
    }

    /// Half a second of silence. Short on purpose: these tests are about the
    /// manifest and the listing, and decoding anything longer would only make
    /// them slower.
    private func writeSilentWAV(to url: URL) throws {
        let sampleRate = 16_000, seconds = 0.5
        let frames = Int(Double(sampleRate) * seconds)
        let dataBytes = frames * 2
        var out = Data()
        func le32(_ v: Int) { out.append(contentsOf: withUnsafeBytes(of: UInt32(v).littleEndian, Array.init)) }
        func le16(_ v: Int) { out.append(contentsOf: withUnsafeBytes(of: UInt16(v).littleEndian, Array.init)) }
        out.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataBytes)
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(1); le16(1); le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        out.append(contentsOf: Array("data".utf8)); le32(dataBytes)
        out.append(Data(count: dataBytes))
        try out.write(to: url)
    }
}

/// `vs_project_summary`, which the transcript screen is built on.
@Suite("FFI project summary")
struct FFISummaryTests {

    private func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { vs_string_free(pointer) }
        return String(cString: pointer)
    }

    private func summary(of root: URL) throws -> [String: Any] {
        let text = try #require(root.path.withCString { take(vs_project_summary($0)) })
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryPackage() throws -> ProjectPackage {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "summary-\(UUID().uuidString).\(ProjectPackage.fileExtension)")
        let package = ProjectPackage(root: root)
        try FileManager.default.createDirectory(at: package.outputDirectory,
                                                withIntermediateDirectories: true)
        return package
    }

    private func write(_ variant: TranscriptVariant, to url: URL, sentences: [String]) throws {
        let segments = sentences.enumerated().map { index, text in
            TranscriptSegment(
                originalStart: .seconds(Double(index) * 2),
                originalEnd: .seconds(Double(index) * 2 + 2),
                text: text,
                words: text.split(separator: " ").map {
                    Word(text: String($0), originalStart: .zero, originalEnd: .zero,
                         confidence: 0.9)
                })
        }
        try AtomicFile.writeJSON(
            Transcript(variant: variant, segments: segments, provenance: Provenance()),
            to: url)
    }

    @Test("A project with nothing finished reports no variants, not an error")
    func emptyProject() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package.root) }

        let object = try summary(of: package.root)
        #expect((object["variants"] as? [Any])?.isEmpty == true)
        let polish = try #require(object["polish"] as? [String: Any])
        #expect(polish["ran"] as? Bool == false)
        #expect(take(vs_last_error_copy()) == nil)
    }

    @Test("Only the transcripts that exist are listed, with their counts")
    func listsWhatExists() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package.root) }

        try write(.verbatim, to: package.transcriptURL,
                  sentences: ["one two three", "four five"])
        try write(.clean, to: package.cleanTranscriptURL,
                  sentences: ["one two three"])
        // No polished transcript: the stage has not run.

        let variants = try #require(try summary(of: package.root)["variants"] as? [[String: Any]])
        #expect(variants.count == 2)
        #expect(variants[0]["variant"] as? String == "verbatim")
        #expect(variants[0]["words"] as? Int == 5)
        #expect(variants[0]["segments"] as? Int == 2)
        #expect(variants[1]["variant"] as? String == "clean")
        #expect(variants[1]["words"] as? Int == 3)
    }

    @Test("A declined polish carries the engine's reason, not a blank")
    func skipReasonSurvives() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package.root) }

        let reason = "Apple Intelligence is unavailable and this build ships no model"
        try Data(reason.utf8).write(to: package.polishSkippedURL)

        let polish = try #require(try summary(of: package.root)["polish"] as? [String: Any])
        // §26: a missing polished transcript must never be unexplained.
        #expect(polish["ran"] as? Bool == false)
        #expect(polish["skipReason"] as? String == reason)
    }

    @Test("Counts and evidence are separated, so a clean run is not a megabyte")
    func countsAndEvidenceAreSeparate() throws {
        let package = try temporaryPackage()
        defer { try? FileManager.default.removeItem(at: package.root) }

        func sentence(_ disposition: PolishDisposition, _ reasons: [String] = [])
            -> PolishedSentence {
            PolishedSentence(
                segmentID: SegmentID(), original: "before", revised: "after",
                report: ValidationReport(results: reasons.map {
                    CheckResult(check: .polarity, passed: false, detail: $0)
                }),
                disposition: disposition)
        }

        try AtomicFile.writeJSON([
            sentence(.accepted), sentence(.accepted), sentence(.accepted),
            sentence(.acceptedAfterRetry),
            sentence(.fellBackToClean, ["polarity reversed"]),
            sentence(.modelFailed),
        ], to: package.polishReportURL)

        let polish = try #require(try summary(of: package.root)["polish"] as? [String: Any])
        #expect(polish["ran"] as? Bool == true)
        #expect(polish["accepted"] as? Int == 3)
        #expect(polish["acceptedAfterRetry"] as? Int == 1)
        #expect(polish["keptClean"] as? Int == 2)

        // Three plain acceptances are counted and not carried; the retry and
        // the two fallbacks are the ones worth reading.
        let flagged = try #require(polish["flagged"] as? [[String: Any]])
        #expect(flagged.count == 3)
        #expect(flagged.contains { $0["disposition"] as? String == "acceptedAfterRetry" })
        #expect(flagged.contains {
            ($0["reasons"] as? [String])?.contains("polarity reversed") == true
        })
    }

    @Test("An empty path is refused rather than reported as an empty project")
    func emptyPathRefused() {
        #expect("".withCString { vs_project_summary($0) } == nil)
        #expect(take(vs_last_error_copy())?.isEmpty == false)
        #expect(vs_project_summary(nil) == nil)
    }
}
