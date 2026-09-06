import Testing
import Foundation
import VoxVerbaCore
import VoxVerbaTestSupport
@testable import VoxVerbaProject

@Suite("Project packages")
struct ProjectStoreTests {

    /// A small real audio file to import.
    private func makeAudio(in directory: URL) throws -> URL {
        let url = directory.appending(path: "source.wav")
        try AudioFileWriter.write(samples: StandardCorpus.basic.render(), to: url,
                                  format: .wav, sampleRate: CanonicalFormat.sampleRate)
        return url
    }

    private func probe(_ url: URL) async throws -> (AudioFormatDescription, MediaTime) {
        (AudioFormatDescription(sampleRate: 16_000, channelCount: 1, formatDescription: "test"),
         .seconds(18))
    }

    @Test("Referencing leaves the original where the user put it")
    func referencePolicy() async throws {
        let tmp = try TempDirectory()
        let audio = try makeAudio(in: tmp.url)
        let originalSize = try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int64

        let project = try await ProjectStore().create(
            from: audio, at: tmp.url.appending(path: "p.voxverba"),
            policy: .reference, probe: probe)

        #expect(!project.manifest.source.reference.isCopy)
        // The original is untouched and still where it was.
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int64 == originalSize)
        // Nothing was duplicated into the package.
        let copies = try FileManager.default.contentsOfDirectory(
            atPath: project.package.originalDirectory.path)
        #expect(copies.isEmpty)

        let (resolved, release) = try project.resolveSource()
        defer { release() }
        #expect(resolved.lastPathComponent == "source.wav")
    }

    @Test("Copying makes the project self-contained, still without touching the original")
    func copyPolicy() async throws {
        let tmp = try TempDirectory()
        let audio = try makeAudio(in: tmp.url)
        let project = try await ProjectStore().create(
            from: audio, at: tmp.url.appending(path: "p.voxverba"),
            policy: .copy, probe: probe)

        #expect(project.manifest.source.reference.isCopy)
        #expect(FileManager.default.fileExists(atPath: audio.path))   // §5: never moved

        let (resolved, release) = try project.resolveSource()
        defer { release() }
        #expect(resolved.path.contains("Original"))
        #expect(try ContentHash.file(at: resolved) == project.manifest.source.contentHash)
    }

    @Test("A copied project survives the original being deleted")
    func copySurvivesDeletion() async throws {
        let tmp = try TempDirectory()
        let audio = try makeAudio(in: tmp.url)
        let root = tmp.url.appending(path: "p.voxverba")
        _ = try await ProjectStore().create(from: audio, at: root, policy: .copy, probe: probe)

        try FileManager.default.removeItem(at: audio)
        let reopened = try await ProjectStore().open(at: root)
        let (resolved, release) = try reopened.resolveSource()
        defer { release() }
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }

    @Test("A referencing project reports a missing original clearly")
    func referenceReportsMissingSource() async throws {
        let tmp = try TempDirectory()
        let audio = try makeAudio(in: tmp.url)
        let root = tmp.url.appending(path: "p.voxverba")
        _ = try await ProjectStore().create(from: audio, at: root, policy: .reference, probe: probe)

        try FileManager.default.removeItem(at: audio)
        let reopened = try await ProjectStore().open(at: root)
        #expect(throws: VoxVerbaError.self) { _ = try reopened.resolveSource() }
    }

    @Test("Reopening restores the manifest and job state")
    func reopen() async throws {
        let tmp = try TempDirectory()
        let audio = try makeAudio(in: tmp.url)
        let root = tmp.url.appending(path: "p.voxverba")

        let created = try await ProjectStore().create(from: audio, at: root, probe: probe)
        try await created.store.setState(.chunking)
        await created.store.close()

        let reopened = try await ProjectStore().open(at: root)
        #expect(try await reopened.store.loadState() == .chunking)
        #expect(reopened.manifest.source.contentHash == created.manifest.source.contentHash)
        #expect(reopened.manifest.projectID == created.manifest.projectID)
    }

    @Test("Opening clears temporary files left by an interrupted write")
    func clearsOrphans() async throws {
        let tmp = try TempDirectory()
        let audio = try makeAudio(in: tmp.url)
        let root = tmp.url.appending(path: "p.voxverba")
        _ = try await ProjectStore().create(from: audio, at: root, probe: probe)

        let derived = root.appending(path: "Derived")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let orphan = derived.appending(path: ".canonical.f32.abc.tmp")
        try Data("half written".utf8).write(to: orphan)

        _ = try await ProjectStore().open(at: root)
        // Anything still carrying the temporary suffix never became a committed
        // artifact, so removing it can never lose data.
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("A project from a newer schema is refused rather than misread")
    func rejectsNewerSchema() async throws {
        let tmp = try TempDirectory()
        let audio = try makeAudio(in: tmp.url)
        let root = tmp.url.appending(path: "p.voxverba")
        let created = try await ProjectStore().create(from: audio, at: root, probe: probe)
        await created.store.close()

        let manifestURL = root.appending(path: "manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        json["schemaVersion"] = VoxVerba.projectSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        await #expect(throws: VoxVerbaError.self) { _ = try await ProjectStore().open(at: root) }
    }

    @Test("Reclaiming storage never touches the original or the output")
    func reclaimSpares() async throws {
        let tmp = try TempDirectory()
        let audio = try makeAudio(in: tmp.url)
        let root = tmp.url.appending(path: "p.voxverba")
        let project = try await ProjectStore().create(from: audio, at: root, policy: .copy, probe: probe)

        try AtomicFile.write(Data(repeating: 0, count: 100_000), to: project.package.canonicalAudioURL)
        try AtomicFile.write(Data("final".utf8),
                             to: project.package.outputDirectory.appending(path: "verbatim.txt"))

        let freed = try project.reclaimDerivedStorage()
        #expect(freed >= 100_000)
        #expect(!FileManager.default.fileExists(atPath: project.package.canonicalAudioURL.path))
        // §5: the original and the outputs are not reclaimable, ever.
        let (resolved, release) = try project.resolveSource()
        defer { release() }
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(FileManager.default.fileExists(
            atPath: project.package.outputDirectory.appending(path: "verbatim.txt").path))
        #expect(FileManager.default.fileExists(atPath: project.package.manifestURL.path))
    }
}

@Suite("Manifest compatibility")
struct ManifestCompatibilityTests {

    /// A manifest as written before `locale` and `concurrency` existed.
    private let olderManifest = """
        {
          "schemaVersion": 1,
          "projectID": "5E3B7A1C-1111-4222-8333-444455556666",
          "source": {
            "id": "5E3B7A1C-9999-4222-8333-444455556666",
            "reference": { "insidePackage": { "filename": "a.wav" } },
            "displayName": "a.wav",
            "contentHash": "abc",
            "format": { "sampleRate": 16000, "channelCount": 1, "formatDescription": "test" },
            "duration": { "nanoseconds": 18000000000 },
            "byteSize": 1234,
            "importedAt": "2026-01-01T00:00:00Z"
          },
          "silenceParameters": {
            "marginDB": 8, "hysteresisDB": 4, "absoluteFloorDB": -65,
            "minSpeechDuration": { "nanoseconds": 200000000 },
            "minSilenceDuration": { "nanoseconds": 500000000 },
            "padLead": { "nanoseconds": 200000000 },
            "padTrail": { "nanoseconds": 350000000 },
            "paragraphPauseThreshold": { "nanoseconds": 1500000000 },
            "sectionPauseThreshold": { "nanoseconds": 4000000000 },
            "fricativeProtection": true
          },
          "chunkParameters": {
            "minDuration": { "nanoseconds": 120000000000 },
            "maxDuration": { "nanoseconds": 300000000000 },
            "targetDuration": { "nanoseconds": 240000000000 },
            "overlapDuration": { "nanoseconds": 3000000000 },
            "minBoundaryGap": { "nanoseconds": 400000000 }
          },
          "engineID": "apple.speech-transcriber",
          "createdAt": "2026-01-01T00:00:00Z",
          "modifiedAt": "2026-01-01T00:00:00Z"
        }
        """

    @Test("A manifest missing newer fields still decodes")
    func decodesOlderManifest() throws {
        // The regression this guards: adding two non-optional Codable properties
        // made every existing project undecodable, and because the library skips
        // what it cannot read, they vanished from the sidebar. Nothing was lost on
        // disk, but from the user's side their work had disappeared.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ProjectManifest.self,
                                          from: Data(olderManifest.utf8))

        #expect(manifest.source.displayName == "a.wav")
        // Fields added later fall back to their defaults rather than failing.
        #expect(manifest.locale == "en-US")
        #expect(manifest.concurrency == 4)
        #expect(manifest.silenceParameters.marginDB == 8)
    }

    @Test("A project written by an older version opens")
    func opensOlderProject() async throws {
        let tmp = try TempDirectory()
        let root = tmp.url.appending(path: "old.voxverba")
        try FileManager.default.createDirectory(
            at: root.appending(path: "Original"), withIntermediateDirectories: true)
        try Data(olderManifest.utf8).write(to: root.appending(path: "manifest.json"))

        let project = try await ProjectStore().open(at: root)
        #expect(project.manifest.locale == "en-US")
        #expect(project.manifest.concurrency == 4)
    }
}
