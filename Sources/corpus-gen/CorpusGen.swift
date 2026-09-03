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
              corpus-gen <output-directory> [--cases <name,name,...>]

            Emits, for each case, an audio file plus a JSON sidecar holding the exact
            transcript and the exact silence boundaries used to build it.
            """)
            exit(EXIT_FAILURE)
        }

        do {
            try await generate(into: URL(filePath: outPath))
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
