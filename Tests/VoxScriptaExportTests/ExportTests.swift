import Testing
import Foundation
import AVFoundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaExport

/// A transcript with real word timings, as the engine produces.
func timedTranscript(variant: TranscriptVariant = .clean) -> Transcript {
    let sentences: [(String, Double, Double)] = [
        ("We sold 500 units in the third quarter.", 1.5, 5.2),
        ("David met with Sarah Chen on Tuesday.", 6.0, 9.4),
        ("We did not approve the revised budget.", 14.0, 17.1),
    ]
    let segments = sentences.enumerated().map { index, spec -> TranscriptSegment in
        let words = spec.0.split(separator: " ").map(String.init)
        let step = (spec.2 - spec.1) / Double(words.count)
        return TranscriptSegment(
            originalStart: .seconds(spec.1), originalEnd: .seconds(spec.2),
            text: spec.0,
            words: words.enumerated().map { i, w in
                Word(text: w,
                     originalStart: .seconds(spec.1 + Double(i) * step),
                     originalEnd: .seconds(spec.1 + Double(i + 1) * step - 0.02))
            },
            precedingGap: index == 2 ? .seconds(4.6) : (index == 0 ? nil : .seconds(0.8)))
    }
    return Transcript(variant: variant, segments: segments, provenance: Provenance())
}

@Suite("Timecodes")
struct TimecodeTests {

    @Test("SubRip and WebVTT differ only in the fraction separator")
    func separators() {
        let t = MediaTime.seconds(3725.5)   // 1:02:05.500
        #expect(Timecode.subRip(t) == "01:02:05,500")
        #expect(Timecode.webVTT(t) == "01:02:05.500")
    }

    @Test("Millisecond precision is exact")
    func precision() {
        #expect(Timecode.subRip(.zero) == "00:00:00,000")
        #expect(Timecode.subRip(.milliseconds(1)) == "00:00:00,001")
        #expect(Timecode.subRip(.milliseconds(999)) == "00:00:00,999")
        #expect(Timecode.subRip(.seconds(59.999)) == "00:00:59,999")
        #expect(Timecode.subRip(.seconds(60)) == "00:01:00,000")
        #expect(Timecode.subRip(.seconds(3600)) == "01:00:00,000")
    }

    @Test("A six-hour recording formats correctly")
    func longRecording() {
        // The target case from §20. An hours field that wrapped would silently
        // ruin every cue past the six-hour mark.
        #expect(Timecode.subRip(.seconds(6 * 3600 + 1)) == "06:00:01,000")
        #expect(Timecode.webVTT(.seconds(12 * 3600)) == "12:00:00.000")
    }
}

@Suite("Subtitle export")
struct SubtitleExportTests {

    @Test("SubRip has the structure players expect")
    func subRipStructure() throws {
        let data = try SubRipExporter().export(timedTranscript(), options: .default)
        let text = String(decoding: data, as: UTF8.self)
        let blocks = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }

        #expect(!blocks.isEmpty)
        for (index, block) in blocks.enumerated() {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(Int(lines[0]) == index + 1, "cue numbering must be sequential from 1")
            #expect(lines[1].contains(" --> "))
            #expect(lines.count >= 3, "a cue needs text")
        }
    }

    @Test("WebVTT starts with its required header")
    func webVTTHeader() throws {
        let data = try WebVTTExporter().export(timedTranscript(), options: .default)
        let text = String(decoding: data, as: UTF8.self)
        // A file without this line is rejected outright by every player.
        #expect(text.hasPrefix("WEBVTT\n"))
        #expect(text.contains(" --> "))
        #expect(!text.contains(","), "VTT uses a period before the fraction, not a comma")
    }

    @Test("Cue times match the transcript's word timings")
    func timingsMatchSource() throws {
        let transcript = timedTranscript()
        let cues = CueBuilder.default.cues(from: transcript)
        #expect(!cues.isEmpty)

        // Every cue must lie inside a segment it came from — the property that
        // makes subtitles line up with the audio rather than merely look plausible.
        for cue in cues {
            let covering = transcript.segments.first {
                cue.range.start >= $0.originalStart - .milliseconds(1)
                    && cue.range.end <= $0.originalEnd + .milliseconds(1)
            }
            #expect(covering != nil, "cue \(cue.index) at \(cue.range) matches no segment")
        }
        // And they must advance.
        for (a, b) in zip(cues, cues.dropFirst()) {
            #expect(a.range.start <= b.range.start)
        }
    }

    @Test("AVFoundation parses the generated WebVTT")
    func avFoundationAcceptsOutput() async throws {
        // Verified against the system parser — the same one QuickTime and Safari
        // use — rather than against a reimplementation of my own writer. A file
        // this accepts is a file a player will accept.
        let tmp = try TempDirectory()
        let transcript = timedTranscript()
        let url = tmp.url.appending(path: "captions.vtt")
        try WebVTTExporter().export(transcript, options: .default).write(to: url)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        #expect(tracks.count == 1, "AVFoundation found no text track")

        let duration = try await asset.load(.duration)
        let cues = CueBuilder.default.cues(from: transcript)
        let lastCueEnd = cues.last!.range.end.seconds
        // The asset's duration is the last cue's end, so a timing error anywhere
        // in the file shows up here.
        #expect(abs(CMTimeGetSeconds(duration) - lastCueEnd) < 0.05,
                "AVFoundation read \(CMTimeGetSeconds(duration))s, expected \(lastCueEnd)s")
    }

    @Test("Long segments are split into readable cues")
    func splitsLongSegments() {
        let words = (0..<120).map { "word\($0)" }
        let segment = TranscriptSegment(
            originalStart: .zero, originalEnd: .seconds(60),
            text: words.joined(separator: " "),
            words: words.enumerated().map { i, w in
                Word(text: w, originalStart: .seconds(Double(i) * 0.5),
                     originalEnd: .seconds(Double(i) * 0.5 + 0.4))
            })
        let cues = CueBuilder.default.cues(from: Transcript(
            variant: .clean, segments: [segment], provenance: Provenance()))

        #expect(cues.count > 1, "a 60-second segment must not become one cue")
        for cue in cues {
            #expect(cue.range.duration <= .seconds(7), "cue \(cue.index) is too long to read")
            #expect(cue.lines.count <= 2, "a cue should not exceed two display lines")
        }
    }

    @Test("Splitting loses no words")
    func splittingPreservesText() {
        let transcript = timedTranscript()
        let cues = CueBuilder.default.cues(from: transcript)
        let before = TextTokenizer.tokens(transcript.plainText())
        let after = TextTokenizer.tokens(cues.flatMap(\.lines).joined(separator: " "))
        #expect(before == after, "cue splitting changed the words")
    }

    @Test("A transcript with no timed content is refused, not silently empty")
    func refusesUntimedTranscript() {
        let empty = Transcript(variant: .clean, segments: [], provenance: Provenance())
        #expect(throws: VoxScriptaError.self) {
            _ = try SubRipExporter().export(empty, options: .default)
        }
        #expect(throws: VoxScriptaError.self) {
            _ = try WebVTTExporter().export(empty, options: .default)
        }
    }

    @Test("A gap marker produces no empty caption")
    func skipsGapMarkers() {
        let gap = TranscriptSegment(originalStart: .zero, originalEnd: .seconds(30),
                                    text: "", words: [], warnings: [.transcriptionGap])
        var segments = timedTranscript().segments
        segments.insert(gap, at: 1)
        let cues = CueBuilder.default.cues(from: Transcript(
            variant: .clean, segments: segments, provenance: Provenance()))
        // A blank caption box on screen for thirty seconds is worse than nothing.
        #expect(cues.allSatisfy { !$0.lines.joined().isEmpty })
    }
}

@Suite("Document export")
struct DocumentExportTests {

    @Test("Plain text keeps paragraph structure")
    func plainText() throws {
        let data = try PlainTextExporter().export(timedTranscript(), options: .default)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("500"))
        #expect(text.contains("Sarah Chen"))
        #expect(text.contains("did not approve"))
        // The 4.6-second pause before the third sentence is a paragraph break.
        #expect(text.contains("\n"))
    }

    @Test("Timestamps and speaker labels appear when asked for")
    func optionalAnnotations() throws {
        var options = ExportOptions.default
        options.includeTimestamps = true
        let text = String(decoding: try PlainTextExporter().export(timedTranscript(),
                                                                   options: options),
                          as: UTF8.self)
        #expect(text.contains("[0:01.500]"))
    }

    @Test("Markdown escapes syntax so a transcript is not reformatted")
    func markdownEscaping() throws {
        let segment = TranscriptSegment(
            originalStart: .zero, originalEnd: .seconds(2),
            text: "We discussed *emphasis* and the # channel and a [link].",
            words: [])
        let data = try MarkdownExporter().export(
            Transcript(variant: .clean, segments: [segment], provenance: Provenance()),
            options: .default)
        let text = String(decoding: data, as: UTF8.self)
        // A speaker who said "asterisk emphasis asterisk" should not have their
        // words rendered as italics.
        #expect(text.contains("\\*emphasis\\*"))
        #expect(text.contains("\\#"))
        #expect(text.contains("\\[link\\]"))
    }

    @Test("DOCX is a valid archive containing the required parts")
    func docxIsValidZip() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "transcript.docx")
        try DOCXExporter().export(timedTranscript(), options: .default).write(to: url)

        // Checked with the system unzip rather than by reading back my own
        // writer, which would only prove it is self-consistent.
        let test = Process()
        test.executableURL = URL(filePath: "/usr/bin/unzip")
        test.arguments = ["-t", url.path]
        test.standardOutput = FileHandle.nullDevice
        test.standardError = FileHandle.nullDevice
        try test.run()
        test.waitUntilExit()
        #expect(test.terminationStatus == 0, "unzip rejected the .docx")

        let list = Process()
        list.executableURL = URL(filePath: "/usr/bin/unzip")
        list.arguments = ["-l", url.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        try list.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()

        for part in ["[Content_Types].xml", "_rels/.rels",
                     "word/document.xml", "word/styles.xml"] {
            #expect(listing.contains(part), "the archive is missing \(part)")
        }
    }

    @Test("DOCX content survives the round trip")
    func docxContent() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appending(path: "t.docx")
        try DOCXExporter().export(timedTranscript(), options: .default).write(to: url)

        let extract = Process()
        extract.executableURL = URL(filePath: "/usr/bin/unzip")
        extract.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        extract.standardOutput = pipe
        try extract.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        extract.waitUntilExit()

        #expect(xml.contains("500"))
        #expect(xml.contains("Sarah Chen"))
        #expect(xml.contains("did not approve"))
    }

    @Test("XML special characters are escaped")
    func docxEscaping() {
        #expect(DOCXExporter.escape("a & b") == "a &amp; b")
        #expect(DOCXExporter.escape("<tag>") == "&lt;tag&gt;")
        // A control character would make Word refuse the whole document.
        #expect(DOCXExporter.escape("bad\u{0007}char") == "badchar")
    }
}

@Suite("Format availability")
struct FormatAvailabilityTests {

    @Test("Every format is offered for a timed transcript")
    func timedOffersAll() {
        let available = Exporters.available(for: timedTranscript())
        #expect(Set(available) == Set(ExportFormat.allCases))
    }

    @Test("Subtitle formats are withheld from an untimed transcript")
    func untimedWithholdsSubtitles() {
        let untimed = Transcript(
            variant: .polished,
            segments: [TranscriptSegment(originalStart: .zero, originalEnd: .zero,
                                         text: "No timing here.", words: [])],
            provenance: Provenance())
        let available = Exporters.available(for: untimed)
        #expect(!available.contains(.subRip))
        #expect(!available.contains(.webVTT))
        #expect(available.contains(.plainText))
        #expect(available.contains(.docx))
    }

    @Test("Every format produces output for every variant")
    func allFormatsAllVariants() throws {
        for variant in TranscriptVariant.allCases {
            let transcript = timedTranscript(variant: variant)
            for format in Exporters.available(for: transcript) {
                let data = try Exporters.make(format).export(transcript, options: .default)
                #expect(!data.isEmpty, "\(format) produced nothing for \(variant)")
            }
        }
    }

    @Test("Filenames name the variant, so three exports do not collide")
    func filenames() {
        let exporter = SubRipExporter()
        #expect(exporter.filename(base: "Interview", variant: .clean)
                == "Interview — clean.srt")
        #expect(exporter.filename(base: "Interview", variant: .polished)
                == "Interview — polished.srt")
    }
}
