import Foundation
import VoxScriptaCore

/// One segment of a transcription case: words, the voice that speaks them, and
/// the rules they are scored under.
///
/// A case is a list of these rather than a single block because a mixed-language
/// recording has no single scoring language, and pretending otherwise is how a
/// measurement ends up describing the canonicalizer instead of the engine.
public struct CorpusSegment: Sendable {
    public let passages: [SpeechPassage]
    /// BCP-47 tag selecting the system voice. Also the accent axis: the default
    /// voice for en-GB is not the default voice for en-US.
    public let voiceLanguage: String
    /// The language whose number and token rules grade this segment.
    public let scoringLanguage: TranscriptLanguage
    /// `AVSpeechUtterance.rate`. 0.45 is the corpus baseline.
    public let rate: Float

    public init(passages: [SpeechPassage], voiceLanguage: String,
                scoringLanguage: TranscriptLanguage, rate: Float = 0.45) {
        self.passages = passages
        self.voiceLanguage = voiceLanguage
        self.scoringLanguage = scoringLanguage
        self.rate = rate
    }

    public var referenceText: String { passages.map(\.text).joined(separator: " ") }
    public var referenceWordCount: Int {
        referenceText.split(whereSeparator: \.isWhitespace).count
    }
}

/// One measurable case: known words, spoken under one named acoustic condition.
///
/// Every case carries a `purpose`, so a row that regresses says what it was
/// guarding. A number without that is just a number.
public struct TranscriptionCase: Sendable {
    public let name: String
    public let purpose: String
    public let segments: [CorpusSegment]
    public let condition: SpeechCondition
    public let seed: UInt64

    public init(name: String, purpose: String, segments: [CorpusSegment],
                condition: SpeechCondition = .clean, seed: UInt64 = 0x5EED_C0DE) {
        self.name = name
        self.purpose = purpose
        self.segments = segments
        self.condition = condition
        self.seed = seed
    }

    /// The full reference transcript, in spoken order.
    public var referenceText: String {
        segments.map(\.referenceText).joined(separator: " ")
    }

    public var isMixedLanguage: Bool {
        Set(segments.map(\.scoringLanguage)).count > 1
    }

    /// The language that most of the words belong to.
    ///
    /// A mixed case has to be scored under *something*, and the honest choice is
    /// the majority language plus a note that the minority segment is scored
    /// under foreign rules. The per-segment scores in the report are the ones to
    /// trust; this exists so a whole-file number is still available.
    public var dominantLanguage: TranscriptLanguage {
        var words: [TranscriptLanguage: Int] = [:]
        for segment in segments {
            words[segment.scoringLanguage, default: 0] += segment.referenceWordCount
        }
        return words.max { $0.value < $1.value }?.key ?? .english
    }
}

/// The transcription corpus: the standard passages crossed with the acoustic
/// conditions, plus the cases that only exist as whole recordings.
///
/// Composed in code rather than written out case by case, because the cross
/// product is the point — a condition that is only ever tested against English
/// plain prose has not been tested. Names are derived deterministically so a
/// result table can be diffed between runs.
public enum TranscriptionCorpus {

    // MARK: - Axes

    /// The conditions every language is measured under.
    ///
    /// Chosen to span the failures seen in the field rather than to be
    /// exhaustive: a quiet speaker, three textures of noise, a music bed, the
    /// pause structure that drives chunking, and the two tail shapes that cost
    /// final words.
    public static let conditions: [SpeechCondition] = [
        .clean,
        .quiet(gainDB: -18),
        .noise(snrDB: 12, kind: .hiss),
        .noise(snrDB: 12, kind: .hum),
        .noise(snrDB: 6, kind: .machinery),
        .music(snrDB: 10),
        .longPauses(seconds: 3),
        .abruptEnding,
        .decayingFinalWord(fadeSeconds: 1.2),
    ]

    // MARK: - Base cases

    /// The name-free passages, which is what an acoustic condition is measured
    /// on. Using ``SpeechCorpus/standard`` here was measured and rejected: its
    /// proper nouns fail in every row and swamp the conditions.
    private static func english(rate: Float = 0.45, voice: String = "en-US") -> CorpusSegment {
        CorpusSegment(passages: SpeechCorpus.acoustic, voiceLanguage: voice,
                      scoringLanguage: .english, rate: rate)
    }

    private static func spanish(rate: Float = 0.45, voice: String = "es-ES") -> CorpusSegment {
        CorpusSegment(passages: SpeechCorpus.acousticSpanish, voiceLanguage: voice,
                      scoringLanguage: .spanish, rate: rate)
    }

    /// The name-heavy passages, kept as their own cases rather than mixed into
    /// the conditions. They measure what the polish validator has to protect,
    /// and that is a different question from how well the engine hears.
    public static var entities: [TranscriptionCase] {
        [
            TranscriptionCase(
                name: "en_entities",
                purpose: "Names, numbers, dates and negations in English. A high rate "
                       + "here is expected and is proper-noun error, not hearing error.",
                segments: [CorpusSegment(passages: SpeechCorpus.standard,
                                         voiceLanguage: "en-US", scoringLanguage: .english)]),
            TranscriptionCase(
                name: "es_entities",
                purpose: "The same shapes in Spanish, where the names carry accents "
                       + "and the negation is the double negative Spanish requires.",
                segments: [CorpusSegment(passages: SpeechCorpus.spanish,
                                         voiceLanguage: "es-ES", scoringLanguage: .spanish)]),
        ]
    }

    /// Both languages under every condition. The core of the corpus.
    public static var conditioned: [TranscriptionCase] {
        var cases: [TranscriptionCase] = []
        for condition in conditions {
            cases.append(TranscriptionCase(
                name: "en_\(condition.slug)",
                purpose: "English standard passages under \(condition.name).",
                segments: [english()],
                condition: condition))
            cases.append(TranscriptionCase(
                name: "es_\(condition.slug)",
                purpose: "Spanish standard passages under \(condition.name). "
                       + "Paired with the English case so the two rates compare.",
                segments: [spanish()],
                condition: condition))
        }
        return cases
    }

    /// Speaking rate, which changes the acoustics far more than it looks.
    ///
    /// Fast speech shortens the gaps the chunker needs and slurs word
    /// boundaries; slow speech opens gaps wide enough to look like pauses.
    /// Both are ordinary human behaviour and neither is in the baseline.
    public static var rates: [TranscriptionCase] {
        let labelled: [(String, Float)] = [("slow", 0.35), ("fast", 0.58)]
        return labelled.flatMap { label, rate in
            [
                TranscriptionCase(
                    name: "en_rate_\(label)",
                    purpose: "English at \(label) rate (\(rate)): rate must not move word error rate much.",
                    segments: [english(rate: rate)]),
                TranscriptionCase(
                    name: "es_rate_\(label)",
                    purpose: "Spanish at \(label) rate (\(rate)).",
                    segments: [spanish(rate: rate)]),
            ]
        }
    }

    /// Accent, approximated by the system's regional default voices.
    ///
    /// An approximation and labelled as one: these are synthesized regional
    /// voices, not speakers from those regions, so a good score here does not
    /// prove the engine handles that accent. A *bad* score still proves it
    /// handles something badly, which is worth knowing and costs nothing.
    public static var accents: [TranscriptionCase] {
        let voices: [(String, TranscriptLanguage, [String])] = [
            ("en", .english, ["en-GB", "en-AU", "en-IN"]),
            ("es", .spanish, ["es-MX", "es-AR"]),
        ]
        return voices.flatMap { prefix, language, tags in
            tags.map { tag in
                TranscriptionCase(
                    name: "\(prefix)_voice_\(tag.replacingOccurrences(of: "-", with: "_"))",
                    purpose: "Regional default voice \(tag). An accent proxy, not a speaker sample.",
                    segments: [CorpusSegment(
                        passages: language == .english ? SpeechCorpus.standard : SpeechCorpus.spanish,
                        voiceLanguage: tag, scoringLanguage: language)])
            }
        }
    }

    /// One recording that changes language partway through.
    ///
    /// This is the case the language probe cannot be right about, because there
    /// is no single right answer. It is in the corpus to make the behaviour
    /// *documented* rather than discovered: whatever the probe does here is
    /// recorded, and a change to it shows up as a change.
    public static var mixedLanguage: [TranscriptionCase] {
        [
            TranscriptionCase(
                name: "mixed_en_then_es",
                purpose: "English then Spanish in one recording. No single correct "
                       + "detection exists; this records what the probe does.",
                segments: [english(), spanish()]),
            TranscriptionCase(
                name: "mixed_es_then_en",
                purpose: "The same boundary in the other direction, because order "
                       + "matters to a probe that samples the middle of the speech.",
                segments: [spanish(), english()]),
            TranscriptionCase(
                name: "mixed_es_dominant",
                purpose: "Mostly Spanish with one English passage. The probe should "
                       + "report Spanish; an English answer here is the field bug.",
                segments: [
                    spanish(),
                    CorpusSegment(passages: [SpeechCorpus.standard[4]],
                                  voiceLanguage: "en-US", scoringLanguage: .english),
                    spanish(),
                ]),
        ]
    }

    /// Recordings long enough that chunking, merging and resumption all engage.
    ///
    /// The short cases never cross a chunk boundary, so they cannot measure the
    /// merge — which is why merge quality has been unmeasured. These exist to
    /// put speech *across* the seam on purpose.
    public static var long: [TranscriptionCase] {
        // The standard set repeated until it runs several minutes. Repetition is
        // acceptable here because what is under test is the seam, not the
        // vocabulary — and it keeps the reference exact.
        let repeated = Array(repeating: SpeechCorpus.standard, count: 6).flatMap { $0 }
        // The same, with the trailing silence stripped so the planner finds no
        // comfortable cut and has to take a hard one mid-speech.
        let gapless = repeated.map {
            SpeechPassage(name: $0.name, text: $0.text, trailingSilence: 0)
        }
        let spanishGapless = Array(repeating: SpeechCorpus.spanish, count: 6)
            .flatMap { $0 }
            .map { SpeechPassage(name: $0.name, text: $0.text, trailingSilence: 0) }
        return [
            TranscriptionCase(
                name: "en_long_with_pauses",
                purpose: "Several minutes with real pauses: the planner should cut at "
                       + "silence and the merge should be invisible.",
                segments: [CorpusSegment(passages: repeated, voiceLanguage: "en-US",
                                         scoringLanguage: .english)]),
            TranscriptionCase(
                name: "en_long_gapless",
                purpose: "Several minutes with no usable pause, forcing a hard cut "
                       + "through speech. This is where merge errors live.",
                segments: [CorpusSegment(passages: gapless, voiceLanguage: "en-US",
                                         scoringLanguage: .english)]),
            TranscriptionCase(
                name: "es_long_gapless",
                purpose: "The hard-cut case in Spanish, because the merge heuristics "
                       + "were only ever checked against English.",
                segments: [CorpusSegment(passages: spanishGapless,
                                         voiceLanguage: "es-ES",
                                         scoringLanguage: .spanish)]),
        ]
    }

    /// Disfluent speech, scored as spoken.
    ///
    /// The reference includes the fillers, because the engine's job is to
    /// transcribe what was said. Removing them is CLEAN's job and is measured
    /// separately; conflating the two hides which stage lost the word.
    public static var disfluent: [TranscriptionCase] {
        [TranscriptionCase(
            name: "en_disfluent",
            purpose: "Fillers and stutters, scored as spoken. The engine should keep "
                   + "them; CLEAN removes them later and is measured on its own.",
            segments: [CorpusSegment(passages: SpeechCorpus.disfluent,
                                     voiceLanguage: "en-US", scoringLanguage: .english)])]
    }

    // MARK: - Selections

    /// Everything. Long enough to be an overnight run, not a pre-commit check.
    public static var all: [TranscriptionCase] {
        conditioned + rates + accents + mixedLanguage + long + disfluent + entities
    }

    /// A short selection for routine use: both languages clean, the two noise
    /// textures that differ most, and the tail case that cost us a real word.
    public static var smoke: [TranscriptionCase] {
        let wanted = ["en_clean", "es_clean", "en_hiss_12dB",
                      "es_machinery_6dB", "en_decay_12"]
        return conditioned.filter { wanted.contains($0.name) }
    }

    public static func named(_ name: String) -> TranscriptionCase? {
        all.first { $0.name == name }
    }
}
