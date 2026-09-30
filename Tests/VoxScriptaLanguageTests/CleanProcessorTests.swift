import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// Builds a verbatim transcript from words with explicit timings.
func verbatimTranscript(_ specs: [(String, Double, Double)], gap: Double? = nil) -> Transcript {
    let words = specs.map {
        Word(text: $0.0, originalStart: .seconds($0.1), originalEnd: .seconds($0.2), confidence: 0.9)
    }
    let segment = TranscriptSegment(
        originalStart: words.first?.originalStart ?? .zero,
        originalEnd: words.last?.originalEnd ?? .zero,
        text: words.map(\.text).joined(separator: " "),
        words: words,
        precedingGap: gap.map { MediaTime.seconds($0) })
    return Transcript(variant: .verbatim, segments: [segment], provenance: Provenance())
}

/// Evenly spaced words, for cases where timing is not the point.
func evenlySpaced(_ tokens: [String], step: Double = 0.4) -> Transcript {
    verbatimTranscript(tokens.enumerated().map { i, t in
        (t, Double(i) * step, Double(i) * step + step * 0.7)
    })
}

@Suite("CLEAN — the invariant")
struct CleanInvariantTests {

    /// Comparable word tokens, ignoring case and punctuation.
    private func tokens(_ transcript: Transcript) -> [String] {
        transcript.segments.flatMap { TextTokenizer.tokens($0.text) }
    }

    /// Whether `small` appears within `large` in order, possibly with gaps.
    private func isSubsequence(_ small: [String], of large: [String]) -> Bool {
        var index = 0
        for token in large where index < small.count && small[index] == token {
            index += 1
        }
        return index == small.count
    }

    @Test("CLEAN never adds a word and never reorders one")
    func subsequenceInvariant() throws {
        // The property that makes CLEAN's zero-hallucination claim checkable
        // rather than merely asserted. If output words are always a subsequence
        // of input words, the pass cannot have invented or rearranged anything —
        // it can only have deleted from its closed lexicon.
        let corpora: [[String]] = [
            ["uh", "so", "basically", "what", "I", "wanted", "to", "say", "was", "that",
             "we", "should", "probably", "start", "on", "Monday"],
            ["I", "I", "think", "um", "we", "we", "should", "go"],
            ["We", "sold", "500", "units", "in", "the", "3rd", "quarter"],
            ["The", "the", "committee", "did", "not", "approve", "it", "uh", "yet"],
            ["mm", "hmm", "yes", "that", "is", "right"],
            ["David", "met", "with", "Sarah", "Chen", "on", "Tuesday"],
            ["no", "no", "that", "is", "different"],
            ["I", "had", "had", "enough", "of", "that", "that", "day"],
        ]

        for corpus in corpora {
            let verbatim = evenlySpaced(corpus)
            let result = try CleanProcessor().process(
                verbatim: verbatim, parameters: .default, silenceParameters: .default)

            let input = tokens(verbatim)
            let output = tokens(result.transcript)
            #expect(isSubsequence(output, of: input),
                    "CLEAN produced tokens not present in order: \(output) from \(input)")
        }
    }

    @Test("Every deleted word is accounted for in the edit log")
    func editLogIsComplete() throws {
        let verbatim = evenlySpaced(["uh", "I", "I", "think", "um", "so"])
        let result = try CleanProcessor().process(
            verbatim: verbatim, parameters: .default, silenceParameters: .default)

        let before = verbatim.segments.flatMap(\.words).count
        let after = result.transcript.segments.flatMap(\.words).count
        // The log must explain the difference exactly — no silent deletions.
        #expect(before - after == result.wordsRemoved)
        #expect(result.wordsRemoved > 0)
    }

    @Test("CLEAN is deterministic")
    func deterministic() throws {
        let verbatim = evenlySpaced(["uh", "we", "we", "should", "go", "um", "tomorrow"])
        let a = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                             silenceParameters: .default)
        let b = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                             silenceParameters: .default)
        #expect(a.transcript.plainText() == b.transcript.plainText())
        #expect(a.edits == b.edits)
    }

    @Test("The conservative preset deletes nothing at all")
    func conservativeDeletesNothing() throws {
        let verbatim = evenlySpaced(["uh", "I", "I", "think", "um", "yes"])
        let result = try CleanProcessor().process(
            verbatim: verbatim, parameters: .conservative, silenceParameters: .default)
        #expect(result.wordsRemoved == 0)
        #expect(result.transcript.segments[0].words.count == 6)
    }
}

@Suite("CLEAN — deletions")
struct CleanDeletionTests {

    private func clean(_ tokens: [String], _ p: CleanParameters = .default) throws -> String {
        try CleanProcessor()
            .process(verbatim: evenlySpaced(tokens), parameters: p, silenceParameters: .default)
            .transcript.plainText()
    }

    @Test("Non-lexical fillers are removed")
    func removesFillers() throws {
        #expect(try clean(["uh", "so", "we", "start", "Monday"]) == "So we start Monday.")
        #expect(try clean(["um", "yes"]) == "Yes.")
        #expect(try clean(["I", "think", "er", "maybe"]) == "I think maybe.")
    }

    @Test("The §12 worked example keeps every real word")
    func section12Example() throws {
        // Verbatim: "uh so basically what I wanted to say was that we should
        // probably start on Monday". Only "uh" may go — "basically" and
        // "probably" shade meaning and must survive.
        let out = try clean(["uh", "so", "basically", "what", "I", "wanted", "to", "say",
                             "was", "that", "we", "should", "probably", "start", "on", "Monday"])
        #expect(out == "So basically what I wanted to say was that we should probably start on Monday.")
        #expect(out.contains("basically"))
        #expect(out.contains("probably"))
    }

    @Test("Affirmations that look like fillers are protected")
    func protectsAffirmations() throws {
        // Deleting "uh-huh" can invert the sense of an answer.
        #expect(try clean(["uh-huh", "that", "is", "right"]).lowercased().contains("uh-huh"))
        #expect(try clean(["mm-hmm", "exactly"]).lowercased().contains("mm-hmm"))
        #expect(try clean(["huh"]).lowercased().contains("huh"))
    }

    @Test("Stutters collapse")
    func collapsesStutters() throws {
        #expect(try clean(["I", "I", "think", "so"]) == "I think so.")
        #expect(try clean(["the", "the", "report"]) == "The report.")
    }

    @Test("Legitimate doublings survive")
    func keepsLegitimateDoublings() throws {
        // "had had" and "that that" are grammatical; collapsing them deletes a
        // real word and changes the sentence.
        #expect(try clean(["I", "had", "had", "enough"]) == "I had had enough.")
        #expect(try clean(["the", "thing", "that", "that", "man", "said"])
                == "The thing that that man said.")
    }

    @Test("A deliberate repetition with a pause is not a stutter")
    func pauseDefeatsCollapse() throws {
        // "no ... no, that is different" — the speaker meant both.
        let verbatim = verbatimTranscript([
            ("no", 0.0, 0.3), ("no", 1.4, 1.7), ("that", 1.8, 2.0),
            ("is", 2.1, 2.2), ("different", 2.3, 2.9),
        ])
        let out = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                               silenceParameters: .default).transcript.plainText()
        #expect(out.lowercased().hasPrefix("no no"), "a one-second pause was treated as a stutter: \(out)")
    }

    @Test("A tight repetition is a stutter")
    func tightRepetitionCollapses() throws {
        let verbatim = verbatimTranscript([
            ("we", 0.0, 0.15), ("we", 0.20, 0.35), ("should", 0.4, 0.7),
        ])
        let out = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                               silenceParameters: .default).transcript.plainText()
        #expect(out == "We should.")
    }

    @Test("Removing a parenthetical filler takes its delimiter with it")
    func stranded() throws {
        // "we should, um, start" must not become "we should, start". The comma
        // existed only to set off the filler; leaving it reads as a comma splice.
        let verbatim = verbatimTranscript([
            ("we", 0.0, 0.2), ("should,", 0.3, 0.6), ("um,", 0.7, 0.9),
            ("start", 1.0, 1.4), ("Monday", 1.5, 2.0),
        ])
        let out = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                               silenceParameters: .default).transcript.plainText()
        #expect(out == "We should start Monday.")
        #expect(!out.contains(", start"))
    }

    @Test("A comma that was not a filler delimiter survives")
    func keepsRealCommas() throws {
        // Nothing was removed here, so the comma must stay exactly as spoken.
        let verbatim = verbatimTranscript([
            ("yes,", 0.0, 0.3), ("we", 0.4, 0.6), ("agree", 0.7, 1.1),
        ])
        let out = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                               silenceParameters: .default).transcript.plainText()
        #expect(out == "Yes, we agree.")
    }

    @Test("Collapsing a stutter keeps the completed word, not the stumble")
    func collapseKeepsLaterToken() throws {
        // In "I, I wanted" the first token carries the comma marking the break;
        // the second is the word the speaker actually finished.
        let verbatim = verbatimTranscript([
            ("I,", 0.0, 0.15), ("I", 0.20, 0.35), ("wanted", 0.4, 0.8),
        ])
        let result = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                                  silenceParameters: .default)
        #expect(result.transcript.plainText() == "I wanted.")
        // The surviving word still spans the whole stumble.
        let first = result.transcript.segments[0].words[0]
        #expect(first.originalStart == .zero)
        #expect(first.originalEnd == .seconds(0.35))
    }

    @Test("Numbers and names are never touched")
    func preservesEntities() throws {
        let out = try clean(["We", "sold", "500", "units", "David", "met", "Sarah", "Chen"])
        #expect(out.contains("500"))
        #expect(out.contains("David"))
        #expect(out.contains("Sarah"))
        #expect(out.contains("Chen"))
    }

    @Test("Negations and hedges are never touched")
    func preservesPolarityAndModality() throws {
        let out = try clean(["we", "did", "not", "approve", "it", "and", "it", "might", "change"])
        #expect(out.contains("not"))
        #expect(out.contains("might"))
    }
}

@Suite("CLEAN — shaping")
struct CleanShapingTests {

    @Test("Doubled punctuation is repaired but real constructions survive")
    func punctuation() {
        #expect(CleanProcessor.repairPunctuation("Hello,, world..") == "Hello, world.")
        #expect(CleanProcessor.repairPunctuation("What ?!") == "What?!")
        #expect(CleanProcessor.repairPunctuation("a  b   c") == "a b c")
        #expect(CleanProcessor.repairPunctuation("word ,") == "word,")
    }

    @Test("Capitalization only ever adds information")
    func capitalization() {
        #expect(CleanProcessor.capitalize("hello there.", startsSentence: true) == "Hello there.")
        #expect(CleanProcessor.capitalize("one. two. three.", startsSentence: true)
                == "One. Two. Three.")
        // Never lowercases: a proper noun the engine got right must survive.
        #expect(CleanProcessor.capitalize("meeting with David", startsSentence: false)
                == "meeting with David")
        #expect(CleanProcessor.capitalize("NASA and IBM.", startsSentence: true) == "NASA and IBM.")
    }

    @Test("A full stop is added only where one is missing")
    func termination() {
        #expect(CleanProcessor.terminate("no stop here") == "no stop here.")
        #expect(CleanProcessor.terminate("already done.") == nil)
        #expect(CleanProcessor.terminate("a question?") == nil)
        // A trailing comma before a long pause is an artifact.
        #expect(CleanProcessor.terminate("trailing comma,") == "trailing comma.")
    }

    @Test("Punctuation stays tight against the preceding word")
    func joining() {
        #expect(CleanProcessor.join(["Hello", ",", "world", "."]) == "Hello, world.")
        #expect(CleanProcessor.join(["We", "sold", "500,", "up", "from", "312."])
                == "We sold 500, up from 312.")
    }

    @Test("A long pause becomes a paragraph break")
    func paragraphBreak() throws {
        // §7: "Hello..." [5 s] "...my name is David." must not become one line.
        let first = TranscriptSegment(
            originalStart: .zero, originalEnd: .seconds(1), text: "Hello",
            words: [Word(text: "Hello", originalStart: .zero, originalEnd: .seconds(1))])
        let second = TranscriptSegment(
            originalStart: .seconds(6), originalEnd: .seconds(8),
            text: "my name is David",
            words: ["my", "name", "is", "David"].enumerated().map { i, t in
                Word(text: t, originalStart: .seconds(6 + Double(i) * 0.4),
                     originalEnd: .seconds(6.3 + Double(i) * 0.4))
            },
            precedingGap: .seconds(5))

        let result = try CleanProcessor().process(
            verbatim: Transcript(variant: .verbatim, segments: [first, second],
                                 provenance: Provenance()),
            parameters: .default, silenceParameters: .default)

        let text = result.transcript.plainText()
        #expect(text.contains("\n\n"))
        #expect(text == "Hello.\n\nMy name is David.")
    }

    @Test("A gap marker survives so the reader sees what failed")
    func preservesGapMarkers() throws {
        let spoken = TranscriptSegment(
            originalStart: .zero, originalEnd: .seconds(1), text: "hello",
            words: [Word(text: "hello", originalStart: .zero, originalEnd: .seconds(1))])
        let gap = TranscriptSegment(
            originalStart: .seconds(1), originalEnd: .seconds(30), text: "",
            words: [], warnings: [.transcriptionGap])

        let result = try CleanProcessor().process(
            verbatim: Transcript(variant: .verbatim, segments: [spoken, gap],
                                 provenance: Provenance()),
            parameters: .default, silenceParameters: .default)

        #expect(result.transcript.segments.count == 2)
        #expect(result.transcript.segments[1].warnings.contains(.transcriptionGap))
        #expect(result.transcript.segments[1].originalEnd == .seconds(30))
    }

    @Test("Word timings survive cleaning, so subtitles stay aligned")
    func preservesTimings() throws {
        let verbatim = verbatimTranscript([
            ("uh", 0.0, 0.2), ("we", 0.5, 0.8), ("start", 1.0, 1.5),
        ])
        let result = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                                  silenceParameters: .default)
        let words = result.transcript.segments[0].words
        #expect(words.count == 2)
        #expect(words[0].text == "we")
        #expect(words[0].originalStart == .seconds(0.5))
        #expect(words[1].originalEnd == .seconds(1.5))
        // The segment now starts at the first surviving word, not at the filler.
        #expect(result.transcript.segments[0].originalStart == .seconds(0.5))
    }

    @Test("A collapsed stutter keeps covering its audio")
    func stutterTimingSpansBoth() throws {
        let verbatim = verbatimTranscript([("I", 0.0, 0.1), ("I", 0.15, 0.30), ("go", 0.4, 0.6)])
        let result = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                                  silenceParameters: .default)
        let words = result.transcript.segments[0].words
        #expect(words.count == 2)
        // The surviving "I" spans both utterances, so a subtitle cue does not
        // leave a silent hole where the stumble was.
        #expect(words[0].originalStart == .seconds(0.0))
        #expect(words[0].originalEnd == .seconds(0.30))
    }

    @Test("The transcript stays monotonic and correctly labelled")
    func structuralIntegrity() throws {
        let verbatim = evenlySpaced(["uh", "one", "two", "um", "three", "four"])
        let result = try CleanProcessor().process(verbatim: verbatim, parameters: .default,
                                                  silenceParameters: .default)
        #expect(result.transcript.variant == .clean)
        #expect(result.transcript.isMonotonic)
    }
}
