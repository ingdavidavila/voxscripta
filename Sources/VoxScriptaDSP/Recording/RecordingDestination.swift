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
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appending(path: "VoxScripta/Recordings")
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
}
