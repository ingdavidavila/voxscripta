import Foundation
import VoxVerbaCore
import VoxVerbaDSP

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
        _ = FrameGeometry.default
        throw VoxVerbaError.notImplemented("corpus-gen — Phase 1")
    }
}
