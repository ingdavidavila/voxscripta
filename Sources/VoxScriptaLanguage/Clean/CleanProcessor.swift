import Foundation
import VoxScriptaCore

/// Tunable behaviour for the CLEAN pass (§12).
public struct CleanParameters: Hashable, Sendable, Codable {
    /// Delete non-lexical fillers drawn from the closed lexicon.
    public var removeFillers: Bool
    /// Collapse immediate stutter repetitions.
    public var collapseRepetitions: Bool
    /// Repair doubled and stranded punctuation.
    public var repairPunctuation: Bool
    /// Capitalize the first letter of each sentence.
    public var normalizeCapitalization: Bool
    /// Add a full stop before a long pause when one is missing.
    public var terminateSentences: Bool
    /// Which language's lexicons CLEAN applies.
    ///
    /// Part of the parameters, and therefore part of the content hash, so
    /// changing it re-runs CLEAN rather than leaving a transcript cleaned by
    /// another language's rules.
    public var language: TranscriptLanguage

    /// Longest gap between two identical words still treated as a stutter.
    ///
    /// A speaker who repeats a word deliberately leaves a longer gap than a
    /// speaker who stumbles over it. This is the signal that separates "I—I think"
    /// from "no, no, that is different".
    public var maximumStutterGap: MediaTime

    public init(
        removeFillers: Bool = true,
        collapseRepetitions: Bool = true,
        repairPunctuation: Bool = true,
        normalizeCapitalization: Bool = true,
        terminateSentences: Bool = true,
        language: TranscriptLanguage = .english,
        maximumStutterGap: MediaTime = .milliseconds(300)
    ) {
        self.removeFillers = removeFillers
        self.collapseRepetitions = collapseRepetitions
        self.repairPunctuation = repairPunctuation
        self.normalizeCapitalization = normalizeCapitalization
        self.terminateSentences = terminateSentences
        self.language = language
        self.maximumStutterGap = maximumStutterGap
    }

    /// Decoded leniently so a project written before `language` existed still
    /// opens. The synthesized decoder would fail on the missing key and make
    /// every earlier project unreadable — a mistake this codebase has already
    /// made once, with the manifest.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? true
        collapseRepetitions = try c.decodeIfPresent(Bool.self, forKey: .collapseRepetitions) ?? true
        repairPunctuation = try c.decodeIfPresent(Bool.self, forKey: .repairPunctuation) ?? true
        normalizeCapitalization =
            try c.decodeIfPresent(Bool.self, forKey: .normalizeCapitalization) ?? true
        terminateSentences = try c.decodeIfPresent(Bool.self, forKey: .terminateSentences) ?? true
        language = try c.decodeIfPresent(TranscriptLanguage.self, forKey: .language) ?? .english
        maximumStutterGap =
            try c.decodeIfPresent(MediaTime.self, forKey: .maximumStutterGap) ?? .milliseconds(300)
    }

    public static let `default` = CleanParameters()

    /// Punctuation and capitalization only; no words are ever deleted.
    public static let conservative = CleanParameters(
        removeFillers: false, collapseRepetitions: false)
}

public protocol CleanProcessing: Sendable {
    func process(
        verbatim: Transcript,
        parameters: CleanParameters,
        silenceParameters: SilenceParameters
    ) throws -> CleanResult
}

/// Produces the CLEAN variant with no language model involved.
///
/// Modern on-device ASR already emits punctuated, capitalized text, so everything
/// §12 asks for is reachable with deterministic rules over the structured
/// transcript plus measured pause data. That makes CLEAN's hallucination risk
/// exactly zero, which matters because it is the variant most people will read.
///
/// Two invariants hold by construction, and are asserted by the test suite:
///
/// 1. **No word is ever added.** Every token in the output appears in the input.
/// 2. **No word is ever reordered.** Output tokens are a subsequence of input
///    tokens.
///
/// Together these mean CLEAN can only delete from a closed lexicon and adjust
/// punctuation, capitalization and spacing. It cannot rewrite a sentence, because
/// there is no code path that produces a word the speaker did not say.
public struct CleanProcessor: CleanProcessing {
    public init() {}

    public func process(
        verbatim: Transcript,
        parameters: CleanParameters = .default,
        silenceParameters: SilenceParameters = .default
    ) throws -> CleanResult {
        var segments: [TranscriptSegment] = []
        var edits: [CleanEdit] = []

        for (index, original) in verbatim.segments.enumerated() {
            // A gap marker has no content to clean and must survive intact, so
            // the reader still sees where transcription failed.
            if original.warnings.contains(.transcriptionGap) {
                segments.append(original)
                continue
            }

            var segment = original
            if !segment.words.isEmpty {
                let filtered = filterWords(segment.words, parameters: parameters,
                                           segmentID: segment.id, edits: &edits)
                guard !filtered.isEmpty else { continue }
                segment.words = filtered
                segment.originalStart = filtered.first!.originalStart
                segment.originalEnd = filtered.last!.originalEnd
                segment.text = Self.join(filtered.map(\.text))
            }

            if parameters.repairPunctuation {
                let repaired = Self.repairPunctuation(segment.text)
                if repaired != segment.text {
                    edits.append(CleanEdit(segmentID: segment.id, kind: .punctuationRepaired,
                                           original: segment.text, replacement: repaired,
                                           at: segment.originalStart))
                    segment.text = repaired
                }
            }

            // A full stop is added only before a real pause, never mid-thought.
            let nextStartsParagraph = index + 1 < verbatim.segments.count
                && (verbatim.segments[index + 1].precedingGap ?? .zero)
                    >= silenceParameters.paragraphPauseThreshold
            let isLast = index == verbatim.segments.count - 1

            if parameters.terminateSentences, nextStartsParagraph || isLast,
               let terminated = Self.terminate(segment.text) {
                edits.append(CleanEdit(segmentID: segment.id, kind: .sentenceTerminated,
                                       original: segment.text, replacement: terminated,
                                       at: segment.originalEnd))
                segment.text = terminated
            }

            if parameters.normalizeCapitalization {
                let previousTerminated = segments.last.map { Self.endsSentence($0.text) } ?? true
                let capitalized = Self.capitalize(segment.text, startsSentence: previousTerminated)
                if capitalized != segment.text {
                    edits.append(CleanEdit(segmentID: segment.id, kind: .capitalized,
                                           original: segment.text, replacement: capitalized,
                                           at: segment.originalStart))
                    segment.text = capitalized
                }
            }

            segments.append(segment)
        }

        let transcript = Transcript(
            variant: .clean, segments: segments,
            provenance: Provenance(
                engineID: verbatim.provenance.engineID,
                silenceParameterHash: verbatim.provenance.silenceParameterHash,
                chunkParameterHash: verbatim.provenance.chunkParameterHash,
                concurrency: verbatim.provenance.concurrency))

        return CleanResult(transcript: transcript, edits: edits)
    }

    // MARK: - Word filtering

    private func filterWords(
        _ words: [Word],
        parameters: CleanParameters,
        segmentID: SegmentID,
        edits: inout [CleanEdit]
    ) -> [Word] {
        var out: [Word] = []
        out.reserveCapacity(words.count)

        for (index, word) in words.enumerated() {
            let following = index + 1 < words.count ? words[index + 1].text : nil
            if parameters.removeFillers,
               DisfluencyLexicon.isFiller(word.text, in: parameters.language,
                                          following: following) {
                edits.append(CleanEdit(segmentID: segmentID, kind: .disfluencyRemoved,
                                       original: word.text, replacement: "",
                                       at: word.originalStart))
                // A parenthetical filler is delimited by commas on both sides:
                // "we should, um, start". Deleting only the word leaves the
                // opening comma stranded and reads as a comma splice, so the
                // now-redundant delimiter goes with it.
                if Self.endsWithComma(word.text), let previous = out.last,
                   Self.endsWithComma(previous.text) {
                    out[out.count - 1] = Word(
                        text: Self.strippingTrailingComma(previous.text),
                        originalStart: previous.originalStart,
                        originalEnd: previous.originalEnd,
                        confidence: previous.confidence)
                }
                continue
            }

            if parameters.collapseRepetitions, let previous = out.last,
               Self.isStutter(previous, word, within: parameters.maximumStutterGap,
                              language: parameters.language) {
                edits.append(CleanEdit(segmentID: segmentID, kind: .repetitionCollapsed,
                                       original: "\(previous.text) \(word.text)",
                                       replacement: word.text, at: word.originalStart))
                // Keep the *later* token's text and the earlier one's start time.
                //
                // In "I, I wanted" the first occurrence is the stumble, carrying
                // the comma that marks the break; the second is the word the
                // speaker actually completed. Keeping the first would leave
                // "I, wanted". The earlier start time is retained so the surviving
                // word still covers the audio a reader would hear.
                out[out.count - 1] = Word(
                    text: word.text, originalStart: previous.originalStart,
                    originalEnd: word.originalEnd, confidence: word.confidence)
                continue
            }

            out.append(word)
        }
        return out
    }

    /// Whether `second` is a stumble over `first` rather than a deliberate repeat.
    static func isStutter(_ first: Word, _ second: Word, within maximumGap: MediaTime,
                          language: TranscriptLanguage) -> Bool {
        let a = DisfluencyLexicon.normalize(first.text)
        let b = DisfluencyLexicon.normalize(second.text)
        guard !a.isEmpty, a == b,
              DisfluencyLexicon.mayCollapseRepetition(of: a, in: language) else { return false }

        let gap = second.originalStart - first.originalEnd
        // Timings can be absent or degenerate; fall back to the token rule alone
        // rather than silently declining to collapse an obvious stutter.
        guard first.originalEnd > .zero || second.originalStart > .zero else { return true }
        return gap <= maximumGap
    }

    /// Whether a token ends with a comma, ignoring trailing quotes.
    static func endsWithComma(_ token: String) -> Bool {
        token.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]")).hasSuffix(",")
    }

    /// Removes one trailing comma, keeping any quotes that followed it.
    static func strippingTrailingComma(_ token: String) -> String {
        guard let index = token.lastIndex(of: ",") else { return token }
        var out = token
        out.remove(at: index)
        return out
    }

    // MARK: - Text shaping

    /// Joins tokens, keeping punctuation tight against the preceding word.
    static func join(_ tokens: [String]) -> String {
        var out = ""
        for token in tokens {
            guard !token.isEmpty else { continue }
            if out.isEmpty {
                out = token
                continue
            }
            let first = token.first!
            let attaches = ",.!?;:)]}…".contains(first) || token.hasPrefix("'")
            let previousOpens = "([{".contains(out.last!)
            out += (attaches || previousOpens) ? token : " " + token
        }
        return out
    }

    /// Collapses redundant whitespace and doubled punctuation.
    ///
    /// Only marks that are meaningless when doubled are collapsed. "?!" is a real
    /// construction and survives; ".." and ",," are artifacts and do not.
    static func repairPunctuation(_ text: String) -> String {
        var out = ""
        var previous: Character?
        var pendingSpace = false

        for character in text {
            if character.isWhitespace {
                if !out.isEmpty { pendingSpace = true }
                continue
            }
            // Never leave a space before closing punctuation.
            if pendingSpace, !",.!?;:)]}…".contains(character) {
                out.append(" ")
            }
            pendingSpace = false

            if let previous, previous == character, ".,;:".contains(character) {
                continue   // ".." -> ".", ",," -> ","
            }
            out.append(character)
            previous = character
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Appends a full stop when the text ends without terminal punctuation.
    static func terminate(_ text: String) -> String? {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return nil }
        guard !".!?…".contains(last) else { return nil }
        // A trailing comma before a long pause is an artifact; replace it.
        if ",;:".contains(last) {
            return String(text.dropLast()) + "."
        }
        return text + "."
    }

    /// Whether the text ends a sentence, so the next one should be capitalized.
    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return true }
        return ".!?…".contains(last)
    }

    /// Capitalizes sentence-initial letters, and never lowercases anything.
    ///
    /// Lowercasing risks destroying a proper noun the engine got right, which
    /// would be a meaning-affecting edit. Capitalization can only add information
    /// about sentence boundaries.
    static func capitalize(_ text: String, startsSentence: Bool) -> String {
        var out = ""
        var expectingCapital = startsSentence
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if expectingCapital, character.isLetter {
                out.append(contentsOf: String(character).uppercased())
                expectingCapital = false
            } else {
                out.append(character)
                if ".!?…".contains(character) { expectingCapital = true }
                else if !character.isWhitespace && !"\"')]".contains(character) {
                    expectingCapital = false
                }
            }
            index = text.index(after: index)
        }
        return out
    }
}
