import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaLanguage
import VoxScriptaProject
import VoxScriptaTestSupport
@testable import VoxScriptaPipeline

/// CLEAN against genuine engine output.
///
/// The disfluencies here are *spoken* and transcribed by the real model, not
/// inserted into a hand-built transcript. That difference matters: real output
/// carries punctuation attached to filler tokens, which is where the pass's
/// first defect lived.
/// One pipeline run, shared by every test in the suite.
///
/// Synthesizing speech and running the model costs about half a minute. The
/// tests all interrogate the same output, so running it once and asking several
/// questions of it is both faster and a more honest description of what is being
/// checked.
actor CleanRunCache {
    static let shared = CleanRunCache()

    struct Output: Sendable {
        let verbatim: Transcript
        let clean: Transcript
        let edits: [CleanEdit]
    }

    private var cached: Output?
    private var scratch: URL?

    func output() async throws -> Output {
        if let cached { return cached }

        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "voxscripta-clean-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratch = root

        let samples = try await SpeechCorpus.render(SpeechCorpus.disfluent)
        let audio = root.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: samples, to: audio, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        var chunking = ChunkParameters.default
        chunking.minDuration = .seconds(12)
        chunking.targetDuration = .seconds(20)
        chunking.maxDuration = .seconds(30)

        let decoder = CanonicalDecoder()
        let project = try await ProjectStore().create(
            from: audio, at: root.appending(path: "p.voxscripta"), chunking: chunking,
            probe: { (try await decoder.probe(url: $0), try decoder.duration(of: $0)) })

        var options = JobOptions()
        options.transcription.concurrency = 1
        _ = try await JobRunner().run(project: project, options: options)

        let output = Output(
            verbatim: try JobRunner.transcript(.verbatim, from: project.package),
            clean: try JobRunner.transcript(.clean, from: project.package),
            edits: try AtomicFile.readJSON([CleanEdit].self, from: project.package.cleanEditsURL))
        cached = output
        return output
    }
}

@Suite("CLEAN end to end", .serialized)
struct CleanEndToEndTests {

    @Test("Fillers are removed while meaning-bearing words survive")
    func removesFillersKeepsMeaning() async throws {
        let output = try await CleanRunCache.shared.output()
        let (verbatim, clean, edits) = (output.verbatim, output.clean, output.edits)

        let before = TextTokenizer.tokens(verbatim.plainText())
        let after = TextTokenizer.tokens(clean.plainText())
        #expect(!before.isEmpty)

        // Fillers the engine actually produced are gone.
        let fillersAfter = after.filter { DisfluencyLexicon.isFiller($0, in: .english) }
        #expect(fillersAfter.isEmpty, "fillers survived CLEAN: \(fillersAfter)")
        #expect(after.count < before.count, "CLEAN removed nothing from disfluent speech")

        // The things that carry meaning are all still there.
        let text = clean.plainText().lowercased()
        #expect(text.contains("not"), "a negation was lost")
        #expect(text.contains("monday"))
        #expect(text.contains("budget"))
        #expect(clean.plainText().contains("500"))

        // Every deletion is logged.
        let deletions = edits.count { $0.kind == .disfluencyRemoved || $0.kind == .repetitionCollapsed }
        #expect(deletions > 0)
    }

    @Test("The invariant holds on real engine output")
    func subsequenceInvariantEndToEnd() async throws {
        let output = try await CleanRunCache.shared.output()
        let (verbatim, clean) = (output.verbatim, output.clean)

        let before = TextTokenizer.tokens(verbatim.plainText())
        let after = TextTokenizer.tokens(clean.plainText())

        var index = 0
        for token in before where index < after.count && after[index] == token {
            index += 1
        }
        #expect(index == after.count,
                "CLEAN produced a token not present in the verbatim transcript, in order")
    }

    @Test("CLEAN leaves no stranded delimiters")
    func noStrandedPunctuation() async throws {
        let clean = try await CleanRunCache.shared.output().clean
        let text = clean.plainText()

        // The defect this suite was written to catch: deleting a comma-delimited
        // filler and leaving its comma behind.
        #expect(!text.contains(", ,"))
        #expect(!text.contains(",."))
        #expect(!text.contains(" ,"))
        for sentence in text.split(separator: ".") {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!trimmed.hasPrefix(","), "a sentence began with a stranded comma: \(trimmed)")
        }
    }

    @Test("Word timings survive so subtitle export stays aligned")
    func timingsSurvive() async throws {
        let clean = try await CleanRunCache.shared.output().clean
        #expect(clean.isMonotonic)

        let words = clean.segments.flatMap(\.words)
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.originalStart <= $0.originalEnd })
        let starts = words.map(\.originalStart)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
