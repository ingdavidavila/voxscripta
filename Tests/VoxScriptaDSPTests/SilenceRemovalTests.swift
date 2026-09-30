import Testing
import Foundation
import AVFoundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaDSP

@Suite("Silence-removed rendering")
struct SilenceRemovalTests {

    /// Renders a corpus case, detects its silence, and writes the shortened copy.
    private func render(
        _ testCase: CorpusCase,
        in tmp: borrowing TempDirectory,
        sampleRate: Int = 44_100
    ) async throws -> (source: URL, output: URL, map: SilenceMap, result: SilenceRemovalMap) {
        let source = try AudioFileWriter.write(testCase, to: tmp.url,
                                               format: .wav, sampleRate: sampleRate)
        let canonical = try tmp.writeCanonical(testCase.render())
        let features = try await FrameAnalyzer().analyze(canonicalFile: canonical,
                                                         geometry: .default) { _ in }
        let map = try SilenceDetector().detect(
            features: features, parameters: .default,
            sourceDuration: testCase.duration, parameterHash: "render")

        let output = tmp.url.appending(path: "short.wav")
        let result = try await SilenceRemovalRenderer()
            .render(source: source, to: output, using: map)
        return (source, output, map, result)
    }

    @Test("The rendered file is as long as the speech it kept")
    func lengthMatchesSpeech() async throws {
        let tmp = try TempDirectory()
        let run = try await render(StandardCorpus.basic, in: tmp)

        // Within a frame or two of the summed speech regions.
        let expected = run.map.speechDuration.seconds
        #expect(abs(run.result.renderedDuration.seconds - expected) < 0.05,
                "rendered \(run.result.renderedDuration) for \(run.map.speechDuration) of speech")
        #expect(run.result.renderedDuration < run.result.originalDuration)
        #expect(run.result.removedDuration > .zero)
    }

    @Test("The original is not modified")
    func originalUntouched() async throws {
        // §5, at the one place in the codebase that writes audio.
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url,
                                               format: .wav, sampleRate: 44_100)
        let before = try Data(contentsOf: source)

        _ = try await render(StandardCorpus.basic, in: tmp)

        // Byte-for-byte, not merely the same size.
        let after = try Data(contentsOf: source)
        #expect(after == before)
    }

    @Test("The output keeps the source's rate and channel count")
    func preservesSourceFormat() async throws {
        let tmp = try TempDirectory()
        let run = try await render(StandardCorpus.basic, in: tmp, sampleRate: 44_100)

        let output = try AVAudioFile(forReading: run.output)
        // Rendered from the original, not from the 16 kHz analysis copy — the
        // whole point of this artifact is that it is listenable.
        #expect(output.fileFormat.sampleRate == 44_100)
        #expect(output.fileFormat.channelCount == 1)
        #expect(output.length > 0)
    }

    @Test("A shortened copy is not larger than the original")
    func notLargerThanSource() async throws {
        // Forcing a fixed 24-bit output once made a shortened 16-bit recording
        // bigger than the file it came from, which is a confusing thing to hand
        // someone who asked to remove silence.
        let tmp = try TempDirectory()
        let run = try await render(StandardCorpus.basic, in: tmp, sampleRate: 44_100)
        let sourceSize = try FileManager.default
            .attributesOfItem(atPath: run.source.path)[.size] as? Int64 ?? 0
        let outputSize = try FileManager.default
            .attributesOfItem(atPath: run.output.path)[.size] as? Int64 ?? 0
        #expect(outputSize < sourceSize)
    }

    @Test("The time map covers the output and maps back to the original")
    func timeMapRoundTrips() async throws {
        let tmp = try TempDirectory()
        let run = try await render(StandardCorpus.basic, in: tmp)
        let result = run.result

        #expect(result.spans.count == run.map.speechRegions.count)

        // Spans tile the rendered file with no gap.
        for (a, b) in zip(result.spans, result.spans.dropFirst()) {
            #expect(a.rendered.end == b.rendered.start)
            #expect(a.original.end <= b.original.start)
        }
        #expect(result.spans.first?.rendered.start == .zero)
        #expect(abs((result.spans.last?.rendered.end ?? .zero).seconds
                    - result.renderedDuration.seconds) < 0.01)

        // §7: a listener can locate themselves in the source recording.
        for span in result.spans {
            let midpoint = span.rendered.start + span.rendered.duration * 0.5
            let original = result.originalTime(forRendered: midpoint)
            #expect(original != nil)
            #expect(span.original.contains(original!) || original == span.original.end,
                    "rendered \(midpoint) mapped outside its source span")
        }
    }

    @Test("Removed silence is accounted for span by span")
    func accountsForRemovedSilence() async throws {
        let tmp = try TempDirectory()
        let run = try await render(StandardCorpus.longPause, in: tmp)

        // The corpus case has a five-second pause; it must show up as a cut.
        let biggest = run.result.spans.map(\.removedBefore).max() ?? .zero
        #expect(biggest > .seconds(3), "the long pause was not recorded as removed")

        let totalCut = run.result.spans.reduce(MediaTime.zero) { $0 + $1.removedBefore }
        #expect(totalCut <= run.result.removedDuration + .milliseconds(50))
    }

    @Test("Joins are faded, so a splice does not click")
    func joinsAreFaded() async throws {
        let tmp = try TempDirectory()
        let run = try await render(StandardCorpus.basic, in: tmp, sampleRate: 44_100)
        guard run.result.spans.count > 1 else { return }

        let file = try AVAudioFile(forReading: run.output)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]

        // The very first sample of a faded-in region is scaled to zero, so a join
        // never starts at full amplitude. Without the fade, splicing two regions
        // at arbitrary phase produces an audible click at every cut.
        let rate = Int(format.sampleRate)
        for span in run.result.spans.dropFirst() {
            let joinFrame = Int(span.rendered.start.samples(at: rate))
            guard joinFrame < Int(buffer.frameLength) else { continue }
            #expect(abs(samples[joinFrame]) < 0.001,
                    "the join at \(span.rendered.start) was not faded in")
        }
    }

    @Test("A map with no speech is refused rather than writing an empty file")
    func refusesEmptyMap() async throws {
        let tmp = try TempDirectory()
        let source = try AudioFileWriter.write(StandardCorpus.basic, to: tmp.url, format: .wav)
        let empty = SilenceMap(speechRegions: [], gaps: [], noiseFloorProfile: [],
                               parameters: .default, parameterHash: "x",
                               sourceDuration: .seconds(18))
        await #expect(throws: VoxScriptaError.noSpeechDetected) {
            _ = try await SilenceRemovalRenderer().render(
                source: source, to: tmp.url.appending(path: "out.wav"), using: empty)
        }
    }

    @Test("The rendered audio still contains speech-level signal")
    func outputHasSignal() async throws {
        let tmp = try TempDirectory()
        let run = try await render(StandardCorpus.basic, in: tmp, sampleRate: 44_100)

        let file = try AVAudioFile(forReading: run.output)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                          count: Int(buffer.frameLength))
        let peak = samples.map(abs).max() ?? 0
        // Silence removal that removed the speech instead would still produce a
        // plausible-looking file of the right length.
        #expect(peak > 0.05, "the rendered audio is silent")
    }
}
