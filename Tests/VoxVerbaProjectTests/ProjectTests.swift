import Testing
import Foundation
import VoxVerbaCore
@testable import VoxVerbaProject

@Suite("Project package layout")
struct ProjectPackageTests {

    private let pkg = ProjectPackage(root: URL(filePath: "/tmp/Interview.voxverba"))

    @Test("Paths resolve under the package root")
    func paths() {
        #expect(pkg.manifestURL.lastPathComponent == "manifest.json")
        #expect(pkg.jobStoreURL.lastPathComponent == "job.sqlite")
        #expect(pkg.canonicalAudioURL.lastPathComponent == "canonical.f32")
        #expect(pkg.chunkResultURL(sequence: 7).lastPathComponent == "0007.json")
        #expect(pkg.chunkResultURL(sequence: 1234).lastPathComponent == "1234.json")
    }

    @Test("Chunk result names sort lexicographically in sequence order")
    func chunkNamesSort() {
        // Zero-padding matters: a directory listing must match processing order.
        let names = (1...200).map { pkg.chunkResultURL(sequence: $0).lastPathComponent }
        #expect(names == names.sorted())
    }

    @Test("Cleanup never touches the original, the manifest, or the outputs")
    func cleanupIsSafe() {
        // §5 is a hard requirement, so it gets a test rather than a convention.
        let reclaimable = Set(pkg.reclaimableDirectories.map(\.path))
        #expect(!reclaimable.contains(pkg.originalDirectory.path))
        #expect(!reclaimable.contains(pkg.outputDirectory.path))
        #expect(!reclaimable.contains(pkg.manifestURL.path))
        #expect(reclaimable.contains(pkg.derivedDirectory.path))
    }

    @Test("Canonical audio lives under a reclaimable directory")
    func derivedIsReclaimable() {
        #expect(pkg.canonicalAudioURL.path.hasPrefix(pkg.derivedDirectory.path))
    }
}

@Suite("Manifest")
struct ManifestTests {

    private func makeSource() -> AudioSource {
        AudioSource(
            bookmark: Data([0x01, 0x02]),
            displayName: "Interview.wav",
            contentHash: "abc123",
            format: AudioFormatDescription(sampleRate: 48_000, channelCount: 2,
                                           bitDepth: 24, formatDescription: "WAV PCM"),
            duration: .seconds(3600),
            byteSize: 1_000_000
        )
    }

    @Test("Manifest round-trips through JSON")
    func codable() throws {
        let m = ProjectManifest(source: makeSource())
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ProjectManifest.self, from: data)
        #expect(back.schemaVersion == VoxVerba.projectSchemaVersion)
        #expect(back.source.displayName == "Interview.wav")
        #expect(back.source.duration == .seconds(3600))
        #expect(back.engineID == .appleSpeech)
    }

    @Test("A source's time range spans the whole recording")
    func sourceRange() {
        #expect(makeSource().timeRange == TimeRange(start: .zero, end: .seconds(3600)))
    }
}

@Suite("Resume and job store placeholders")
struct ResumePlaceholderTests {

    @Test("Resume planner")
    func planner() async {
        await #expect(throws: VoxVerbaError.self) {
            try await ResumePlanner().plan(for: ProjectPackage(root: URL(filePath: "/tmp/x")))
        }
    }

    @Test("Job store")
    func store() async {
        let s = JobStore(url: URL(filePath: "/tmp/job.sqlite"))
        await #expect(throws: VoxVerbaError.self) { try await s.loadState() }
        await #expect(throws: VoxVerbaError.self) { try await s.outstandingChunks() }
    }

    @Test("Resume plans are comparable, which the recovery tests rely on")
    func plansEquatable() {
        #expect(ResumePlan.alreadyComplete == ResumePlan.alreadyComplete)
        #expect(ResumePlan.restart(from: .chunking) != ResumePlan.restart(from: .merging))
    }
}
