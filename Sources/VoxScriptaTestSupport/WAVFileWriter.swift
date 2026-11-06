import Foundation
import VoxScriptaCore

/// Writes 16-bit PCM WAVE files without AVFoundation.
///
/// The rest of the fixture writing in this target goes through AVFoundation's
/// encoders, which is the right choice on Apple's platforms: a fixture produced
/// by the system encoder is the same kind of file the decoder will meet in use.
/// It is also the reason this whole target could not be compiled for Linux, and
/// therefore the reason none of the engine's tests could run there.
///
/// WAVE is the one container simple enough to write by hand correctly, and it is
/// the format nine of the twelve call sites ask for. Writing it here buys the
/// portable test suite at the cost of about eighty lines, which is a better
/// trade than an `#if` around every test that needs a file.
///
/// Used on every platform rather than only where AVFoundation is missing. A
/// fallback that runs on one platform and not the other is a fallback nobody
/// has tested; one path, exercised everywhere, is worth more than byte-identical
/// continuity with the encoder this replaces.
public enum WAVFileWriter {

    /// Writes mono float samples as 16-bit little-endian PCM.
    ///
    /// - Parameter channels: 1 or 2. Stereo duplicates the mono signal, which is
    ///   what a mono recording saved as stereo actually looks like.
    public static func write(
        samples: [Float],
        to url: URL,
        sampleRate: Int,
        channels: Int = 1
    ) throws {
        precondition(channels == 1 || channels == 2, "channels must be 1 or 2")
        guard !samples.isEmpty else {
            throw VoxScriptaError.ioFailure(path: url.path, reason: "no samples to write")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        let dataBytes = samples.count * blockAlign

        var header = Data(capacity: 44)
        header.append(ascii: "RIFF")
        header.append(le: UInt32(36 + dataBytes))     // everything after this field
        header.append(ascii: "WAVE")
        header.append(ascii: "fmt ")
        header.append(le: UInt32(16))                 // PCM fmt chunk is 16 bytes
        header.append(le: UInt16(1))                  // 1 = integer PCM
        header.append(le: UInt16(channels))
        header.append(le: UInt32(sampleRate))
        header.append(le: UInt32(sampleRate * blockAlign))
        header.append(le: UInt16(blockAlign))
        header.append(le: UInt16(bitsPerSample))
        header.append(ascii: "data")
        header.append(le: UInt32(dataBytes))

        guard FileManager.default.createFile(atPath: url.path, contents: header) else {
            throw VoxScriptaError.ioFailure(path: url.path, reason: "could not create the file")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
        } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }

        // Written in blocks so fixture generation has the same bounded footprint
        // as the decoder it feeds.
        let blockSize = 1 << 16
        var offset = 0
        while offset < samples.count {
            let n = min(blockSize, samples.count - offset)
            var block = Data(capacity: n * blockAlign)
            for i in offset..<(offset + n) {
                // Round to nearest and clamp: the same quantisation the system
                // encoder applies, written out so it is visible.
                let scaled = (samples[i] * 32767).rounded()
                let value = Int16(scaled.clamped(to: -32768 ... 32767))
                for _ in 0..<channels { block.append(le: UInt16(bitPattern: value)) }
            }
            do {
                try handle.write(contentsOf: block)
            } catch {
                throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
            }
            offset += n
        }
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func append(le value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(le value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
