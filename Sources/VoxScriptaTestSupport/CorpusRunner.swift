import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaBench

/// One row of the corpus report: a case, a configuration, and what it scored.
///
/// Every field a row is grouped by is stored on the row rather than implied by
/// where it was printed, so a report read a month later is still legible and a
/// run can be diffed against another engine's.
public struct CorpusMeasurement: Sendable, Codable {
    public let caseName: String
    /// The path the audio went through, when a case is measured more than one
    /// way — "whole" against "chunked", for instance.
    public let path: String
    public let conditionSlug: String
    public let engineID: String
    /// Whatever the engine reports as `modelIdentity`, so a row cannot be
    /// mistaken for one produced by a different model.
    public let modelIdentity: String
    public let scoringLanguage: String
    public let mixedLanguage: Bool
    public let wer: WERResult
    public let cer: CERResult
    public let audioSeconds: Double
    public let wallSeconds: Double
    public let reference: String
    public let hypothesis: String

    public var realTimeFactor: Double {
        audioSeconds > 0 ? wallSeconds / audioSeconds : 0
    }

    /// Reference words that do not appear anywhere in the transcript.
    ///
    /// A bag-of-words approximation and labelled as one: it ignores order, so a
    /// transposition reads as correct and a word repeated once but spoken twice
    /// reads as present. What it is good for is the question a flat results
    /// table raises — *which* words are being lost — and for that it needs no
    /// alignment, which the error metrics do not expose.
    public func missedWords(in language: TranscriptLanguage) -> [String] {
        let referenceTokens = TextTokenizer.comparableTokens(reference, in: language)
        let heard = Set(TextTokenizer.comparableTokens(hypothesis, in: language))
        var seen = Set<String>()
        return referenceTokens.filter { !heard.contains($0) && seen.insert($0).inserted }
    }

    public init(caseName: String, path: String, conditionSlug: String,
                engineID: String, modelIdentity: String,
                scoringLanguage: String, mixedLanguage: Bool,
                wer: WERResult, cer: CERResult,
                audioSeconds: Double, wallSeconds: Double,
                reference: String, hypothesis: String) {
        self.caseName = caseName
        self.path = path
        self.conditionSlug = conditionSlug
        self.engineID = engineID
        self.modelIdentity = modelIdentity
        self.scoringLanguage = scoringLanguage
        self.mixedLanguage = mixedLanguage
        self.wer = wer
        self.cer = cer
        self.audioSeconds = audioSeconds
        self.wallSeconds = wallSeconds
        self.reference = reference
        self.hypothesis = hypothesis
    }
}

/// A set of rows, with the formatting a human needs to read them.
public struct CorpusReport: Sendable, Codable {
    public let rows: [CorpusMeasurement]
    public let recordedAt: Date
    public let hardware: String

    public init(rows: [CorpusMeasurement], recordedAt: Date = Date(),
                hardware: String = CorpusReport.describeHardware()) {
        self.rows = rows
        self.recordedAt = recordedAt
        self.hardware = hardware
    }

    public static func describeHardware() -> String {
        let info = ProcessInfo.processInfo
        return "\(info.activeProcessorCount) cores, "
             + "\(info.physicalMemory / 1_073_741_824) GB, "
             + "\(info.operatingSystemVersionString)"
    }

    /// A fixed-width table, because the point of the corpus is comparison and
    /// comparison needs columns that line up.
    public var table: String {
        guard !rows.isEmpty else { return "no measurements" }
        var out = ""
        out += "case                      cond          lang  WER     CER     S/D/I        RTF\n"
        out += "────────────────────────────────────────────────────────────────────────────────\n"
        for row in rows.sorted(by: { ($0.caseName, $0.path) < ($1.caseName, $1.path) }) {
            let name = row.path == "whole"
                ? row.caseName
                : "\(row.caseName)·\(row.path)"
            out += name.padded(25)
            out += row.conditionSlug.padded(14)
            out += (row.mixedLanguage ? "mix" : row.scoringLanguage.prefix(3).description).padded(6)
            out += String(format: "%6.1f%%  ", row.wer.rate * 100)
            out += String(format: "%6.1f%%  ", row.cer.rate * 100)
            out += "\(row.wer.substitutions)/\(row.wer.deletions)/\(row.wer.insertions)".padded(13)
            out += String(format: "%5.2f", row.realTimeFactor)
            out += "\n"
        }
        return out
    }

    /// The mean word error rate, weighted by reference length.
    ///
    /// Weighted rather than a mean of rates: an unweighted average lets a
    /// four-word case move the headline figure as much as a six-minute one.
    public var aggregateWER: Double {
        let words = rows.reduce(0) { $0 + $1.wer.referenceWords }
        guard words > 0 else { return 0 }
        let errors = rows.reduce(0) {
            $0 + $1.wer.substitutions + $1.wer.deletions + $1.wer.insertions
        }
        return Double(errors) / Double(words)
    }

    /// Rows grouped the way the brief asks the results to be read: separately
    /// by condition, so a condition that only hurts one language is visible.
    public func byCondition() -> [String: [CorpusMeasurement]] {
        Dictionary(grouping: rows, by: \.conditionSlug)
    }

    public func byLanguage() -> [String: [CorpusMeasurement]] {
        Dictionary(grouping: rows, by: \.scoringLanguage)
    }

    /// The cost of chunking, for cases measured both ways.
    ///
    /// This is the merge-quality number that has been missing. A case
    /// transcribed whole and then transcribed in chunks should score the same;
    /// the difference is what the seam cost, and attributing it needs nothing
    /// more than running the same audio twice.
    public func mergeDeltas() -> [(caseName: String, whole: Double, chunked: Double, delta: Double)] {
        let byCase = Dictionary(grouping: rows, by: \.caseName)
        return byCase.compactMap { name, rows in
            guard let whole = rows.first(where: { $0.path == "whole" }),
                  let chunked = rows.first(where: { $0.path == "chunked" }) else { return nil }
            return (name, whole.wer.rate, chunked.wer.rate,
                    chunked.wer.rate - whole.wer.rate)
        }.sorted { $0.delta > $1.delta }
    }

    /// The reference words lost most often across the whole run, with how many
    /// rows lost each.
    ///
    /// This is the question a flat table forces. If every condition scores the
    /// same, either nothing is being measured or the metric is saturated by a
    /// constant set of words — and the two have completely different remedies,
    /// so guessing between them is not acceptable.
    public func persistentlyMissedWords() -> [(word: String, rows: Int)] {
        var counts: [String: Int] = [:]
        for row in rows {
            let language = TranscriptLanguage(rawValue: row.scoringLanguage) ?? .english
            for word in row.missedWords(in: language) {
                counts[word, default: 0] += 1
            }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { (word: $0.key, rows: $0.value) }
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? String(prefix(width - 1)) + " "
                       : self + String(repeating: " ", count: width - count)
    }
}

/// Renders corpus cases and scores what an engine makes of them.
///
/// The engine is supplied as a closure rather than a type. That keeps this
/// portable — the scoring half compiles anywhere, and only rendering needs a
/// speech synthesizer — and it means the same harness measures Whisper, Apple,
/// a chunked pipeline or a mock without knowing which it has.
public struct CorpusRunner: Sendable {

    /// Transcribes decoded canonical samples and returns the transcript.
    ///
    /// Takes the canonical file and sample count rather than the original audio
    /// because that is the boundary every engine shares, and because §5 says the
    /// original is never touched — the runner decodes to a separate file and the
    /// engine never sees the source.
    public typealias Transcribe = @Sendable (
        _ canonical: URL, _ sampleCount: Int64, _ locale: String
    ) async throws -> String

    public let engineID: String
    public let modelIdentity: String

    public init(engineID: String, modelIdentity: String = "") {
        self.engineID = engineID
        self.modelIdentity = modelIdentity
    }

    /// A rendered case on disk, ready to measure.
    public struct Rendered: Sendable {
        public let wav: URL
        public let canonical: URL
        public let sampleCount: Int64
        public let seconds: Double
    }

    /// Scores a transcript against a case. Portable: no audio involved.
    public func score(_ transcriptionCase: TranscriptionCase,
                      hypothesis: String,
                      path: String = "whole",
                      audioSeconds: Double,
                      wallSeconds: Double) -> CorpusMeasurement {
        let reference = transcriptionCase.referenceText
        let language = transcriptionCase.dominantLanguage
        return CorpusMeasurement(
            caseName: transcriptionCase.name,
            path: path,
            conditionSlug: transcriptionCase.condition.slug,
            engineID: engineID,
            modelIdentity: modelIdentity,
            scoringLanguage: language.rawValue,
            // Recorded on the row because a mixed case's figure is scored under
            // one language and therefore charges the other segment under
            // foreign number rules. The row says so rather than leaving a
            // reader to assume the number means what the others mean.
            mixedLanguage: transcriptionCase.isMixedLanguage,
            wer: WordErrorRate.measure(reference: reference, hypothesis: hypothesis,
                                       language: language),
            cer: CharacterErrorRate.measure(reference: reference, hypothesis: hypothesis,
                                            language: language),
            audioSeconds: audioSeconds,
            wallSeconds: wallSeconds,
            reference: reference,
            hypothesis: hypothesis)
    }
}

// Rendering needs a speech synthesizer, so it exists only where AVFoundation
// does. Everything above stays available everywhere, which is deliberate: a
// Linux run can score a transcript produced elsewhere even though it cannot
// speak the corpus itself.
#if canImport(AVFoundation)
extension CorpusRunner {

    /// Renders a case to a WAV file and decodes it to canonical samples.
    ///
    /// The condition is applied to the rendered speech, not to the file on
    /// disk, so the audio that reaches the engine has been through a real
    /// encode and decode — the same path a user's recording takes. Measuring
    /// against an in-memory float array would skip the two stages most likely
    /// to lose the end of a word.
    public func render(_ transcriptionCase: TranscriptionCase,
                       into directory: URL) async throws -> Rendered {
        var samples: [Float] = []
        for segment in transcriptionCase.segments {
            samples += try await SpeechCorpus.render(
                segment.passages, rate: segment.rate, language: segment.voiceLanguage)
        }
        guard !samples.isEmpty else {
            throw VoxScriptaError.decodingFailed(
                reason: "\(transcriptionCase.name) rendered to no audio; "
                      + "a voice for its language is probably not installed")
        }

        let conditioned = SpeechConditioning.apply(
            transcriptionCase.condition, to: samples, seed: transcriptionCase.seed)

        let wav = directory.appending(path: "\(transcriptionCase.name).wav")
        try WAVFileWriter.write(samples: conditioned, to: wav,
                                sampleRate: CanonicalFormat.sampleRate)

        let canonical = directory.appending(path: "\(transcriptionCase.name).f32")
        let written = try await CanonicalDecoder().decode(url: wav, to: canonical) { _ in }

        return Rendered(wav: wav, canonical: canonical, sampleCount: written,
                        seconds: Double(written) / Double(CanonicalFormat.sampleRate))
    }

    /// Renders, transcribes and scores one case.
    public func measure(_ transcriptionCase: TranscriptionCase,
                        in directory: URL,
                        path: String = "whole",
                        locale: String? = nil,
                        transcribe: Transcribe) async throws -> CorpusMeasurement {
        let rendered = try await render(transcriptionCase, into: directory)
        // The locale handed to the engine defaults to the case's own dominant
        // segment rather than to English. Defaulting to English here is exactly
        // the bug that made the first Spanish measurement meaningless.
        let resolved = locale ?? transcriptionCase.segments.first?.voiceLanguage ?? "en-US"

        let started = Date()
        let hypothesis = try await transcribe(rendered.canonical, rendered.sampleCount, resolved)
        let elapsed = Date().timeIntervalSince(started)

        return score(transcriptionCase, hypothesis: hypothesis, path: path,
                     audioSeconds: rendered.seconds, wallSeconds: elapsed)
    }

    /// Runs a set of cases, keeping going when one cannot be rendered.
    ///
    /// A missing regional voice is the common failure and it is not a result:
    /// skipping that row and saying so is honest, whereas scoring Spanish text
    /// read by an English voice produces a number that looks real and measures
    /// the renderer.
    public func run(_ cases: [TranscriptionCase],
                    in directory: URL,
                    locale: String? = nil,
                    onSkip: (@Sendable (String, String) -> Void)? = nil,
                    transcribe: Transcribe) async -> CorpusReport {
        var rows: [CorpusMeasurement] = []
        for transcriptionCase in cases {
            do {
                rows.append(try await measure(transcriptionCase, in: directory,
                                              locale: locale, transcribe: transcribe))
            } catch {
                onSkip?(transcriptionCase.name, String(describing: error))
            }
        }
        return CorpusReport(rows: rows)
    }

    /// Whether every voice a set of cases needs is installed.
    ///
    /// Reported rather than assumed, so a run states what it could not cover
    /// instead of quietly covering less than it claims.
    public static func missingVoices(for cases: [TranscriptionCase]) -> [String] {
        let wanted = Set(cases.flatMap { $0.segments.map(\.voiceLanguage) })
        return wanted.filter { AVSpeechSynthesisVoice(language: $0) == nil }.sorted()
    }
}
#endif
