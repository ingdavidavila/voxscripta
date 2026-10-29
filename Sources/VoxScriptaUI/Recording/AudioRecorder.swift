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
    private(set) public var elapsed: TimeInterval = 0

    /// Recent input levels, oldest first, each 0…1.
    ///
    /// A meter exists for one reason: to show that the microphone is actually
    /// hearing something. A silent recording discovered an hour later is the
    /// failure worth spending a few pixels to prevent.
    private(set) public var levels: [Double] = []

    /// Where the current recording is being written, while one is running.
    private(set) public var fileURL: URL?

    /// How many level samples the meter keeps.
    private static let meterHistory = 48

    /// Polling interval for the clock and the meter.
    ///
    /// Twenty a second: fast enough that the meter moves with the voice, slow
    /// enough to be free next to an audio encoder.
    private static let tick = Duration.milliseconds(50)

    private var recorder: AVAudioRecorder?
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

    /// AAC in an MPEG-4 container, mono, at a bit rate chosen for speech.
    ///
    /// Lossy, deliberately. The pipeline resamples everything to 16 kHz mono
    /// before a transcriber ever sees it, so 64 kbit/s at 44.1 kHz is already
    /// far more than the recognition uses, while an hour of linear PCM would
    /// be 300 MB on a phone. The AAC encoder's 2112-sample priming delay is
    /// already handled in the decoder, so this costs no alignment.
    nonisolated static var encoderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    // MARK: - Transport

    /// Begins writing a new recording.
    ///
    /// Asynchronous because `AVAudioRecorder.record()` blocks until the audio
    /// queue has the hardware, and that wait is not bounded. Run on the main
    /// actor it freezes the interface: the first time this was tried on a
    /// simulator whose input device would not open, `record()` never returned
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

        // Unstructured on purpose. A task group awaits every one of its
        // children before it exits, so a group cannot put a deadline on work
        // that may never return — and that is exactly what this is.
        let handoff = Handoff()
        Task.detached(priority: .userInitiated) {
            do { handoff.deliver(.success(try Self.openMicrophone(writingTo: url))) }
            catch { handoff.deliver(.failure(error)) }
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
                box.recorder.stop()
                return
            }
            recorder = box.recorder
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
                if case .success(let box) = value { box.recorder.stop() }
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

    /// Carries the recorder back from the detached task.
    ///
    /// `AVAudioRecorder` is not `Sendable`. It is safe to move here because
    /// exactly one task holds it until it is handed over, and from then on it
    /// is only touched from the main actor — the audio queue's own thread is
    /// the framework's business, not this code's.
    fileprivate struct Box: @unchecked Sendable {
        let recorder: AVAudioRecorder
    }

    /// The part that blocks. Runs nowhere near the main thread.
    private nonisolated static func openMicrophone(writingTo url: URL) throws -> Box {
        #if os(iOS) || os(visionOS)
        // Without an active session the recorder starts and captures silence.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            throw VoxScriptaError.recordingFailed(reason: error.localizedDescription)
        }
        #endif

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: encoderSettings)
        } catch {
            throw VoxScriptaError.recordingFailed(reason: error.localizedDescription)
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw VoxScriptaError.recordingFailed(
                reason: String(localized: "the microphone is in use by something else"))
        }
        return Box(recorder: recorder)
    }

    public func pause() {
        guard state == .recording, let recorder else { return }
        recorder.pause()
        state = .paused
        // Leave the meter where it stopped rather than letting it decay to
        // zero, which would read as "not hearing you" instead of "paused".
        ticker?.cancel()
        ticker = nil
        elapsed = recorder.currentTime
    }

    public func resume() {
        guard state == .paused, let recorder, recorder.record() else { return }
        state = .recording
        startTicking()
    }

    /// Stops and keeps the file.
    ///
    /// - Returns: The finished recording, or `nil` if nothing was captured.
    @discardableResult
    public func finish() -> URL? {
        guard let url = fileURL else { return nil }
        // Stopped before the microphone ever opened: there is nothing to keep,
        // and `start` sees the state change and closes the queue if it arrives.
        guard let recorder else {
            stopEverything()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let length = recorder.currentTime
        stopEverything()
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
        stopEverything()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func stopEverything() {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        fileURL = nil
        state = .idle
        levels = []
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
        #endif
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                self.append(level: Self.normalize(recorder.averagePower(forChannel: 0)))
            }
        }
    }

    private func append(level: Double) {
        levels.append(level)
        if levels.count > Self.meterHistory { levels.removeFirst(levels.count - Self.meterHistory) }
    }

    /// Turns the recorder's decibel reading into a bar height.
    ///
    /// `averagePower` runs from -160 dB to 0. Mapping that range linearly puts
    /// every ordinary voice in the top tenth of the meter, so the floor is
    /// -50 dB — quiet room, not digital silence — and the result is raised to
    /// a power below one to open out the bottom of the scale, which is where
    /// the difference between "quiet" and "nothing" actually lives.
    static func normalize(_ decibels: Float) -> Double {
        let floorDB = -50.0
        let clamped = Swift.max(floorDB, Swift.min(0, Double(decibels)))
        return pow((clamped - floorDB) / -floorDB, 0.6)
    }
}
