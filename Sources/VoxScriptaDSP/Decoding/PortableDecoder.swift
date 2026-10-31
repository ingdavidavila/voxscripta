import Foundation
import CFFmpeg
import VoxScriptaCore

/// Decoding without AVFoundation, for the platforms that do not have it.
///
/// FFmpeg, built down to the containers and codecs AVFoundation reads and
/// nothing else — 2.9 MB of shared library rather than the tens of megabytes
/// a full build is. The point is parity: an m4a, an mp4's audio track, a wav,
/// an mp3 and a flac all open here, because an app that cannot read its own
/// recordings on one platform is not the same app.
///
/// This replaced a miniaudio implementation that read wav, flac and mp3 and
/// could not read AAC. That gap was not a rounding error in coverage — the app
/// records m4a, so a recording made on a Mac could not have been opened on
/// Linux.
///
/// The libraries are LGPL v2.1, built with `--disable-gpl --disable-nonfree
/// --disable-version3`, and shared rather than static so they can be replaced
/// in place. That is what keeps the licence satisfiable without publishing
/// this app's own source.
///
/// Memory behaves as it does in ``CanonicalDecoder``, and for the same reason:
/// frames are pulled a packet at a time, converted, and appended to disk. A
/// six-hour recording costs what a six-second one costs.
public struct PortableDecoder: CanonicalDecoding {

    /// How much converted audio is buffered before it is written.
    public let bufferDuration: TimeInterval

    public init(bufferDuration: TimeInterval = 10) {
        precondition(bufferDuration > 0, "bufferDuration must be positive")
        self.bufferDuration = bufferDuration
    }

    // MARK: - Probe

    public func probe(url: URL) async throws -> AudioFormatDescription {
        let source = try Source(url: url)
        defer { source.close() }
        let parameters = source.stream.pointee.codecpar!.pointee
        let name = avcodec_get_name(parameters.codec_id).map { String(cString: $0) } ?? "unknown"
        let channels = Int(parameters.ch_layout.nb_channels)
        return AudioFormatDescription(
            sampleRate: Double(parameters.sample_rate),
            channelCount: channels,
            bitDepth: parameters.bits_per_raw_sample > 0
                ? Int(parameters.bits_per_raw_sample) : nil,
            formatDescription: "\(parameters.sample_rate) Hz "
                + (channels == 1 ? "mono" : "\(channels) channels") + ", \(name)")
    }

    /// How long the recording is, without decoding it.
    public func duration(of url: URL) throws -> MediaTime {
        let source = try Source(url: url)
        defer { source.close() }
        // The stream's own duration where it has one, otherwise the
        // container's. A stream that declares neither is reported rather than
        // guessed at, because a wrong duration becomes a wrong progress bar
        // and a wrong chunk plan.
        let stream = source.stream.pointee
        if stream.duration > 0, stream.time_base.den > 0 {
            let seconds = Double(stream.duration) * Double(stream.time_base.num)
                / Double(stream.time_base.den)
            return MediaTime(seconds: seconds)
        }
        let container = source.format?.pointee.duration ?? 0
        guard container > 0 else {
            throw VoxScriptaError.decodingFailed(
                reason: "the length of \(url.lastPathComponent) is not recorded in the file")
        }
        return MediaTime(seconds: Double(container) / Double(AV_TIME_BASE))
    }

    // MARK: - Decode

    public func decode(
        url: URL,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let source = try Source(url: url)
        defer { source.close() }
        let resampler = try Resampler(from: source.stream.pointee.codecpar!)
        defer { resampler.close() }

        let total = (try? duration(of: url))?.seconds ?? 0

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw VoxScriptaError.ioFailure(path: destination.path,
                                            reason: "could not open the destination for writing")
        }
        defer { try? output.close() }

        var written: Int64 = 0
        var pending: [Float] = []
        pending.reserveCapacity(Int(bufferDuration) * CanonicalFormat.sampleRate)
        let flushAt = Int(bufferDuration * Double(CanonicalFormat.sampleRate))

        func flush() throws {
            guard !pending.isEmpty else { return }
            let data = pending.withUnsafeBufferPointer { Data(buffer: $0) }
            do { try output.write(contentsOf: data) } catch {
                throw VoxScriptaError.ioFailure(path: destination.path,
                                                reason: error.localizedDescription)
            }
            written += Int64(pending.count)
            pending.removeAll(keepingCapacity: true)
        }

        let packet = av_packet_alloc()
        let frame = av_frame_alloc()
        defer {
            var p = packet; av_packet_free(&p)
            var f = frame; av_frame_free(&f)
        }

        while av_read_frame(source.format, packet) >= 0 {
            defer { av_packet_unref(packet) }
            try Task.checkCancellation()
            guard packet!.pointee.stream_index == source.streamIndex else { continue }
            guard avcodec_send_packet(source.codec, packet) >= 0 else { continue }

            while avcodec_receive_frame(source.codec, frame) >= 0 {
                pending += try resampler.convert(frame!)
                if pending.count >= flushAt {
                    try flush()
                    if total > 0 {
                        progress(min(1, Double(written)
                                     / (total * Double(CanonicalFormat.sampleRate))))
                    }
                }
            }
        }

        // Drain: a decoder holds frames back, and the tail of the recording is
        // in them.
        avcodec_send_packet(source.codec, nil)
        while avcodec_receive_frame(source.codec, frame) >= 0 {
            pending += try resampler.convert(frame!)
        }
        pending += resampler.drain()
        try flush()

        guard written > 0 else {
            throw VoxScriptaError.decodingFailed(reason: "the file contains no audio frames")
        }
        progress(1)
        return written
    }

    // MARK: - An open file and its decoder

    /// Owns the format context and codec context for one file.
    ///
    /// A class because both are C pointers that must be freed exactly once,
    /// and because FFmpeg keeps references between them.
    private final class Source {
        var format: UnsafeMutablePointer<AVFormatContext>?
        var codec: UnsafeMutablePointer<AVCodecContext>?
        let streamIndex: Int32
        let stream: UnsafeMutablePointer<AVStream>

        init(url: URL) throws {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VoxScriptaError.sourceUnavailable(path: url.path)
            }
            var context: UnsafeMutablePointer<AVFormatContext>?
            guard avformat_open_input(&context, url.path, nil, nil) >= 0, context != nil else {
                // Almost always a container this build was not configured
                // with, which deserves the error that names the extension
                // rather than one that says the file is damaged.
                throw VoxScriptaError.unsupportedContainer(
                    fileExtension: url.pathExtension.lowercased())
            }
            guard avformat_find_stream_info(context, nil) >= 0 else {
                avformat_close_input(&context)
                throw VoxScriptaError.decodingFailed(
                    reason: "no stream information in \(url.lastPathComponent)")
            }

            var decoder: UnsafePointer<AVCodec>?
            let index = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)
            guard index >= 0, let decoder else {
                avformat_close_input(&context)
                // A video with no audio, which is a normal thing to be handed
                // and not a failure of the file.
                throw VoxScriptaError.noAudioTrack(path: url.path)
            }
            guard let codecContext = avcodec_alloc_context3(decoder) else {
                avformat_close_input(&context)
                throw VoxScriptaError.decodingFailed(reason: "could not allocate a decoder")
            }
            let streamPointer = context!.pointee.streams[Int(index)]!
            avcodec_parameters_to_context(codecContext, streamPointer.pointee.codecpar)
            guard avcodec_open2(codecContext, decoder, nil) >= 0 else {
                var c: UnsafeMutablePointer<AVCodecContext>? = codecContext
                avcodec_free_context(&c)
                avformat_close_input(&context)
                throw VoxScriptaError.unsupportedFormat(
                    description: avcodec_get_name(streamPointer.pointee.codecpar.pointee.codec_id)
                        .map { String(cString: $0) } ?? "unknown codec")
            }

            self.format = context
            self.codec = codecContext
            self.streamIndex = index
            self.stream = streamPointer
        }

        func close() {
            if codec != nil { avcodec_free_context(&codec) }
            if format != nil { avformat_close_input(&format) }
        }

        deinit { close() }
    }

    /// Converts whatever the decoder produces into canonical samples.
    ///
    /// Rate, channel count and sample format all at once, which is the whole
    /// reason swresample is linked: doing any of the three by hand is how a
    /// decoder ends up disagreeing with the platform one.
    private final class Resampler {
        private var context: OpaquePointer?

        init(from parameters: UnsafeMutablePointer<AVCodecParameters>) throws {
            var mono = AVChannelLayout()
            av_channel_layout_default(&mono, Int32(CanonicalFormat.channelCount))
            var input = parameters.pointee.ch_layout

            var created: OpaquePointer?
            let status = swr_alloc_set_opts2(
                &created,
                &mono, AV_SAMPLE_FMT_FLT, Int32(CanonicalFormat.sampleRate),
                &input, AVSampleFormat(parameters.pointee.format),
                parameters.pointee.sample_rate,
                0, nil)
            guard status >= 0, let created, swr_init(created) >= 0 else {
                throw VoxScriptaError.decodingFailed(
                    reason: "could not set up conversion to 16 kHz mono")
            }
            context = created
        }

        func convert(_ frame: UnsafeMutablePointer<AVFrame>) throws -> [Float] {
            guard let context else { return [] }
            // Delay-aware: the resampler holds samples back, so the output
            // size depends on what is already inside it as well as on what is
            // arriving.
            let delay = swr_get_delay(context, Int64(CanonicalFormat.sampleRate))
            let capacity = Int(av_rescale_rnd(
                delay + Int64(frame.pointee.nb_samples),
                Int64(CanonicalFormat.sampleRate),
                Int64(frame.pointee.sample_rate), AV_ROUND_UP))
            guard capacity > 0 else { return [] }

            // `const uint8_t * const *` on the input side against
            // `uint8_t **` on the frame: same memory, different constness,
            // so it is rebound rather than cast through UnsafePointer(),
            // which resolves to the OpaquePointer initializer instead.
            guard let planes = frame.pointee.extended_data else { return [] }
            let input = UnsafeRawPointer(planes)
                .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)

            var out = [Float](repeating: 0, count: capacity)
            let produced: Int32 = out.withUnsafeMutableBufferPointer { buffer in
                // swr_convert takes an array of plane pointers. Canonical
                // output is one interleaved mono plane, so the array has one
                // entry — but it still has to be an array.
                let planes: [UnsafeMutablePointer<UInt8>?] = [
                    UnsafeMutableRawPointer(buffer.baseAddress!)
                        .assumingMemoryBound(to: UInt8.self)
                ]
                return planes.withUnsafeBufferPointer { out in
                    swr_convert(context, out.baseAddress, Int32(capacity),
                                input, frame.pointee.nb_samples)
                }
            }
            guard produced > 0 else { return [] }
            return Array(out.prefix(Int(produced)))
        }

        /// Whatever the resampler is still holding once the input has ended.
        func drain() -> [Float] {
            guard let context else { return [] }
            let remaining = Int(swr_get_delay(context, Int64(CanonicalFormat.sampleRate)))
            guard remaining > 0 else { return [] }
            var out = [Float](repeating: 0, count: remaining)
            let produced: Int32 = out.withUnsafeMutableBufferPointer { buffer in
                let planes: [UnsafeMutablePointer<UInt8>?] = [
                    UnsafeMutableRawPointer(buffer.baseAddress!)
                        .assumingMemoryBound(to: UInt8.self)
                ]
                return planes.withUnsafeBufferPointer { out in
                    swr_convert(context, out.baseAddress, Int32(remaining), nil, 0)
                }
            }
            return produced > 0 ? Array(out.prefix(Int(produced))) : []
        }

        func close() {
            if context != nil { swr_free(&context) }
        }

        deinit { close() }
    }
}
