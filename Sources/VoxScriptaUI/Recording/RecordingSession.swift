import AVFoundation
import Foundation
import VoxScriptaCore

/// Captures the microphone to a file that stays readable if the app dies.
///
/// This replaced `AVAudioRecorder`, which writes the MPEG-4 index only when it
/// is stopped cleanly. Anything else — a crash, a force quit, a flat battery —
/// left a file full of audio and no way to read it: measured, a 2.4 MB
/// recording that `afinfo` reported as having no duration at all. For a
/// feature whose point is recording a two-hour lecture, losing the lecture
/// because the app died at minute 119 is not an acceptable failure.
///
/// So the writing goes through `AVAssetWriter` with `movieFragmentInterval`
/// set. The index is written incrementally, every ``fragmentInterval``, and a
/// file that is never finalized is still playable up to the last completed
/// fragment. Verified by killing the writer with SIGKILL nine seconds in: the
/// file read back as 8.03 seconds of audio, and this project's own decoder
/// opened it.
///
/// Everything here runs off the main actor. Sample buffers arrive on
/// ``queue`` and are written there; the observable values are read from the
/// main actor through a lock. `@unchecked Sendable` because that locking is
/// done by hand — `AVAssetWriter` and `CMSampleBuffer` are not `Sendable`, and
/// they never leave this class.
final class RecordingSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
                              @unchecked Sendable {

    /// How often the index is flushed, and therefore the most that a crash
    /// can cost.
    ///
    /// Two seconds. Small enough that nobody minds losing it, large enough
    /// that an hour of recording adds under two thousand fragment headers.
    static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

    let url: URL

    private let queue = DispatchQueue(label: "com.voxscripta.recording", qos: .userInitiated)
    private let session = AVCaptureSession()
    /// Both are touched only on ``queue``. Nothing here is `Sendable`, and
    /// the class is `@unchecked`, so that confinement is the whole of the
    /// safety argument — an access from anywhere else is a race the compiler
    /// will not report.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    private let lock = NSLock()
    private var _elapsed: TimeInterval = 0
    /// Decibels full scale. Starts at the floor, not at zero: zero is *full
    /// scale*, so an unstarted meter would read as a pegged one.
    private var _level: Double = -160
    private var _isPaused = false
    private var _failure: String?

    /// Timeline bookkeeping, touched only on ``queue``.
    private var firstSample: CMTime?
    private var pausedTotal: CMTime = .zero
    private var pauseBegan: CMTime?

    init(url: URL) {
        self.url = url
        super.init()
    }

    // MARK: - Values the interface reads

    var elapsed: TimeInterval { lock.withLock { _elapsed } }
    var level: Double { lock.withLock { _level } }
    /// Set when the writer failed mid-recording, so the UI can say so instead
    /// of showing a clock that has quietly stopped.
    var failure: String? { lock.withLock { _failure } }

    // MARK: - Transport

    /// Opens the microphone and begins writing. Blocks; never call it on the
    /// main thread.
    func start() throws {
        #if os(iOS) || os(visionOS)
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
        } catch {
            throw VoxScriptaError.recordingFailed(reason: error.localizedDescription)
        }
        #endif

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw VoxScriptaError.recordingFailed(
                reason: String(localized: "no microphone is available"))
        }
        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw VoxScriptaError.recordingFailed(reason: error.localizedDescription)
        }

        let output = AVCaptureAudioDataOutput()
        // Left at the device's own format on purpose. Asking the capture
        // output to convert is supported unevenly across the two platforms,
        // and the writer is told to encode whatever actually arrives.
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw VoxScriptaError.recordingFailed(
                reason: String(localized: "the microphone could not be opened"))
        }
        session.addInput(deviceInput)
        session.addOutput(output)
        session.commitConfiguration()

        do {
            let made = try Self.makeWriter(at: url)
            queue.sync { self.writer = made }
        } catch {
            throw VoxScriptaError.recordingFailed(reason: error.localizedDescription)
        }

        session.startRunning()
        guard session.isRunning else {
            throw VoxScriptaError.recordingFailed(
                reason: String(localized: "the microphone did not start"))
        }
    }

    func pause() { lock.withLock { _isPaused = true } }
    func resume() { lock.withLock { _isPaused = false } }

    /// Stops and finalizes. The file is readable either way; this makes it tidy.
    ///
    /// `stopRunning` first, then a hop onto ``queue``: buffers already in
    /// flight are delivered there, and finishing the writer from another
    /// thread while one of them is still being appended is a race. The
    /// writer and its input are only ever touched on that queue.
    func finish() async -> TimeInterval {
        session.stopRunning()
        let writer = await withCheckedContinuation { continuation in
            queue.async {
                self.input?.markAsFinished()
                continuation.resume(returning: self.writer)
            }
        }
        if let writer, writer.status == .writing { await writer.finishWriting() }
        deactivateAudioSession()
        return elapsed
    }

    /// Stops and abandons what was written.
    func cancel() {
        session.stopRunning()
        queue.sync {
            if let writer = self.writer, writer.status == .writing { writer.cancelWriting() }
            self.writer = nil
            self.input = nil
        }
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Writing

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let writer else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // The writer's settings are built from the first buffer, so the
        // encoder is never asked to resample or downmix — whatever the device
        // produces is what gets encoded. The pipeline reduces it to 16 kHz
        // mono later anyway.
        if input == nil {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            else { return }
            let made = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.encoderSettings(sampleRate: asbd.mSampleRate,
                                                     channels: Int(asbd.mChannelsPerFrame)))
            made.expectsMediaDataInRealTime = true
            guard writer.canAdd(made) else { return }
            writer.add(made)
            guard writer.startWriting() else {
                fail(writer.error?.localizedDescription ?? "the writer would not start")
                return
            }
            writer.startSession(atSourceTime: .zero)
            input = made
            firstSample = timestamp
        }
        guard let input, let firstSample else { return }

        // Paused: drop the audio and remember when the gap started, so the
        // written timeline has no silent stretch in it and the clock does not
        // count time the recording does not contain.
        if lock.withLock({ _isPaused }) {
            if pauseBegan == nil { pauseBegan = timestamp }
            return
        }
        if let began = pauseBegan {
            pausedTotal = pausedTotal + (timestamp - began)
            pauseBegan = nil
        }

        let start = timestamp - firstSample - pausedTotal
        guard let retimed = Self.retime(sampleBuffer, to: start) else { return }
        guard input.isReadyForMoreMediaData, input.append(retimed) else {
            if writer.status == .failed {
                fail(writer.error?.localizedDescription ?? "the recording could not be written")
            }
            return
        }

        let end = (start + CMSampleBufferGetDuration(sampleBuffer)).seconds
        let measured = Self.level(of: sampleBuffer)
        lock.withLock {
            _elapsed = end.isFinite ? end : _elapsed
            if let measured { _level = measured }
        }
    }

    private func fail(_ reason: String) {
        lock.withLock { if _failure == nil { _failure = reason } }
    }

    /// The writer, configured so an unfinished file is still a readable one.
    ///
    /// Separate from `start` so a test can build the same writer without a
    /// microphone and check the property that matters, rather than checking
    /// that a constant was assigned.
    static func makeWriter(at url: URL) throws -> AVAssetWriter {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.movieFragmentInterval = fragmentInterval
        return writer
    }

    /// Moves a buffer onto the recording's own timeline.
    ///
    /// Needed because the timeline skips whatever was paused, so a buffer's
    /// capture timestamp is not where it belongs in the file.
    static func retime(_ buffer: CMSampleBuffer, to start: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(buffer),
                                        presentationTimeStamp: start,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    /// AAC at the rate and channel count the microphone actually produced.
    ///
    /// Lossy, deliberately: the pipeline resamples to 16 kHz mono before a
    /// transcriber sees any of it, so this is already far beyond what the
    /// recognition uses, while an hour of linear PCM would be 300 MB on a
    /// phone. The AAC encoder's 2112-sample priming delay is handled in the
    /// decoder, so it costs no alignment.
    static func encoderSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        // Typed locals, not expressions inside the literal. A dictionary of
        // `Any` gives each value `Any` as its contextual type, which lets an
        // integer literal in a ternary stay an `Int` even when the other
        // branch is a `Double` — so the fallback rate went in as `Int(44100)`
        // and AVFoundation would have been handed the wrong type for the one
        // input it cannot infer.
        let channels: Int = max(1, min(channels, 2))
        let rate: Double = sampleRate > 0 ? sampleRate : 44_100
        let bitRate: Int = channels == 1 ? 64_000 : 96_000
        return [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            // Speech, so generous per channel without being wasteful.
            AVEncoderBitRateKey: bitRate,
        ]
    }

    /// Peak level of a buffer, in decibels full scale, or `nil` for a format
    /// this does not know how to read.
    ///
    /// Measured here rather than asked of the capture device, because the
    /// meter now has the actual samples in hand.
    static func level(of buffer: CMSampleBuffer) -> Double? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return nil }

        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let data = list.mBuffers.mData else { return nil }
        let bytes = Int(list.mBuffers.mDataByteSize)
        var peak: Float = 0

        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 {
            let samples = data.bindMemory(to: Float.self, capacity: bytes / 4)
            for i in 0..<(bytes / 4) { peak = max(peak, abs(samples[i])) }
        } else if asbd.mBitsPerChannel == 16 {
            let samples = data.bindMemory(to: Int16.self, capacity: bytes / 2)
            for i in 0..<(bytes / 2) {
                peak = max(peak, abs(Float(samples[i])) / Float(Int16.max))
            }
        } else {
            return nil
        }
        return peak > 0 ? Double(20 * log10(peak)) : -160
    }
}
