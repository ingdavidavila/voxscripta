import Testing
import Foundation
import AVFoundation
import VoxScriptaCore
@testable import VoxScriptaUI

/// The promise that a recording survives the app dying.
///
/// This is the one property worth testing here, and it is testable without a
/// microphone: synthetic audio goes through exactly the writer
/// ``RecordingSession`` uses, the writer is then abandoned the way a crash
/// abandons it — no `finishWriting`, no index — and the file still has to
/// read back as audio.
///
/// The behaviour was also confirmed the blunt way, out of process: the same
/// writer was sent SIGKILL nine seconds into a recording, and the file read
/// back as 8.03 seconds, losing only the fragment in flight. That cannot be
/// done inside a test runner without killing the runner, so it is recorded
/// here rather than automated.
@Suite("Crash-safe recording")
struct CrashSafeRecordingTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "voxscripta-crash-\(UUID().uuidString).m4a")
    }

    /// One buffer of a sine tone, in the shape a microphone would deliver.
    private func tone(at frame: Int64, frames: Int, rate: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
            let format else { return nil }

        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = 0.4 * sinf(2 * .pi * 440 * Float(Int(frame) + i) / Float(rate))
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: frames * 4, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: frames * 4,
            flags: 0, blockBufferOut: &block) == noErr,
            let block, CMBlockBufferAssureBlockMemory(block) == noErr else { return nil }
        samples.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: frames * 4)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: CMTime(value: frame, timescale: CMTimeScale(rate)),
            decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: [4],
            sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }

    /// Writes `seconds` of tone and walks away without finalizing.
    private func abandonedRecording(seconds: Double, at url: URL) throws {
        let rate = 44_100.0
        let writer = try RecordingSession.makeWriter(at: url)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: RecordingSession.encoderSettings(sampleRate: rate, channels: 1))
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let chunk = 4410                                       // 0.1 s
        var frame: Int64 = 0
        while Double(frame) / rate < seconds {
            guard let buffer = tone(at: frame, frames: chunk, rate: rate) else { break }
            while !input.isReadyForMoreMediaData { usleep(1000) }
            #expect(input.append(buffer))
            frame += Int64(chunk)
        }
        // No markAsFinished, no finishWriting: this is what a crash leaves.
    }

    @Test("A recording abandoned without finalizing is still readable")
    func abandonedFileSurvives() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try abandonedRecording(seconds: 6, at: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        // Everything but the fragment still in flight. Exact length depends on
        // where the last flush landed, so this asserts the property — most of
        // the audio is there — rather than a number that would be brittle.
        let note = "an abandoned recording read back as \(duration)s of 6s;"
            + " fragmented writing is not working, and a crash loses the lot"
        #expect(duration > 3, "\(note)")
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
    }

    @Test("The same file abandoned without fragments is unreadable")
    func theControl() async throws {
        // The other half of the measurement. Without the fragment interval
        // this is what the app used to produce, and what cost a recording:
        // a file full of audio that nothing can open.
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let rate = 44_100.0
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        // Deliberately not setting movieFragmentInterval.
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: RecordingSession.encoderSettings(sampleRate: rate, channels: 1))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var frame: Int64 = 0
        while Double(frame) / rate < 6 {
            guard let buffer = tone(at: frame, frames: 4410, rate: rate) else { break }
            while !input.isReadyForMoreMediaData { usleep(1000) }
            _ = input.append(buffer)
            frame += 4410
        }

        let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        let note = "an unfragmented abandoned file read back as \(duration)s — if this"
            + " now works, the fragment interval is no longer what saves the file"
        #expect(!(duration > 3), "\(note)")
    }

    @Test("The fragment interval is short enough to lose little")
    func fragmentIntervalIsSmall() {
        let seconds = RecordingSession.fragmentInterval.seconds
        #expect(seconds > 0)
        // A crash costs at most this much audio. Anything long enough to lose
        // a sentence defeats the point.
        #expect(seconds <= 5)
    }
}
