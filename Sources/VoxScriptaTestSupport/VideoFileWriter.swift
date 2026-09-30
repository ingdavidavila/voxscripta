import AVFoundation
import CoreMedia
import Foundation

/// Writes small video files, so the video import paths can be tested for real.
///
/// The interesting cases are containers rather than codecs: a video that carries
/// audio, and one that does not. Both are generated rather than checked in,
/// because a committed binary fixture cannot be inspected in a diff and rots
/// silently when the system's encoders change.
public enum VideoFileWriter {

    /// A video file with an AAC audio track alongside the picture.
    public static func writeWithAudio(to url: URL, seconds: Double = 1) async throws {
        try await write(to: url, seconds: seconds, includeAudio: true)
    }

    /// A video file with no audio track at all — a silent screen recording.
    public static func writeSilent(to url: URL, seconds: Double = 1) async throws {
        try await write(to: url, seconds: seconds, includeAudio: false)
    }

    private static func write(to url: URL, seconds: Double, includeAudio: Bool) async throws {
        try? FileManager.default.removeItem(at: url)
        let type: AVFileType = url.pathExtension == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: type)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 120])
        video.expectsMediaDataInRealTime = false
        writer.add(video)

        var audio: AVAssetWriterInput?
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * 10)
        for i in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(i * 8 % 255),
                   CVPixelBufferGetBytesPerRow(buffer) * 120)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try await waitForInput(video, writer: writer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
        }
        video.markAsFinished()

        if let audio {
            try await waitForInput(audio, writer: writer)
            audio.append(try toneSample(seconds: seconds))
            audio.markAsFinished()
        }

        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// Waits for an input to accept data, rather than spinning forever if the
    /// writer has failed underneath us.
    private static func waitForInput(_ input: AVAssetWriterInput,
                                     writer: AVAssetWriter) async throws {
        var waited = 0
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(2))
            waited += 1
            if waited > 1_000 {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func toneSample(seconds: Double) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                   channels: 1, interleaved: false)!
        let count = AVAudioFrameCount(seconds * 44_100)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        pcm.frameLength = count
        for n in 0..<Int(count) {
            pcm.floatChannelData![0][n] = 0.3 * sinf(2 * .pi * 440 * Float(n) / 44_100)
        }

        let bytes = Int(count) * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: 0, blockBufferOut: &block)
        CMBlockBufferReplaceDataBytes(with: pcm.floatChannelData![0], blockBuffer: block!,
                                      offsetIntoDestination: 0, dataLength: bytes)

        var asbd = format.streamDescription.pointee
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description)

        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: description!,
            sampleCount: CMItemCount(count), presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }
}
