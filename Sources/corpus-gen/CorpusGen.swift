import Foundation
import VoxVerbaCore
import VoxVerbaDSP
import VoxVerbaTestSupport

/// Generates the synthetic test corpus.
///
/// Transcription is hard to test because ground truth is expensive. The way out is
/// to synthesize the corpus: render known text with `AVSpeechSynthesizer` offline,
/// then compose test cases programmatically — silences of exact durations at exact
/// offsets, noise at measured SNRs, gain ramps, every sample rate and channel count
/// in §33.
///
/// The result is audio whose transcript is known character-for-character and whose
/// silence boundaries are known to the millisecond, which is what makes both WER
/// measurement and silence-detector accuracy fully automatable — with no human
/// transcription and no licensing question about the audio.
///
/// - Note: Phase 1 implements this alongside the detector it exists to validate.
@main
struct CorpusGen {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let outPath = args.first else {
            print("""
            corpus-gen — synthetic ground-truth audio for the VoxVerba test suite

            USAGE
              corpus-gen <output-directory>              signal corpus for the detector
              corpus-gen <output-directory> --speech <minutes> [--disfluent]

            Emits, for each case, an audio file plus a JSON sidecar holding the exact
            transcript and the exact silence boundaries used to build it.
            """)
            exit(EXIT_FAILURE)
        }

        let opts = Array(args.dropFirst())
        do {
            if let index = opts.firstIndex(of: "--speech") {
                let minutes = index + 1 < opts.count ? Double(opts[index + 1]) ?? 1 : 1
                try await generateSpeech(into: URL(filePath: outPath), minutes: minutes,
                                         disfluent: opts.contains("--disfluent"))
            } else {
                try await generate(into: URL(filePath: outPath))
            }
        } catch let error as VoxVerbaError {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func generate(into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        print("Writing \(StandardCorpus.all.count) cases to \(directory.path)\n")

        for testCase in StandardCorpus.all {
            let audio = try AudioFileWriter.write(testCase, to: directory, format: .wav)

            // The sidecar is the point: ground truth recorded next to the audio,
            // exact by construction rather than transcribed by a person.
            let truth = GroundTruth(
                name: testCase.name,
                purpose: testCase.purpose,
                durationSeconds: testCase.duration.seconds,
                sampleRate: CanonicalFormat.sampleRate,
                expectedSpeechRegions: testCase.expectedSpeechRegions.map {
                    .init(start: $0.start.seconds, end: $0.end.seconds)
                },
                noiseFloorDB: testCase.noiseFloorDB,
                noiseFloorEndDB: testCase.noiseFloorEndDB,
                seed: testCase.seed
            )
            let sidecar = directory.appending(path: "\(testCase.name).json")
            try encoder.encode(truth).write(to: sidecar)

            let regions = testCase.expectedSpeechRegions.count
            print(String(format: "  %-22@ %6.1fs  %d speech region%@",
                         testCase.name as NSString, testCase.duration.seconds,
                         regions, regions == 1 ? "" : "s"))
            print("      \(testCase.purpose)")
            print("      \(audio.lastPathComponent) + \(sidecar.lastPathComponent)\n")
        }

        print("Generation is deterministic: the same inputs produce byte-identical audio,")
        print("so these files are reproducible rather than committed.")
    }

    /// Renders real speech with a known transcript, for word error rate.
    ///
    /// Passages repeat with varied trailing pauses until the requested length is
    /// reached, so the file also exercises the chunk planner's boundary search
    /// rather than being one continuous block.
    static func generateSpeech(into directory: URL, minutes: Double, disfluent: Bool = false) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetSamples = Int(minutes * 60 * Double(CanonicalFormat.sampleRate))
        var samples: [Float] = []
        var spoken: [SpeechPassage] = []
        var round = 0

        print("Synthesizing ~\(minutes) minute(s) of speech…")
        while samples.count < targetSamples {
            let passages = disfluent ? SpeechCorpus.disfluent : SpeechCorpus.standard
            for (index, base) in passages.enumerated() {
                // Vary the pause so boundaries are not perfectly periodic.
                let pause = [0.6, 1.4, 2.2, 0.9, 3.1][(round + index) % 5]
                let passage = SpeechPassage(name: base.name, text: base.text, trailingSilence: pause)
                samples += try await SpeechCorpus.render([passage])
                spoken.append(passage)
                if samples.count >= targetSamples { break }
            }
            round += 1
        }

        let audio = directory.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: samples, to: audio, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        let reference = SpeechCorpus.referenceText(for: spoken)
        let referenceURL = directory.appending(path: "speech.reference.txt")
        try reference.write(to: referenceURL, atomically: true, encoding: .utf8)

        let seconds = Double(samples.count) / Double(CanonicalFormat.sampleRate)
        print(String(format: "  %@  %.1fs  %d passages  %d reference words",
                     audio.lastPathComponent, seconds, spoken.count,
                     TextTokenizer.tokens(reference).count))
        print("  \(referenceURL.lastPathComponent) holds the exact spoken text.")
    }

    /// The sidecar written next to each rendered case.
    struct GroundTruth: Encodable {
        struct Region: Encodable { let start: Double; let end: Double }
        let name: String
        let purpose: String
        let durationSeconds: Double
        let sampleRate: Int
        let expectedSpeechRegions: [Region]
        let noiseFloorDB: Double
        let noiseFloorEndDB: Double?
        let seed: UInt64
    }
}
