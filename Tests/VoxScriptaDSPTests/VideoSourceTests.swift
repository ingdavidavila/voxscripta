import Testing
import Foundation
import AVFoundation
import UniformTypeIdentifiers
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaDSP

/// Video files as sources, and the two ways they go wrong.
@Suite("Video sources")
struct VideoSourceTests {

    @Test("A video's audio track is read in place, with no extraction step",
          arguments: ["clip.mp4", "clip.mov"])
    func decodesAudioFromVideo(name: String) async throws {
        let tmp = try TempDirectory()
        let video = tmp.url.appending(path: name)
        try await VideoFileWriter.writeWithAudio(to: video, seconds: 1)

        let decoder = CanonicalDecoder()
        let format = try await decoder.probe(url: video)
        #expect(format.sampleRate == 44_100)
        #expect(format.channelCount == 1)

        // And it decodes, rather than merely opening.
        let canonical = tmp.url.appending(path: "canonical.f32")
        let samples = try await decoder.decode(url: video, to: canonical) { _ in }
        #expect(samples > Int64(CanonicalFormat.sampleRate) / 2)

        // Nothing was written beside the source: no ripped audio file.
        let beside = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        #expect(Set(beside) == [name, "canonical.f32"])
    }

    @Test("A silent video says so, rather than blaming its format")
    func silentVideoIsNamedAsSuch() async throws {
        let tmp = try TempDirectory()
        let video = tmp.url.appending(path: "silent.mp4")
        try await VideoFileWriter.writeSilent(to: video, seconds: 1)

        await #expect(throws: VoxScriptaError.noAudioTrack(path: video.path)) {
            _ = try await CanonicalDecoder().probe(url: video)
        }
    }

    @Test("A container macOS cannot demux is named, with the fix")
    func unsupportedContainerIsNamed() async throws {
        let tmp = try TempDirectory()
        let file = tmp.url.appending(path: "recording.webm")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: file)

        await #expect(throws: VoxScriptaError.unsupportedContainer(fileExtension: "webm")) {
            _ = try await CanonicalDecoder().probe(url: file)
        }
    }

    @Test("A genuinely damaged file keeps AVFoundation's own explanation")
    func corruptFileKeepsOriginalError() async throws {
        let tmp = try TempDirectory()
        let file = tmp.url.appending(path: "damaged.mp4")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: file)

        // Not a container problem and not a missing track — the fallback stands.
        do {
            _ = try await CanonicalDecoder().probe(url: file)
            Issue.record("expected damaged file to fail")
        } catch let error as VoxScriptaError {
            guard case .unsupportedFormat = error else {
                Issue.record("expected unsupportedFormat, got \(error)")
                return
            }
        }
    }

    @Test("Demuxable containers are read from the system, not hardcoded")
    func demuxableMatchesSystem() {
        for ext in ["mp4", "mov", "m4v", "avi"] {
            let type = try! #require(UTType(filenameExtension: ext))
            #expect(CanonicalDecoder.isDemuxable(type), "\(ext) should be readable")
        }
        // The four that macOS registers a type for but cannot actually open.
        for ext in ["webm", "wmv", "flv", "rm"] {
            let type = try! #require(UTType(filenameExtension: ext))
            #expect(!CanonicalDecoder.isDemuxable(type), "\(ext) should not be offered")
        }
    }
}
