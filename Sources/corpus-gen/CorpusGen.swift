import Foundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaTestSupport

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
            corpus-gen — synthetic ground-truth audio for the VoxScripta test suite

            USAGE
              corpus-gen <output-directory>              signal corpus for the detector
              corpus-gen <output-directory> --speech <minutes> [--disfluent]
                                              [--language en-US|es-ES]

              corpus-gen <output-directory> --reading-script
                                              [--language en-US|es-ES]

            A fixture over five minutes plans several chunks, so it exercises
            the merge seams that short fixtures cannot reach.

            --reading-script writes a passage for a person to read aloud, and
            the exact reference text to measure the recording against. Every
            other figure in this project comes from synthesized speech.

            Emits, for each case, an audio file plus a JSON sidecar holding the exact
            transcript and the exact silence boundaries used to build it.
            """)
            exit(EXIT_FAILURE)
        }

        let opts = Array(args.dropFirst())
        do {
            if opts.contains("--reading-script") {
                // No synthesizer needed: this writes text for a person to
                // read, so it works on every platform.
                var language = "en-US"
                if let at = opts.firstIndex(of: "--language"), at + 1 < opts.count {
                    language = opts[at + 1]
                }
                try generateReadingScript(into: URL(filePath: outPath), language: language)
            } else if let index = opts.firstIndex(of: "--speech") {
                #if canImport(AVFoundation)
                let minutes = index + 1 < opts.count ? Double(opts[index + 1]) ?? 1 : 1
                var language = "en-US"
                if let at = opts.firstIndex(of: "--language"), at + 1 < opts.count {
                    language = opts[at + 1]
                }
                try await generateSpeech(into: URL(filePath: outPath), minutes: minutes,
                                         disfluent: opts.contains("--disfluent"),
                                         language: language)
                #else
                // The signal corpus below is portable; the speech corpus needs
                // AVSpeechSynthesizer. Said plainly rather than left to fail at
                // the first call, and rather than emitting silence that would
                // look like a corpus.
                FileHandle.standardError.write(Data("""
                    error: --speech needs a speech synthesizer, which this \
                    platform does not have. Generate the speech corpus on a Mac \
                    and copy the directory across; the signal corpus (no \
                    --speech) works here.

                    """.utf8))
                exit(EXIT_FAILURE)
                #endif
            } else {
                try await generate(into: URL(filePath: outPath))
            }
        } catch let error as VoxScriptaError {
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

    #if canImport(AVFoundation)
    /// Renders real speech with a known transcript, for word error rate.
    ///
    /// Passages repeat with varied trailing pauses until the requested length is
    /// reached, so the file also exercises the chunk planner's boundary search
    /// rather than being one continuous block.
    static func generateSpeech(into directory: URL, minutes: Double,
                               disfluent: Bool = false,
                               language: String = "en-US") async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetSamples = Int(minutes * 60 * Double(CanonicalFormat.sampleRate))
        var samples: [Float] = []
        var spoken: [SpeechPassage] = []
        var round = 0

        // The widest pool available, not just the five entity passages.
        //
        // This used to loop `SpeechCorpus.standard`, five sentences, which is
        // fine for a one-minute fixture and poor for the long ones: Whisper
        // suppresses repeated text, so a five-minute recording of five
        // sentences on a loop risks measuring that suppression rather than
        // whatever the fixture was made for. The acoustic set adds eight more
        // with no proper nouns in them, giving thirteen.
        let pool: [SpeechPassage]
        if disfluent {
            pool = SpeechCorpus.disfluent
        } else if language.hasPrefix("es") {
            pool = SpeechCorpus.acousticSpanish + SpeechCorpus.spanish
        } else {
            pool = SpeechCorpus.acoustic + SpeechCorpus.standard
        }

        print("Synthesizing ~\(minutes) minute(s) of \(language) speech "
            + "from \(pool.count) distinct passages…")
        while samples.count < targetSamples {
            let passages = pool
            for (index, base) in passages.enumerated() {
                // Vary the pause so boundaries are not perfectly periodic.
                let pause = [0.6, 1.4, 2.2, 0.9, 3.1][(round + index) % 5]
                let passage = SpeechPassage(name: base.name, text: base.text, trailingSilence: pause)
                samples += try await SpeechCorpus.render([passage], language: language)
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
        let distinct = Set(spoken.map(\.text)).count
        print(String(format: "  %@  %.1fs  %d passages (%d distinct)  %d reference words",
                     audio.lastPathComponent, seconds, spoken.count, distinct,
                     TextTokenizer.tokens(reference).count))
        if seconds > 300 {
            // The planner targets 240 s and hard-cuts at 300 s, so anything
            // past five minutes exercises chunking and the merge.
            print(String(format: "  long enough to plan ~%.0f chunks, so it "
                               + "exercises the merge seams",
                         (seconds / 240).rounded(.up)))
        }
        print("  \(referenceURL.lastPathComponent) holds the exact spoken text.")
    }
    #endif

    /// Writes a passage for a person to read aloud, plus the exact reference.
    ///
    /// Every accuracy figure in this project comes from synthesized speech,
    /// which is clean, evenly paced, free of accent and free of the small
    /// disfluencies real speaking has. Those figures are honest regression
    /// guards and they are not an estimate of how the app performs for a
    /// person. This is how to get one.
    ///
    /// The passages are deliberately the *same* ones the synthetic corpus
    /// uses. Reading a different text would give a number that could only be
    /// compared with itself; reading this one makes real speech directly
    /// comparable to the 1.3% English and 0.7% Spanish the synthetic corpus
    /// reports on identical words — so the difference between the two figures
    /// is the difference between a synthesizer and a person, which is the
    /// quantity actually wanted.
    static func generateReadingScript(into directory: URL, language: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let spanish = language.hasPrefix("es")
        let passages = spanish
            ? SpeechCorpus.acousticSpanish + SpeechCorpus.spanish
            : SpeechCorpus.acoustic + SpeechCorpus.standard

        let reference = SpeechCorpus.referenceText(for: passages)
        let referenceURL = directory.appending(path: "reading.reference.txt")
        try reference.write(to: referenceURL, atomically: true, encoding: .utf8)

        var script = spanish ? """
        GUION DE LECTURA — Vox Scripta
        ==============================

        Lee las frases siguientes en voz alta, con naturalidad y a tu ritmo
        normal. No hace falta leer perfectamente: si te equivocas, sigue
        adelante sin repetir. La comparación muestra cada diferencia palabra
        por palabra, así que una lectura equivocada se distingue de un error
        de reconocimiento.


        """ : """
        READING SCRIPT — Vox Scripta
        ============================

        Read the sentences below aloud, naturally and at your normal pace.
        It does not need to be perfect: if you misread, carry on rather than
        repeating. The comparison lists every difference word by word, so a
        misreading can be told apart from a mishearing.


        """

        for (index, passage) in passages.enumerated() {
            script += "\(index + 1).  \(passage.text)\n\n"
        }

        let words = TextTokenizer.tokens(reference).count
        script += spanish ? """
        ------------------------------------------------------------------
        \(passages.count) frases, \(words) palabras. Unos dos o tres minutos.

        Cuando termines:
          voxscripta-cli accuracy <tu-grabación> \(referenceURL.lastPathComponent) --locale es-ES
        """ : """
        ------------------------------------------------------------------
        \(passages.count) sentences, \(words) words. Two to three minutes.

        When you are done:
          voxscripta-cli accuracy <your-recording> \(referenceURL.lastPathComponent)
        """

        let scriptURL = directory.appending(path: "reading-script.txt")
        try (script + "\n").write(to: scriptURL, atomically: true, encoding: .utf8)

        print("Reading script for \(language):")
        print("  \(scriptURL.path)")
        print("    \(passages.count) passages, \(words) reference words — read this one aloud")
        print("  \(referenceURL.path)")
        print("    the exact words, for `voxscripta-cli accuracy`")
        print("""

          These are the same passages the synthetic corpus uses, so the result
          is directly comparable to the figures in Docs/ARCHITECTURE.md rather
          than only to itself.
        """)
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
