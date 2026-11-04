import Foundation
import CFFmpeg
import VoxScriptaCore

/// Writes captured audio to a fragmented m4a that survives the process dying.
///
/// The same promise, and deliberately the same file format, as the Apple
/// recorder: AAC in an MPEG-4 container whose index is written as it goes,
/// every ``fragmentSeconds``, so a file that is never finalized is still
/// playable up to the last completed fragment. A recording made on Android or
/// Windows is then the same kind of file as one made on a Mac, readable by
/// either, and loses the same couple of seconds to a crash rather than
/// everything.
///
/// Separated from the microphone on purpose. Capture needs a device and
/// cannot be tested on a machine without one; this half takes samples from
/// anywhere, so the property that matters — a half-written file still reads —
/// is tested with synthesized audio instead of asserted.
public final class FragmentedWriter: @unchecked Sendable {

    /// How often the index is flushed, and so the most a crash can cost.
    public static let fragmentSeconds = 2.0

    /// AAC consumes exactly this many samples per frame.
    private static let frameSize = 1024

    public let url: URL
    public let sampleRate: Int

    private var format: UnsafeMutablePointer<AVFormatContext>?
    private var codec: UnsafeMutablePointer<AVCodecContext>?
    private var stream: UnsafeMutablePointer<AVStream>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?

    /// Samples waiting for a full AAC frame.
    private var pending: [Float] = []
    private var framesWritten: Int64 = 0
    private let lock = NSLock()
    private var open = false

    /// - Parameters:
    ///   - url: Where to write. The extension decides nothing; the muxer is
    ///     always MPEG-4.
    ///   - sampleRate: Of the samples that will be handed over.
    ///   - bitRate: 64 kbit/s mono, matching the Apple recorder, which is far
    ///     beyond what the 16 kHz pipeline uses and still small enough that an
    ///     hour is about 30 MB.
    ///   - fragmenting: Off only for the test that shows what an
    ///     unfragmented file does when it is abandoned, which is what makes
    ///     the crash-safety test a measurement rather than an assertion.
    public init(url: URL, sampleRate: Int = 44_100, bitRate: Int = 64_000,
                fragmenting: Bool = true) throws {
        self.url = url
        self.sampleRate = sampleRate

        guard let encoder = avcodec_find_encoder(AV_CODEC_ID_AAC) else {
            throw VoxScriptaError.recordingFailed(
                reason: "this build has no AAC encoder")
        }
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&formatContext, nil, "ipod", url.path) >= 0,
              let formatContext else {
            throw VoxScriptaError.recordingFailed(reason: "could not create an MPEG-4 writer")
        }
        self.format = formatContext

        guard let newStream = avformat_new_stream(formatContext, nil),
              let codecContext = avcodec_alloc_context3(encoder) else {
            throw VoxScriptaError.recordingFailed(reason: "could not create an audio stream")
        }
        self.stream = newStream
        self.codec = codecContext

        codecContext.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        codecContext.pointee.sample_rate = Int32(sampleRate)
        codecContext.pointee.bit_rate = Int64(bitRate)
        codecContext.pointee.time_base = AVRational(num: 1, den: Int32(sampleRate))
        av_channel_layout_default(&codecContext.pointee.ch_layout, 1)
        // Required when the container keeps its own header, which MPEG-4 does.
        if formatContext.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0 {
            codecContext.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        }

        guard avcodec_open2(codecContext, encoder, nil) >= 0 else {
            throw VoxScriptaError.recordingFailed(reason: "the AAC encoder would not open")
        }
        avcodec_parameters_from_context(newStream.pointee.codecpar, codecContext)
        newStream.pointee.time_base = codecContext.pointee.time_base

        guard avio_open(&formatContext.pointee.pb, url.path, AVIO_FLAG_WRITE) >= 0 else {
            throw VoxScriptaError.ioFailure(path: url.path,
                                            reason: "could not open the file for writing")
        }

        // The whole point. `empty_moov` puts an index at the front before any
        // audio exists, and `frag_duration` closes a fragment every couple of
        // seconds, so the file on disk is always a complete, readable movie
        // up to the last flush rather than becoming one at the end.
        var options: OpaquePointer?
        if fragmenting {
            av_dict_set(&options, "movflags", "empty_moov+default_base_moof", 0)
            av_dict_set_int(&options, "frag_duration",
                            Int64(Self.fragmentSeconds * 1_000_000), 0)
        }
        defer { av_dict_free(&options) }
        guard avformat_write_header(formatContext, &options) >= 0 else {
            throw VoxScriptaError.recordingFailed(reason: "could not write the file header")
        }

        guard let newFrame = av_frame_alloc(), let newPacket = av_packet_alloc() else {
            throw VoxScriptaError.recordingFailed(reason: "could not allocate an audio frame")
        }
        newFrame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        newFrame.pointee.nb_samples = Int32(Self.frameSize)
        newFrame.pointee.sample_rate = Int32(sampleRate)
        av_channel_layout_default(&newFrame.pointee.ch_layout, 1)
        guard av_frame_get_buffer(newFrame, 0) >= 0 else {
            throw VoxScriptaError.recordingFailed(reason: "could not allocate an audio buffer")
        }
        self.frame = newFrame
        self.packet = newPacket
        self.open = true
        pending.reserveCapacity(Self.frameSize * 4)
    }

    /// Seconds of audio written so far.
    public var elapsed: TimeInterval {
        lock.withLock { Double(framesWritten) / Double(sampleRate) }
    }

    // MARK: - Writing

    /// Hands over captured samples. Mono, at ``sampleRate``.
    ///
    /// Buffered into exact AAC frames, because the encoder takes 1024 samples
    /// at a time and a capture callback delivers whatever the device felt
    /// like.
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        pending.append(contentsOf: samples)
        while pending.count >= Self.frameSize {
            try encodeOneFrame(Array(pending.prefix(Self.frameSize)))
            pending.removeFirst(Self.frameSize)
        }
    }

    private func encodeOneFrame(_ samples: [Float]) throws {
        guard let frame, let codec else { return }
        guard av_frame_make_writable(frame) >= 0 else {
            throw VoxScriptaError.recordingFailed(reason: "the audio frame could not be written")
        }
        // Mono planar: one plane, so this is a straight copy.
        samples.withUnsafeBufferPointer { source in
            frame.pointee.data.0?.withMemoryRebound(
                to: Float.self, capacity: Self.frameSize
            ) { destination in
                destination.update(from: source.baseAddress!, count: Self.frameSize)
            }
        }
        frame.pointee.pts = framesWritten
        framesWritten += Int64(Self.frameSize)

        guard avcodec_send_frame(codec, frame) >= 0 else {
            throw VoxScriptaError.recordingFailed(reason: "the encoder rejected a frame")
        }
        try drainEncoder()
    }

    private func drainEncoder() throws {
        guard let codec, let packet, let format, let stream else { return }
        while true {
            let status = avcodec_receive_packet(codec, packet)
            if status == -11 /* EAGAIN */ || status == Int32(bitPattern: 0xFFFFFFFF) { break }
            guard status >= 0 else { break }
            defer { av_packet_unref(packet) }
            packet.pointee.stream_index = stream.pointee.index
            av_packet_rescale_ts(packet, codec.pointee.time_base, stream.pointee.time_base)
            guard av_interleaved_write_frame(format, packet) >= 0 else {
                throw VoxScriptaError.recordingFailed(reason: "a packet could not be written")
            }
        }
    }

    // MARK: - Finishing

    /// Flushes and finalizes. The file is readable either way; this tidies it.
    @discardableResult
    public func finish() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return Double(framesWritten) / Double(sampleRate) }

        // Pad the last partial frame rather than dropping it: AAC only takes
        // whole frames, and silently losing up to 23 milliseconds off the end
        // of every recording is the kind of thing nobody notices until the
        // timings stop lining up.
        if !pending.isEmpty {
            var last = pending
            last.append(contentsOf: [Float](repeating: 0, count: Self.frameSize - last.count))
            try? encodeOneFrame(last)
            pending.removeAll()
        }
        if let codec {
            avcodec_send_frame(codec, nil)
            try? drainEncoder()
        }
        if let format { av_write_trailer(format) }
        close()
        return Double(framesWritten) / Double(sampleRate)
    }

    /// Stops without finalizing, the way a crash would.
    ///
    /// Exposed so the property this class exists for can be tested, and used
    /// by a discarded recording, where the file is deleted straight after.
    public func abandon() {
        lock.withLock { close() }
    }

    private func close() {
        guard open else { return }
        open = false
        if let format, format.pointee.pb != nil { avio_closep(&format.pointee.pb) }
        if codec != nil { avcodec_free_context(&codec) }
        if format != nil { avformat_free_context(format) ; format = nil }
        if frame != nil { av_frame_free(&frame) }
        if packet != nil { av_packet_free(&packet) }
    }

    deinit { if open { _ = finish() } }
}
