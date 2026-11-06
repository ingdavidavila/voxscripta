import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
import VoxScriptaCore

/// Container formats the decoder is required to handle (§33).
public enum TestAudioFormat: String, Sendable, CaseIterable {
    case wav
    case caf
    case m4a
    case aiff
    case flac
    /// Raw AAC in an ADTS stream, which is a different container from `.m4a`.
    case aac

    public var fileExtension: String { rawValue }

    /// Whether the encoder is lossy, which matters when asserting on decoded values.
    public var isLossy: Bool { self == .m4a || self == .aac }

    /// Whether a fixture in this format can be written without AVFoundation.
    ///
    /// Only WAVE, which `WAVFileWriter` encodes directly. The other five are
    /// written by AVFoundation's encoders and so exist only on Apple's
    /// platforms; `AudioFileWriter` throws for them elsewhere rather than
    /// silently substituting a different container. The gap is real and is
    /// recorded in Docs/PARITY.md: off Apple, the decoder is covered against
    /// WAVE fixtures and against whatever real files are supplied by hand.
    public var isPortable: Bool { self == .wav }

    /// The formats a fixture can be written in on the platform being compiled for.
    public static var available: [TestAudioFormat] {
        #if canImport(AVFoundation)
        allCases
        #else
        allCases.filter(\.isPortable)
        #endif
    }
}

/// Formats macOS can decode but not encode.
///
/// There is no MP3 encoder on macOS, in any container — `afconvert` refuses it
/// and `AVAudioFile` has no format for it. An MP3 fixture therefore cannot be
/// synthesized the way every other fixture in this project is, so MP3 decoding
/// is covered only when a real file is supplied. See `DecoderTests`.
public enum DecodeOnlyFormat: String, Sendable, CaseIterable {
    case mp3

    /// Where a hand-supplied fixture is looked for.
    public static func fixture(named name: String, in directory: URL) -> URL? {
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Writes rendered samples to a real audio file.
///
/// Compressed fixtures are produced through AVFoundation's own encoders rather
/// than hand-built headers, so the decoder is exercised against files of the
/// same kind it will meet in use. WAVE is written directly by
/// `WAVFileWriter`, on every platform, which is what allows the engine's tests
/// to run where AVFoundation does not exist.
public enum AudioFileWriter {

    /// Writes mono float samples as `format` at `sampleRate`.
    ///
    /// - Parameter channels: 1 or 2. Stereo duplicates the mono signal, which is
    ///   what a mono recording saved as stereo actually looks like.
    /// - Throws: `VoxScriptaError.ioFailure` if `format` has no encoder on this
    ///   platform. Check `TestAudioFormat.isPortable` to skip rather than fail.
    public static func write(
        samples: [Float],
        to url: URL,
        format: TestAudioFormat,
        sampleRate: Int,
        channels: Int = 1
    ) throws {
        precondition(channels == 1 || channels == 2, "channels must be 1 or 2")

        if format == .wav {
            try WAVFileWriter.write(samples: samples, to: url,
                                    sampleRate: sampleRate, channels: channels)
            return
        }

        #if canImport(AVFoundation)
        try writeWithAVFoundation(samples: samples, to: url, format: format,
                                  sampleRate: sampleRate, channels: channels)
        #else
        throw VoxScriptaError.ioFailure(
            path: url.path,
            reason: "no \(format.rawValue) encoder on this platform; AVFoundation writes it")
        #endif
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

#if canImport(AVFoundation)
extension TestAudioFormat {
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
        case .flac:
            [AVFormatIDKey: kAudioFormatFLAC]
        case .aac:
            [AVFormatIDKey: kAudioFormatMPEG4AAC]
        }
    }
}

extension AudioFileWriter {
    fileprivate static func writeWithAVFoundation(
        samples: [Float],
        to url: URL,
        format: TestAudioFormat,
        sampleRate: Int,
        channels: Int
    ) throws {
        guard !samples.isEmpty else {
            throw VoxScriptaError.ioFailure(path: url.path, reason: "no samples to write")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw VoxScriptaError.ioFailure(path: url.path, reason: "could not build the source format")
        }

        var settings = format.settings
        settings[AVSampleRateKey] = Double(sampleRate)
        settings[AVNumberOfChannelsKey] = channels

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }

        // Written in blocks so fixture generation has the same bounded footprint
        // as the decoder it feeds.
        let blockSize = 1 << 16
        var offset = 0
        while offset < samples.count {
            let n = min(blockSize, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                frameCapacity: AVAudioFrameCount(n)) else {
                throw VoxScriptaError.ioFailure(path: url.path, reason: "could not allocate a write buffer")
            }
            buffer.frameLength = AVAudioFrameCount(n)
            guard let data = buffer.floatChannelData else {
                throw VoxScriptaError.ioFailure(path: url.path, reason: "buffer has no float storage")
            }
            for c in 0..<channels {
                samples.withUnsafeBufferPointer { src in
                    data[c].update(from: src.baseAddress! + offset, count: n)
                }
            }
            do {
                try file.write(from: buffer)
            } catch {
                throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
            }
            offset += n
        }
    }
}
#endif
