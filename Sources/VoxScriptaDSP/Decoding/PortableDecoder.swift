import Foundation
import CMiniaudio
import VoxScriptaCore

/// Decoding without AVFoundation, for the platforms that do not have it.
///
/// miniaudio does three jobs that would otherwise be three dependencies: it
/// reads the container, resamples to 16 kHz, and mixes down to mono. Since the
/// canonical format is exactly that, a decode here is one configured
/// `ma_decoder` and a loop, with no conversion code of this project's own to
/// get wrong.
///
/// The memory promise is the same one ``CanonicalDecoder`` makes and the
/// reason that promise exists: frames are pulled in fixed-size blocks whose
/// size depends on ``bufferDuration`` and never on the file's length, and
/// output is appended to disk as it is produced. A six-hour recording costs
/// what a six-second one costs.
///
/// **What it does not read.** wav, flac and mp3, and nothing else. AAC in an
/// m4a, and audio inside mp4 or mov, need a decoder miniaudio does not carry.
/// That matters because the app records m4a on Apple platforms, so a recording
/// made on a Mac cannot be opened by this decoder. Closing that gap means
/// FFmpeg or a per-platform system decoder, which is a decision with licensing
/// and size attached rather than a missing function.
public struct PortableDecoder: CanonicalDecoding {

    /// How much audio is held in memory at once. Fixed, so footprint is bounded.
    public let bufferDuration: TimeInterval

    public init(bufferDuration: TimeInterval = 10) {
        precondition(bufferDuration > 0, "bufferDuration must be positive")
        self.bufferDuration = bufferDuration
    }

    /// Containers this decoder can open.
    ///
    /// Stated as a set rather than discovered, because unlike AVFoundation
    /// there is no system to ask — miniaudio's decoders are compiled in and
    /// this is the list of them.
    public static let readableExtensions: Set<String> = ["wav", "wave", "flac", "mp3"]

    public static func canRead(_ url: URL) -> Bool {
        readableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Probe

    public func probe(url: URL) async throws -> AudioFormatDescription {
        let decoder = try Decoder(url: url, canonical: false)
        defer { decoder.close() }
        return AudioFormatDescription(
            sampleRate: Double(decoder.sampleRate),
            channelCount: Int(decoder.channels),
            bitDepth: nil,
            formatDescription: "\(decoder.sampleRate) Hz "
                + (decoder.channels == 1 ? "mono" : "\(decoder.channels) channels"))
    }

    /// How long the recording is, without decoding it.
    public func duration(of url: URL) throws -> MediaTime {
        let decoder = try Decoder(url: url, canonical: false)
        defer { decoder.close() }
        var frames: ma_uint64 = 0
        guard ma_decoder_get_length_in_pcm_frames(&decoder.handle, &frames) == MA_SUCCESS,
              frames > 0 else {
            // Some streams do not carry a length. Saying so is better than
            // returning zero, which reads as an empty recording.
            throw VoxScriptaError.decodingFailed(
                reason: "the length of \(url.lastPathComponent) is not recorded in the file")
        }
        return MediaTime(samples: Int64(frames), sampleRate: Int(decoder.sampleRate))
    }

    // MARK: - Decode

    public func decode(
        url: URL,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let decoder = try Decoder(url: url, canonical: true)
        defer { decoder.close() }

        // Total frames in canonical terms, for progress. Absent on some
        // streams, in which case progress stays at zero until the end rather
        // than being invented.
        var totalFrames: ma_uint64 = 0
        _ = ma_decoder_get_length_in_pcm_frames(&decoder.handle, &totalFrames)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = FileHandle(forWritingAtPath: destination.path) else {
            throw VoxScriptaError.ioFailure(path: destination.path,
                                            reason: "could not open the destination for writing")
        }
        defer { try? output.close() }

        let blockFrames = Int(bufferDuration * Double(CanonicalFormat.sampleRate))
        var block = [Float](repeating: 0, count: blockFrames)
        var written: Int64 = 0

        while true {
            try Task.checkCancellation()
            var read: ma_uint64 = 0
            let status = block.withUnsafeMutableBufferPointer { buffer in
                ma_decoder_read_pcm_frames(&decoder.handle, buffer.baseAddress,
                                           ma_uint64(blockFrames), &read)
            }
            // MA_AT_END arrives with the last partial block, so the frames it
            // carries are written before stopping.
            guard status == MA_SUCCESS || status == MA_AT_END else {
                throw VoxScriptaError.decodingFailed(
                    reason: "miniaudio returned \(status.rawValue) reading "
                        + url.lastPathComponent)
            }
            if read > 0 {
                let count = Int(read)
                let data = block.withUnsafeBufferPointer {
                    Data(buffer: UnsafeBufferPointer(start: $0.baseAddress, count: count))
                }
                do { try output.write(contentsOf: data) } catch {
                    throw VoxScriptaError.ioFailure(path: destination.path,
                                                    reason: error.localizedDescription)
                }
                written += Int64(count)
                if totalFrames > 0 {
                    progress(min(1, Double(written) / Double(totalFrames)))
                }
            }
            if status == MA_AT_END || read == 0 { break }
        }

        guard written > 0 else {
            throw VoxScriptaError.decodingFailed(reason: "the file contains no audio frames")
        }
        progress(1)
        return written
    }

    // MARK: - The decoder handle

    /// Owns one `ma_decoder` and makes its failures legible.
    ///
    /// A class because `ma_decoder` must not be copied — miniaudio keeps
    /// pointers into it — and because `close` has to happen exactly once.
    private final class Decoder {
        var handle = ma_decoder()
        let sampleRate: UInt32
        let channels: UInt32
        private var open = false

        /// - Parameter canonical: when true the decoder converts on the way
        ///   out, so reads return 16 kHz mono float whatever the file is.
        init(url: URL, canonical: Bool) throws {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VoxScriptaError.sourceUnavailable(path: url.path)
            }
            var config = canonical
                ? ma_decoder_config_init(ma_format_f32,
                                         ma_uint32(CanonicalFormat.channelCount),
                                         ma_uint32(CanonicalFormat.sampleRate))
                : ma_decoder_config_init(ma_format_f32, 0, 0)

            let status = ma_decoder_init_file(url.path, &config, &handle)
            guard status == MA_SUCCESS else {
                // The common case by far is a container miniaudio was not
                // built with, which is worth saying plainly rather than
                // reporting as a damaged file.
                if !PortableDecoder.canRead(url) {
                    throw VoxScriptaError.unsupportedContainer(
                        fileExtension: url.pathExtension.lowercased())
                }
                throw VoxScriptaError.decodingFailed(
                    reason: "\(url.lastPathComponent) could not be opened "
                        + "(miniaudio \(status.rawValue))")
            }
            open = true
            // Read back what the decoder settled on rather than assuming: in
            // canonical mode these are the requested values, and in probe mode
            // they are the file's own.
            var format = ma_format_unknown
            var channelCount: ma_uint32 = 0
            var rate: ma_uint32 = 0
            ma_decoder_get_data_format(&handle, &format, &channelCount, &rate, nil, 0)
            self.channels = channelCount
            self.sampleRate = rate
        }

        func close() {
            if open { ma_decoder_uninit(&handle); open = false }
        }

        deinit { close() }
    }
}
