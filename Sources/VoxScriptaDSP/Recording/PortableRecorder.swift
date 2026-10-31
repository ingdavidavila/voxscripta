import Foundation
import CMiniaudio
import VoxScriptaCore

/// The microphone on the platforms that are not Apple's.
///
/// miniaudio opens the capture device — WASAPI on Windows, ALSA or PulseAudio
/// on Linux, AAudio on Android, CoreAudio on a Mac — behind one API, and asks
/// it for exactly the format the writer wants, so there is no conversion here
/// to get wrong. ``FragmentedWriter`` turns that into the same fragmented m4a
/// the Apple recorder produces.
///
/// The division of labour is the same as on Apple and for the same reason: a
/// device cannot be opened on a machine with no microphone, so everything that
/// *can* be tested without one lives in the writer, and this class is kept thin
/// enough to read.
///
/// Pausing is simpler here than on Apple. Nothing is written while paused, and
/// the file's timeline is whatever was written — so there is no gap to skip and
/// no timestamps to shift.
public final class PortableRecorder: @unchecked Sendable {

    public enum State: Equatable {
        case idle
        case recording
        case paused
    }

    public let url: URL

    private var device = ma_device()
    private var writer: FragmentedWriter?
    private let lock = NSLock()
    private var _state: State = .idle
    private var _level: Double = -160
    private var _failure: String?
    private var deviceOpen = false

    /// Capture format. Mono at 44.1 kHz, matching the Apple recorder, and far
    /// beyond the 16 kHz the pipeline reduces everything to.
    public static let sampleRate = 44_100

    public init(url: URL) {
        self.url = url
    }

    public var state: State { lock.withLock { _state } }
    /// Seconds of audio actually written, excluding anything paused.
    public var elapsed: TimeInterval { lock.withLock { writer?.elapsed ?? 0 } }
    /// Peak of the last block, in decibels full scale.
    public var level: Double { lock.withLock { _level } }
    /// Set when capture or writing failed part-way through.
    public var failure: String? { lock.withLock { _failure } }

    // MARK: - Transport

    /// Opens the microphone and begins writing. Blocks; not for the main thread.
    public func start() throws {
        lock.lock()
        guard _state == .idle else { lock.unlock(); return }
        lock.unlock()

        let newWriter = try FragmentedWriter(url: url, sampleRate: Self.sampleRate)

        var config = ma_device_config_init(ma_device_type_capture)
        config.capture.format = ma_format_f32
        config.capture.channels = 1
        config.sampleRate = ma_uint32(Self.sampleRate)
        config.dataCallback = { device, _, input, frameCount in
            guard let device, let input,
                  let context = device.pointee.pUserData else { return }
            let recorder = Unmanaged<PortableRecorder>
                .fromOpaque(context).takeUnretainedValue()
            recorder.captured(input.assumingMemoryBound(to: Float.self), Int(frameCount))
        }
        config.pUserData = Unmanaged.passUnretained(self).toOpaque()

        guard ma_device_init(nil, &config, &device) == MA_SUCCESS else {
            newWriter.abandon()
            try? FileManager.default.removeItem(at: url)
            throw VoxScriptaError.recordingFailed(
                reason: String(localized: "no microphone is available"))
        }
        guard ma_device_start(&device) == MA_SUCCESS else {
            ma_device_uninit(&device)
            newWriter.abandon()
            try? FileManager.default.removeItem(at: url)
            throw VoxScriptaError.recordingFailed(
                reason: String(localized: "the microphone did not start"))
        }

        lock.withLock {
            writer = newWriter
            deviceOpen = true
            _state = .recording
        }
    }

    public func pause() {
        lock.withLock { if _state == .recording { _state = .paused } }
    }

    public func resume() {
        lock.withLock { if _state == .paused { _state = .recording } }
    }

    /// Stops and finalizes. The file was readable before this; this tidies it.
    @discardableResult
    public func finish() -> TimeInterval {
        stopDevice()
        return lock.withLock {
            let length = writer?.finish() ?? 0
            writer = nil
            _state = .idle
            return length
        }
    }

    /// Stops and deletes what was written.
    public func cancel() {
        stopDevice()
        lock.withLock {
            writer?.abandon()
            writer = nil
            _state = .idle
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// The device is stopped before the lock is taken, so a callback already
    /// running finishes rather than deadlocking against it.
    private func stopDevice() {
        let shouldStop = lock.withLock { deviceOpen }
        guard shouldStop else { return }
        ma_device_stop(&device)
        ma_device_uninit(&device)
        lock.withLock { deviceOpen = false }
    }

    // MARK: - The capture callback

    /// Called on miniaudio's own thread, for every block the device delivers.
    private func captured(_ samples: UnsafePointer<Float>, _ count: Int) {
        let buffer = UnsafeBufferPointer(start: samples, count: count)

        // Measured whether or not it is being written, so a paused meter shows
        // the room rather than freezing.
        var peak: Float = 0
        for sample in buffer { peak = max(peak, abs(sample)) }
        let decibels = peak > 0 ? Double(20 * log10(peak)) : -160

        lock.lock()
        _level = decibels
        let writing = _state == .recording
        let target = writer
        lock.unlock()

        guard writing, let target else { return }
        do {
            try target.append(buffer)
        } catch {
            let reason = (error as? VoxScriptaError)?.errorDescription
                ?? error.localizedDescription
            lock.withLock { if _failure == nil { _failure = reason } }
        }
    }

    deinit {
        stopDevice()
        lock.withLock { writer?.abandon() }
    }
}
