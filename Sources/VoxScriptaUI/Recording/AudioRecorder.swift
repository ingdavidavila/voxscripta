import AVFoundation
import Foundation
import Observation
import VoxScriptaCore

/// Captures the microphone to a file, and nothing else.
///
/// The app was built around files that already existed, which is the wrong
/// shape for a phone: a person with something to transcribe is holding the
/// thing making the sound. So this writes a new original, and then hands it to
/// exactly the same import path a dragged file takes. Nothing downstream knows
/// where the audio came from.
///
/// §5 governs the file this produces as much as any other original. It is
/// written once, closed, and never reopened for writing. The only code that
/// may remove it is ``discard``, and only before it has become a project —
/// at which point the user has made something and it stops being disposable.
@MainActor
@Observable
public final class AudioRecorder {

    public enum State: Equatable {
        case idle
        /// Asked for, not yet running.
        ///
        /// Exists because opening the microphone is not instant and, when the
        /// audio route is unusable, is not finite either. Without a state for
        /// it the interface has nothing truthful to show in between.
        case starting
        case recording
        case paused

        public var isActive: Bool { self != .idle }
    }

    /// Whether the microphone may be used, as the system currently sees it.
    public enum Permission: Equatable {
        case granted
        case denied
        /// Never asked. Asking is what produces the system prompt, so this is
        /// the only state in which starting a recording is allowed to block.
        case undetermined
    }

    private(set) public var state: State = .idle

    /// Seconds of audio captured, excluding anything spent paused.
    ///
    /// Read from the recorder rather than counted here: a timer that ticks
    /// while the encoder stalls would show a length the file does not have.
    ///
    /// Published only when the whole second changes. The clock is the only
    /// reader and it shows whole seconds, so assigning this on every meter
    /// tick invalidated the view ten times for each visible change.
    private(set) public var elapsed: TimeInterval = 0

    /// Recent input levels, oldest first, each 0…1.
    ///
    /// A meter exists for one reason: to show that the microphone is actually
    /// hearing something. A silent recording discovered an hour later is the
    /// failure worth spending a few pixels to prevent.
    private(set) public var levels: [Double] = []

    /// Where the current recording is being written, while one is running.
    private(set) public var fileURL: URL?

    /// Why recording is on hold, when the user did not pause it.
    ///
    /// The clock stops when no audio arrives, and a clock that stops on its
    /// own looks like a bug rather than a phone call.
    private(set) public var interruption: String?

    /// Set when the writer failed part-way through.
    ///
    /// The recording is not discarded when this happens: what reached the
    /// disk is still a readable file, and it is the user's.
    private(set) public var writeFailure: String?

    /// How many level samples the meter keeps.
    private static let meterHistory = 48

    /// Polling interval for the meter.
    ///
    /// Ten a second. It was twenty, which redrew the whole recording screen
    /// twice as often for a meter nobody can read any better at that rate.
    /// A level meter exists to show that the microphone is hearing something,
    /// and ten updates a second shows that just as well.
    private static let tick = Duration.milliseconds(100)

    private var session: RecordingSession?
    private var ticker: Task<Void, Never>?

    public init() {}

    // MARK: - Permission

    public static var permission: Permission {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
        #else
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .undetermined: .undetermined
        default: .denied
        }
        #endif
    }

    /// Asks for the microphone, showing the system prompt if it has not been shown.
    public static func requestPermission() async -> Bool {
        #if os(macOS)
        await AVCaptureDevice.requestAccess(for: .audio)
        #else
        await AVAudioApplication.requestRecordPermission()
        #endif
    }

    // MARK: - Where recordings live

    /// The folder new recordings are written to.
    ///
    /// The two platforms differ on purpose. On iOS this is the app's Documents
    /// folder, which `UIFileSharingEnabled` exposes in Files: a recording the
    /// user made is theirs, and burying it somewhere only this app can reach
    /// would make §5's promise hollow — the file survives, but they can never
    /// get it. On macOS the Finder reaches everywhere, so recordings sit beside
    /// the project library rather than being dropped into ~/Documents
    /// uninvited.
    public static var recordingsDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appending(path: "VoxScripta/Recordings")
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Recordings")
        #endif
    }

    /// A name that sorts chronologically and cannot collide.
    ///
    /// The timestamp is fixed-format rather than locale-formatted: a localized
    /// date contains slashes in most of the world, and a slash in a filename is
    /// a path separator.
    static func newRecordingURL(now: Date = .now,
                                existsAt: (URL) -> Bool = {
                                    FileManager.default.fileExists(atPath: $0.path)
                                }) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: now)
        let word = String(localized: "Recording")

        var candidate = recordingsDirectory.appending(path: "\(word) \(stamp).m4a")
        var suffix = 2
        while existsAt(candidate) {
            candidate = recordingsDirectory.appending(path: "\(word) \(stamp) (\(suffix)).m4a")
            suffix += 1
        }
        return candidate
    }

    // MARK: - Transport

    /// Begins writing a new recording.
    ///
    /// Asynchronous because opening a capture session blocks until the audio
    /// hardware is available, and that wait is not bounded. Run on the main
    /// actor it freezes the interface: the first time this was tried on a
    /// simulator whose input device would not open, starting never returned
    /// and the app stopped drawing — the recording screen it was about to
    /// present never appeared, and the whole thing looked like a dead button.
    ///
    /// So the blocking part runs on a detached task and is raced against a
    /// deadline. A microphone that has not started within
    /// ``startDeadline`` is reported as a failure the user can read rather
    /// than a window that stopped responding.
    ///
    /// - Throws: ``VoxScriptaError/microphoneDenied`` when permission is not
    ///   granted — this does not ask, because asking is asynchronous and the
    ///   caller decides when the prompt appears — or
    ///   ``VoxScriptaError/recordingFailed(reason:)`` when capture will not start.
    public func start() async throws {
        guard state == .idle else { return }
        guard Self.permission == .granted else { throw VoxScriptaError.microphoneDenied }

        let url = Self.newRecordingURL()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw VoxScriptaError.recordingFailed(reason: error.localizedDescription)
        }

        state = .starting
        fileURL = url
        elapsed = 0
        levels = []
        writeFailure = nil
        interruption = nil

        // Unstructured on purpose. A task group awaits every one of its
        // children before it exits, so a group cannot put a deadline on work
        // that may never return — and that is exactly what this is.
        let handoff = Handoff()
        Task.detached(priority: .userInitiated) {
            let session = RecordingSession(url: url)
            do {
                try session.start()
                handoff.deliver(.success(Box(session: session)))
            } catch {
                session.cancel()
                handoff.deliver(.failure(error))
            }
        }
        let deadline = Task {
            try await Task.sleep(for: Self.startDeadline)
            handoff.deliver(.failure(VoxScriptaError.recordingFailed(
                reason: String(localized: "the microphone did not start"))))
        }
        defer { deadline.cancel() }

        do {
            let box = try await handoff.wait()
            // Cancelled or discarded while the microphone was opening.
            guard state == .starting else {
                box.session.cancel()
                return
            }
            session = box.session
            state = .recording
            startTicking()
        } catch {
            // Cancelled while the microphone was still opening. The failure
            // that arrives afterwards — usually the deadline — is about a
            // recording the user already walked away from, and reporting it
            // would be an error message for something they did on purpose.
            guard state == .starting else { return }
            state = .idle
            fileURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// How long to wait for the microphone before calling it a failure.
    ///
    /// Generous: a cold audio route on a busy phone is slow, and a false
    /// failure is worse than a slow start. What it rules out is waiting
    /// forever.
    public static let startDeadline = Duration.seconds(8)

    /// Carries whichever finishes first — the microphone, or the deadline.
    ///
    /// A plain lock and a continuation rather than anything structured,
    /// because the point is to stop waiting on something that may not stop.
    /// When the deadline wins, the blocking call keeps a thread until the
    /// audio system releases it; that is the price of an interface that
    /// stays alive. A microphone that opens after the deadline is closed
    /// here rather than being left on with nothing watching it.
    private final class Handoff: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var pending: Result<Box, any Error>?
        private var waiter: CheckedContinuation<Box, any Error>?

        func deliver(_ value: Result<Box, any Error>) {
            lock.lock()
            if finished {
                lock.unlock()
                // The microphone opened after the deadline gave up on it.
                // Close it, and take the file with it: `start` has already
                // reported a failure and deleted what it knew about, so
                // leaving this one behind would put a recording the user
                // never saw into their Files.
                if case .success(let box) = value {
                    box.session.cancel()
                    try? FileManager.default.removeItem(at: box.session.url)
                }
                return
            }
            finished = true
            let waiter = self.waiter
            self.waiter = nil
            if waiter == nil { pending = value }
            lock.unlock()
            waiter?.resume(with: value)
        }

        func wait() async throws -> Box {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pending {
                    lock.unlock()
                    continuation.resume(with: pending)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }
    }

    /// Carries the open session back from the detached task.
    ///
    /// `RecordingSession` is `@unchecked Sendable` and does its own locking,
    /// so this exists only to name what is being handed over.
    fileprivate struct Box: @unchecked Sendable {
        let session: RecordingSession
    }

    public func pause() {
        guard state == .recording, let session else { return }
        session.pause()
        state = .paused
        // The meter is left where it stopped rather than decaying to zero,
        // which would read as "not hearing you" instead of "paused".
        ticker?.cancel()
        ticker = nil
        elapsed = session.elapsed
    }

    public func resume() {
        guard state == .paused, let session else { return }
        session.resume()
        state = .recording
        startTicking()
    }

    /// Stops and keeps the file.
    ///
    /// Asynchronous because finalizing the file is. The file is already
    /// readable without it — that is the whole point of writing in fragments
    /// — so this is tidying, not rescue.
    ///
    /// - Returns: The finished recording, or `nil` if nothing was captured.
    @discardableResult
    public func finish() async -> URL? {
        guard let url = fileURL else { return nil }
        // Stopped before the microphone ever opened: there is nothing to keep,
        // and `start` sees the state change and closes the session if one
        // arrives afterwards.
        guard let session else {
            clear()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let length = await session.finish()
        clear()
        // A recording with no audio in it is not a file worth keeping, and
        // handing it to the importer would produce a project that fails at the
        // first stage. Nothing has been shown to the user yet, so removing it
        // here takes nothing away from them.
        guard length > 0.25 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// Stops and deletes the file.
    ///
    /// Only reachable from an explicit "discard" the user confirms, and only
    /// while the recording is still a recording — once it has become a project
    /// this is no longer the code that can remove it.
    public func discard() {
        let url = fileURL
        session?.cancel()
        clear()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Returns to idle. Does not touch the file either way.
    private func clear() {
        ticker?.cancel()
        ticker = nil
        session = nil
        fileURL = nil
        state = .idle
        levels = []
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self, let session = self.session else { return }
                // A writer that failed mid-recording stops the clock without
                // saying so, which looks exactly like a microphone that went
                // quiet. Surfaced instead, so the recording can be stopped
                // and whatever reached the disk kept.
                if let failure = session.failure {
                    self.writeFailure = failure
                    return
                }
                self.interruption = session.interruption
                let now = session.elapsed
                if Int(now) != Int(self.elapsed) { self.elapsed = now }
                self.append(level: Self.normalize(Float(session.level)))
            }
        }
    }

    private func append(level: Double) {
        levels.append(level)
        if levels.count > Self.meterHistory { levels.removeFirst(levels.count - Self.meterHistory) }
    }

    /// Turns a level in decibels full scale into a bar height.
    ///
    /// The reading is the buffer's peak, measured from the samples
    /// themselves, and runs from -160 dB to 0. Mapping that range linearly
    /// puts every ordinary voice in the top tenth of the meter, so the floor
    /// is -50 dB — a quiet room, not digital silence — and the result is
    /// raised to a power below one to open out the bottom of the scale,
    /// which is where the difference between "quiet" and "nothing" lives.
    static func normalize(_ decibels: Float) -> Double {
        let floorDB = -50.0
        let clamped = Swift.max(floorDB, Swift.min(0, Double(decibels)))
        return pow((clamped - floorDB) / -floorDB, 0.6)
    }
}
