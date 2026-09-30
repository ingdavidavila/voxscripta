import Foundation
import VoxScriptaCore

/// Subtitle timecode formatting.
///
/// Both formats carry millisecond precision and differ only in the separator
/// before the fraction — SubRip uses a comma, WebVTT a period. Getting that wrong
/// produces a file that looks right and silently fails to load, so the two are
/// generated from one place.
public enum Timecode {

    /// `HH:MM:SS,mmm` — SubRip.
    public static func subRip(_ time: MediaTime) -> String {
        format(time, fractionSeparator: ",")
    }

    /// `HH:MM:SS.mmm` — WebVTT.
    public static func webVTT(_ time: MediaTime) -> String {
        format(time, fractionSeparator: ".")
    }

    private static func format(_ time: MediaTime, fractionSeparator: String) -> String {
        // Negative times cannot occur on a media timeline, but clamping is
        // cheaper than a malformed file if one ever does.
        let total = Swift.max(time.nanoseconds, 0)
        let milliseconds = total / 1_000_000 % 1000
        let seconds = total / 1_000_000_000 % 60
        let minutes = total / 60_000_000_000 % 60
        let hours = total / 3_600_000_000_000
        return String(format: "%02d:%02d:%02d%@%03d",
                      hours, minutes, seconds, fractionSeparator, milliseconds)
    }
}

/// One subtitle cue.
public struct SubtitleCue: Sendable, Equatable {
    public let index: Int
    public let range: TimeRange
    public let lines: [String]
    public let speaker: SpeakerID?

    public init(index: Int, range: TimeRange, lines: [String], speaker: SpeakerID? = nil) {
        self.index = index
        self.range = range
        self.lines = lines
        self.speaker = speaker
    }
}

/// Turns a transcript into cues a player can display.
///
/// A transcript segment is not a subtitle. Segments run to whatever length the
/// speaker's pauses produced, and a twenty-second cue is unreadable, so long
/// segments are split — on word timings when they exist, which is what keeps the
/// result aligned with the audio rather than merely plausible.
public struct CueBuilder: Sendable {
    /// Longest a single cue may stay on screen.
    public let maximumDuration: MediaTime
    /// Characters per cue before it is split.
    public let maximumCharacters: Int
    /// Shortest a cue may be, so a stray word does not flash past.
    public let minimumDuration: MediaTime

    public init(
        maximumDuration: MediaTime = .seconds(6),
        maximumCharacters: Int = 84,
        minimumDuration: MediaTime = .milliseconds(800)
    ) {
        self.maximumDuration = maximumDuration
        self.maximumCharacters = maximumCharacters
        self.minimumDuration = minimumDuration
    }

    public static let `default` = CueBuilder()

    public func cues(from transcript: Transcript) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var index = 1

        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A gap marker has no text; emitting an empty cue would show a blank
            // caption box rather than nothing.
            guard !text.isEmpty else { continue }

            for piece in split(segment) {
                cues.append(SubtitleCue(
                    index: index, range: piece.range,
                    lines: wrap(piece.text), speaker: segment.speaker))
                index += 1
            }
        }
        return cues
    }

    // MARK: - Splitting

    private struct Piece { let range: TimeRange; let text: String }

    private func split(_ segment: TranscriptSegment) -> [Piece] {
        let whole = Piece(range: segment.range, text: segment.text)
        let needsSplit = segment.range.duration > maximumDuration
            || segment.text.count > maximumCharacters
        guard needsSplit else { return [whole] }

        // Without word timings there is nothing to split on that would stay
        // aligned, so the segment is left whole rather than guessed at. This is
        // the polished variant's situation: its text no longer matches the
        // spoken words, so its word timings were dropped.
        guard !segment.words.isEmpty else { return [whole] }

        var pieces: [Piece] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let end = MediaTime.max(last.originalEnd, first.originalStart + minimumDuration)
            pieces.append(Piece(
                range: TimeRange(start: first.originalStart,
                                 end: MediaTime.min(end, segment.originalEnd)),
                text: current.map(\.text).joined(separator: " ")))
            current = []
        }

        for word in segment.words {
            let candidateLength = current.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
            let candidateDuration = current.first.map { word.originalEnd - $0.originalStart }
                ?? .zero
            if !current.isEmpty,
               candidateLength > maximumCharacters || candidateDuration > maximumDuration {
                flush()
            }
            current.append(word)
        }
        flush()
        return pieces.isEmpty ? [whole] : pieces
    }

    /// Breaks a cue into at most two display lines.
    private func wrap(_ text: String) -> [String] {
        guard text.count > maximumCharacters / 2 else { return [text] }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [text] }

        // Balance the two lines rather than filling the first: a long line above
        // a two-word line reads badly.
        let target = text.count / 2
        var first: [String] = []
        var length = 0
        for word in words {
            if length >= target { break }
            first.append(word)
            length += word.count + 1
        }
        let second = words.dropFirst(first.count)
        guard !first.isEmpty, !second.isEmpty else { return [text] }
        return [first.joined(separator: " "), second.joined(separator: " ")]
    }
}
