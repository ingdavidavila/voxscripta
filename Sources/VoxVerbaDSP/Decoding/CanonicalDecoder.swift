import Foundation
import AVFoundation
import VoxVerbaCore

/// Streams a source file into the canonical 16 kHz mono float PCM representation.
///
/// This runs exactly once per project. Every later stage memory-maps the result
/// rather than decoding again, which is what keeps a six-hour recording from ever
/// existing in RAM (§21).
public protocol CanonicalDecoding: Sendable {
    /// Probes a source file's format without decoding it.
    func probe(url: URL) async throws -> AudioFormatDescription

    /// Decodes `url` into `destination` as raw 32-bit float samples.
    ///
    /// - Parameter progress: Called with `0...1` completion. Coalesced by the caller.
    /// - Returns: The number of canonical samples written.
    func decode(
        url: URL,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Int64
}

/// Decodes any AVFoundation-supported container to canonical PCM.
///
/// Memory behaviour is the point of this type. The source is read in fixed-size
/// buffers whose capacity is a function of ``bufferDuration`` alone — never of the
/// file's length — so peak footprint for a six-hour file is identical to that of a
/// six-second one. Output is appended to disk as it is produced and never
/// accumulated.
public struct CanonicalDecoder: CanonicalDecoding {
    /// How much audio is held in memory at once. Fixed, so footprint is bounded.
    public let bufferDuration: TimeInterval

    public init(bufferDuration: TimeInterval = 10) {
        precondition(bufferDuration > 0, "bufferDuration must be positive")
        self.bufferDuration = bufferDuration
    }

    // MARK: - Probe

    public func probe(url: URL) async throws -> AudioFormatDescription {
        let file = try openForReading(url)
        let f = file.fileFormat
        return AudioFormatDescription(
            sampleRate: f.sampleRate,
            channelCount: Int(f.channelCount),
            bitDepth: bitDepth(of: f),
            formatDescription: describe(f)
        )
    }

    /// The source's duration, derived from its own frame count and rate.
    public func duration(of url: URL) throws -> MediaTime {
        let file = try openForReading(url)
        guard file.fileFormat.sampleRate > 0 else {
            throw VoxVerbaError.unsupportedFormat(description: "sample rate is zero")
        }
        return MediaTime(seconds: Double(file.length) / file.fileFormat.sampleRate)
    }

    // MARK: - Decode

    public func decode(
        url: URL,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Int64 {
        let file = try openForReading(url)
        let inputFormat = file.processingFormat

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoxVerbaError.unsupportedFormat(description: describe(inputFormat))
        }
        guard file.length > 0 else {
            throw VoxVerbaError.decodingFailed(reason: "the file contains no audio frames")
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(CanonicalFormat.sampleRate),
            channels: AVAudioChannelCount(CanonicalFormat.channelCount),
            interleaved: false
        ) else {
            throw VoxVerbaError.decodingFailed(reason: "could not build the canonical output format")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw VoxVerbaError.unsupportedFormat(
                description: "no conversion path from \(describe(inputFormat)) to canonical PCM"
            )
        }
        // Multichannel sources are summed to mono rather than having one channel
        // picked, so a recording with a speaker on only the right channel is not
        // silently lost.
        converter.downmix = true

        let inputCapacity = AVAudioFrameCount(inputFormat.sampleRate * bufferDuration)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
            throw VoxVerbaError.decodingFailed(reason: "could not allocate the input buffer")
        }

        // Headroom above the nominal ratio: a sample-rate converter emits a
        // variable number of frames per call and may run slightly ahead.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * ratio) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw VoxVerbaError.decodingFailed(reason: "could not allocate the output buffer")
        }

        let writer = try SampleWriter(destination: destination)
        defer { writer.close() }

        let totalInputFrames = file.length
        let cursor = DecodeCursor(file: file, buffer: inputBuffer)
        var samplesWritten: Int64 = 0
        var lastReportedProgress = -1.0

        while true {
            try Task.checkCancellation()

            outputBuffer.frameLength = 0
            var conversionError: NSError?

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                cursor.nextBuffer(status: inputStatus)
            }

            switch status {
            case .haveData, .inputRanDry:
                if outputBuffer.frameLength > 0 {
                    samplesWritten += try writer.append(outputBuffer)
                }
                if status == .inputRanDry && cursor.exhausted {
                    return try finish(writer, samplesWritten, progress)
                }
            case .endOfStream:
                if outputBuffer.frameLength > 0 {
                    samplesWritten += try writer.append(outputBuffer)
                }
                return try finish(writer, samplesWritten, progress)
            case .error:
                throw VoxVerbaError.decodingFailed(
                    reason: conversionError?.localizedDescription ?? "the converter reported an unspecified failure"
                )
            @unknown default:
                throw VoxVerbaError.decodingFailed(reason: "the converter returned an unrecognized status")
            }

            if totalInputFrames > 0 {
                let fraction = min(Double(cursor.consumedFrames) / Double(totalInputFrames), 1)
                // Report at percent granularity; the UI coalesces further.
                if fraction - lastReportedProgress >= 0.01 {
                    lastReportedProgress = fraction
                    progress(fraction)
                }
            }
        }
    }

    private func finish(
        _ writer: SampleWriter,
        _ samplesWritten: Int64,
        _ progress: @Sendable (Double) -> Void
    ) throws -> Int64 {
        guard samplesWritten > 0 else {
            throw VoxVerbaError.decodingFailed(reason: "decoding produced no samples")
        }
        try writer.flush()
        progress(1)
        return samplesWritten
    }

    // MARK: - Helpers

    private func openForReading(_ url: URL) throws -> AVAudioFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoxVerbaError.sourceUnavailable(path: url.path)
        }
        do {
            // Read-only by construction. There is no AVAudioFile write path in
            // this codebase, which is what makes the §5 guarantee structural.
            return try AVAudioFile(forReading: url)
        } catch {
            throw VoxVerbaError.unsupportedFormat(description: error.localizedDescription)
        }
    }

    private func bitDepth(of format: AVAudioFormat) -> Int? {
        let asbd = format.streamDescription.pointee
        return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
    }

    private func describe(_ format: AVAudioFormat) -> String {
        let channels = format.channelCount == 1 ? "mono" : "\(format.channelCount)ch"
        return "\(Int(format.sampleRate)) Hz \(channels)"
    }
}

/// Mutable state shared with the converter's input block.
///
/// `AVAudioConverterInputBlock` is declared `@Sendable`, but the converter pulls
/// from it synchronously on the calling thread for the duration of
/// `convert(to:error:withInputFrom:)` — it is a pull callback, not a concurrent
/// task. Boxing the state here satisfies Sendable checking at the one place the
/// guarantee actually holds, rather than weakening it across the decoder.
private final class DecodeCursor: @unchecked Sendable {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private(set) var exhausted = false
    private(set) var consumedFrames: Int64 = 0

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.file = file
        self.buffer = buffer
    }

    /// Reads the next input buffer, reporting stream status to the converter.
    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if exhausted {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            exhausted = true
            status.pointee = .endOfStream
            return nil
        }
        if buffer.frameLength == 0 {
            exhausted = true
            status.pointee = .endOfStream
            return nil
        }
        consumedFrames += Int64(buffer.frameLength)
        status.pointee = .haveData
        return buffer
    }
}

/// Buffered writer for raw little-endian Float32 samples.
///
/// Buffering matters: without it a six-hour decode issues millions of small
/// `write(2)` calls. A reference type because it owns a file descriptor and
/// mutable buffer across the decode loop.
final class SampleWriter {
    private let handle: FileHandle
    private var pending: Data
    private let flushThreshold: Int

    init(destination: URL, flushThreshold: Int = 1 << 20) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw VoxVerbaError.ioFailure(path: destination.path, reason: "could not create the file")
        }
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw VoxVerbaError.ioFailure(path: destination.path, reason: error.localizedDescription)
        }
        self.flushThreshold = flushThreshold
        pending = Data()
        pending.reserveCapacity(flushThreshold + (1 << 16))
    }

    /// Appends a buffer's first channel. Returns the sample count written.
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) throws -> Int64 {
        let count = Int(buffer.frameLength)
        guard count > 0, let channel = buffer.floatChannelData?[0] else { return 0 }
        channel.withMemoryRebound(to: UInt8.self, capacity: count * 4) { bytes in
            pending.append(bytes, count: count * 4)
        }
        if pending.count >= flushThreshold { try flush() }
        return Int64(count)
    }

    func flush() throws {
        guard !pending.isEmpty else { return }
        do {
            try handle.write(contentsOf: pending)
        } catch {
            throw VoxVerbaError.ioFailure(path: "canonical audio", reason: error.localizedDescription)
        }
        pending.removeAll(keepingCapacity: true)
    }

    func close() {
        try? flush()
        try? handle.close()
    }
}
