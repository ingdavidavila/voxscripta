import Foundation
import VoxScriptaCore

/// Where recordings go, and what they are called.
///
/// In the engine rather than in an interface because both are rules. Two
/// applications that disagreed about where a recording lands would be two
/// applications, and `Docs/PARITY.md` is the contract this serves. It started
/// in `AudioRecorder`, which only the Apple interface can see.
public enum RecordingDestination {

    /// The folder recordings are written to.
    ///
    /// On iOS it has to be somewhere the Files app can reach: a recording the
    /// user cannot get to would make §5's promise hollow — the file survives,
    /// but they can never have it. Everywhere else the file manager reaches
    /// everywhere, so recordings sit beside the project library rather than
    /// being dropped into a documents folder uninvited.
    public static var directory: URL {
        #if os(iOS) || os(visionOS) || os(tvOS) || os(watchOS)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Recordings")
        #else
        // The same path as before on macOS, Linux and Windows, by way of the
        // one place that decides. On Android the old expression resolved to a
        // read-only `/home` that does not exist, so recordings had nowhere to
        // go — and the failure surfaced as the microphone refusing to open,
        // which is what sent the Android session looking at audio code.
        //
        // Android note, not yet resolved: the app's private files directory is
        // no more reachable by the user than iOS's container was, so §5's
        // promise that a recording is always retrievable needs the same answer
        // there that `.documentDirectory` gives above. That belongs with the
        // SAF work rather than here, and is recorded in PORTING.md.
        return DataDirectory.root.appending(path: "Recordings")
        #endif
    }

    /// A name that sorts chronologically and cannot collide.
    ///
    /// The timestamp is fixed-format rather than locale-formatted: a localized
    /// date contains slashes in most of the world, and a slash in a filename is
    /// a path separator.
    public static func newRecordingURL(
        now: Date = .now,
        existsAt: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: now)
        let word = String(localized: "Recording")

        var candidate = directory.appending(path: "\(word) \(stamp).m4a")
        var suffix = 2
        while existsAt(candidate) {
            candidate = directory.appending(path: "\(word) \(stamp) (\(suffix)).m4a")
            suffix += 1
        }
        return candidate
    }
}

/// How a level meter reads.
public enum RecordingLevel {

    /// Maps decibels full scale onto `0...1` for a meter.
    ///
    /// A rule rather than a presentation choice, which is why it is here: two
    /// interfaces whose meters moved differently for the same microphone would
    /// be describing two different recordings.
    ///
    /// A linear dBFS scale puts every ordinary voice in the top tenth of the
    /// meter, so the floor is −50 dB — a quiet room, not digital silence — and
    /// the result is raised to a power below one to open out the bottom of the
    /// scale, which is where the difference between "quiet" and "nothing"
    /// lives.
    public static func normalize(_ decibels: Double) -> Double {
        let floorDB = -50.0
        let clamped = Swift.max(floorDB, Swift.min(0, decibels))
        return pow((clamped - floorDB) / -floorDB, 0.6)
    }

    /// The reading for a buffer whose samples are all exactly zero.
    ///
    /// Not a quiet room — a quiet room has a noise floor, and the quietest
    /// nonzero sample 16-bit audio can carry is about −90 dB. This is the
    /// value for an input that is delivering nothing whatsoever, which is a
    /// different condition and a diagnosable one.
    public static let digitalSilenceDB = -160.0
}

/// Notices an input that is running but has never delivered any audio.
///
/// The case this exists for: capture starts, the clock runs, the meter sits
/// flat, and what lands on disk is a file of silence. On Android that is what
/// an undeclared `RECORD_AUDIO` produced — the recording screen said
/// "Recording… 0:03" and wrote a silent file, which is worse than failing,
/// because the person believes they have a recording and finds out later that
/// they do not. The same shape is reachable anywhere: a muted interface, a USB
/// device that enumerates but captures nothing, a mic the system has handed to
/// something else.
///
/// Here rather than in an interface because it is a rule about what a
/// recording *is*, and two interfaces that disagreed about when a microphone
/// is dead would be describing two different recordings — the same reason
/// ``RecordingLevel/normalize(_:)`` is here.
///
/// What it deliberately does **not** do is warn about silence later in a
/// recording. Pauses are not a fault in an application whose whole premise is
/// finding and removing them, and someone recording a quiet room on purpose is
/// doing something ordinary. The diagnosable condition is narrower: the input
/// has produced *nothing at all*, not once, since capture began. One nonzero
/// sample proves the microphone is live and retires the check for good.
public struct SilentInputWatch: Sendable, Equatable {

    /// How long an input may deliver pure silence before it is worth saying.
    ///
    /// Long enough that someone who starts recording and then collects their
    /// thoughts is not accused of a broken microphone; short enough that an
    /// hour of silence is not discovered at the end of the hour.
    public static let patience: TimeInterval = 8

    /// True once the microphone has been heard, which settles it permanently.
    public private(set) var hasHeardAudio = false

    /// True once silence has gone on long enough to be worth reporting.
    public private(set) var isSilent = false

    public init() {}

    /// Feeds one meter reading, and says whether to warn.
    ///
    /// - Parameters:
    ///   - decibels: the reading, as ``RecordingLevel`` measures it.
    ///   - elapsed: seconds of recording so far, from the recording's own
    ///     clock rather than the wall's — a clock that has stopped is a
    ///     different fault, already reported elsewhere, and should not also
    ///     accumulate towards this one.
    /// - Returns: true when the input has been silent past ``patience``.
    @discardableResult
    public mutating func observe(level decibels: Double,
                                 elapsed: TimeInterval) -> Bool {
        if hasHeardAudio { return false }
        if decibels > RecordingLevel.digitalSilenceDB {
            hasHeardAudio = true
            isSilent = false
            return false
        }
        isSilent = elapsed >= Self.patience
        return isSilent
    }
}
