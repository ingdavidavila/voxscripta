import Foundation
import AVFoundation
import VoxVerbaCore

/// Container formats the decoder is required to handle (§33).
public enum TestAudioFormat: String, Sendable, CaseIterable {
    case wav
    case caf
    case m4a
    case aiff

    public var fileExtension: String { rawValue }

    /// Whether the encoder is lossy, which matters when asserting on decoded values.
    public var isLossy: Bool { self == .m4a }

    var settings: [String: Any] {
        switch self {
        case .wav:
            [AVFormatIDKey: kAudioFormatLinearPCM,
             AVLinearPCMBitDepthKey: 16,
             AVLinearPCMIsFloatKey: false,
             AVLinearPCMIsBigEndianKey: false]
        case .aiff:
            [AVFormatIDKey: kAudioFormatLinearPCM,
             AVLinearPCMBitDepthKey: 16,
             AVLinearPCMIsFloatKey: false,
             AVLinearPCMIsBigEndianKey: true]
        case .caf:
            [AVFormatIDKey: kAudioFormatLinearPCM,
             AVLinearPCMBitDepthKey: 32,
             AVLinearPCMIsFloatKey: true,
             AVLinearPCMIsBigEndianKey: false]
        case .m4a:
            [AVFormatIDKey: kAudioFormatMPEG4AAC]
        }
    }
}

/// Writes rendered samples to a real audio file.
///
/// Test fixtures are produced through AVFoundation's own encoders rather than
/// hand-built headers, so the decoder is exercised against files of the same kind
/// it will meet in use.
public enum AudioFileWriter {

    /// Writes mono float samples as `format` at `sampleRate`.
    ///
    /// - Parameter channels: 1 or 2. Stereo duplicates the mono signal, which is
    ///   what a mono recording saved as stereo actually looks like.
    public static func write(
        samples: [Float],
        to url: URL,
        format: TestAudioFormat,
        sampleRate: Int,
        channels: Int = 1
    ) throws {
        precondition(channels == 1 || channels == 2, "channels must be 1 or 2")
        guard !samples.isEmpty else {
            throw VoxVerbaError.ioFailure(path: url.path, reason: "no samples to write")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw VoxVerbaError.ioFailure(path: url.path, reason: "could not build the source format")
        }

        var settings = format.settings
        settings[AVSampleRateKey] = Double(sampleRate)
        settings[AVNumberOfChannelsKey] = channels

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw VoxVerbaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }

        // Written in blocks so fixture generation has the same bounded footprint
        // as the decoder it feeds.
        let blockSize = 1 << 16
        var offset = 0
        while offset < samples.count {
            let n = min(blockSize, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                frameCapacity: AVAudioFrameCount(n)) else {
                throw VoxVerbaError.ioFailure(path: url.path, reason: "could not allocate a write buffer")
            }
            buffer.frameLength = AVAudioFrameCount(n)
            guard let data = buffer.floatChannelData else {
                throw VoxVerbaError.ioFailure(path: url.path, reason: "buffer has no float storage")
            }
            for c in 0..<channels {
                samples.withUnsafeBufferPointer { src in
                    data[c].update(from: src.baseAddress! + offset, count: n)
                }
            }
            do {
                try file.write(from: buffer)
            } catch {
                throw VoxVerbaError.ioFailure(path: url.path, reason: error.localizedDescription)
            }
            offset += n
        }
    }

    /// Renders a corpus case straight to a file. Returns the ground truth alongside.
    @discardableResult
    public static func write(
        _ testCase: CorpusCase,
        to directory: URL,
        format: TestAudioFormat = .wav,
        sampleRate: Int = CanonicalFormat.sampleRate,
        channels: Int = 1
    ) throws -> URL {
        let url = directory.appending(path: "\(testCase.name).\(format.fileExtension)")
        try write(samples: testCase.render(sampleRate: sampleRate), to: url,
                  format: format, sampleRate: sampleRate, channels: channels)
        return url
    }
}
