import Foundation
import AVFoundation
import VoxScriptaCore

/// Where a moment in the rendered audio came from in the original.
///
/// §7 asks that removing silence not destroy the structure of a recording. The
/// audio itself cannot carry that, so the map ships beside it: every rendered
/// span records the original span it came from, and the gap that was cut before
/// it. Anyone working from the shortened file can still say where they are in
/// the source.
public struct SilenceRemovalMap: Sendable, Codable {
    public struct Span: Sendable, Codable {
        /// Where this speech sits in the rendered file.
        public let rendered: TimeRange
        /// Where it came from in the original recording.
        public let original: TimeRange
        /// Silence removed immediately before it.
        public let removedBefore: MediaTime

        public init(rendered: TimeRange, original: TimeRange, removedBefore: MediaTime) {
            self.rendered = rendered
            self.original = original
            self.removedBefore = removedBefore
        }
    }

    public let spans: [Span]
    public let originalDuration: MediaTime
    public let renderedDuration: MediaTime
    /// Length of the fade applied at each join.
    public let crossfade: MediaTime

    public init(spans: [Span], originalDuration: MediaTime,
                renderedDuration: MediaTime, crossfade: MediaTime) {
        self.spans = spans
        self.originalDuration = originalDuration
        self.renderedDuration = renderedDuration
        self.crossfade = crossfade
    }

    public var removedDuration: MediaTime { originalDuration - renderedDuration }

    /// Maps a position in the rendered file back to the original recording.
    public func originalTime(forRendered time: MediaTime) -> MediaTime? {
        for span in spans where span.rendered.contains(time) {
            return span.original.start + (time - span.rendered.start)
        }
        return spans.last.map { $0.original.end }
    }
}

/// Writes a copy of a recording with the detected silence removed.
///
/// The architecture calls silence removal non-destructive and skips silence
/// during scheduling rather than splicing audio, because splicing hurts
/// transcription. This is the explicit, opt-in artifact for users who want the
/// shortened file for its own sake — a two-hour interview to listen back to, say.
///
/// Two things make it more than a naive splice. It reads the **original** file
/// rather than the 16 kHz mono analysis copy, so the result keeps the recording's
/// own sample rate and channels. And each join is crossfaded, because butting two
/// waveform segments together at arbitrary phase produces an audible click at
/// every cut.
///
/// - Important: The original is opened read-only and a new file is written. §5
///   holds here as everywhere.
public struct SilenceRemovalRenderer: Sendable {
    /// Fade applied either side of every join.
    public let crossfade: MediaTime

    public init(crossfade: MediaTime = .milliseconds(8)) {
        self.crossfade = crossfade
    }

    /// Renders `source` to `destination`, keeping only the speech in `map`.
    @discardableResult
    public func render(
        source: URL,
        to destination: URL,
        using map: SilenceMap,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> SilenceRemovalMap {
        guard !map.speechRegions.isEmpty else { throw VoxScriptaError.noSpeechDetected }

        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw VoxScriptaError.unsupportedFormat(description: error.localizedDescription)
        }
        let format = input.processingFormat
        let rate = Int(format.sampleRate)
        guard rate > 0 else {
            throw VoxScriptaError.unsupportedFormat(description: "the source has no sample rate")
        }

        // Written in the source's own sample rate and channel count, so the
        // shortened copy sounds like the recording rather than like the
        // analysis representation.
        let output = try makeOutput(at: destination, matching: input)

        let fadeFrames = Int(crossfade.samples(at: rate))
        var spans: [SilenceRemovalMap.Span] = []
        var renderedFrames: Int64 = 0
        var previousEnd = MediaTime.zero

        for (index, region) in map.speechRegions.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(map.speechRegions.count))

            let startFrame = region.range.start.samples(at: rate)
            let endFrame = Swift.min(region.range.end.samples(at: rate), input.length)
            let frameCount = endFrame - startFrame
            guard frameCount > 0 else { continue }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
                throw VoxScriptaError.ioFailure(path: destination.path,
                                              reason: "could not allocate a render buffer")
            }
            input.framePosition = startFrame
            do {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
            } catch {
                throw VoxScriptaError.decodingFailed(reason: error.localizedDescription)
            }
            guard buffer.frameLength > 0 else { continue }

            // Fade in at every join but the first, and out at every join but the
            // last. Without this each cut is an audible click.
            applyFades(to: buffer,
                       fadeIn: index > 0 ? fadeFrames : 0,
                       fadeOut: index < map.speechRegions.count - 1 ? fadeFrames : 0)

            do {
                try output.write(from: buffer)
            } catch {
                throw VoxScriptaError.ioFailure(path: destination.path,
                                              reason: error.localizedDescription)
            }

            let renderedStart = MediaTime(samples: renderedFrames, sampleRate: rate)
            renderedFrames += Int64(buffer.frameLength)
            spans.append(SilenceRemovalMap.Span(
                rendered: TimeRange(start: renderedStart,
                                    end: MediaTime(samples: renderedFrames, sampleRate: rate)),
                original: region.range,
                removedBefore: Swift.max(region.range.start - previousEnd, .zero)))
            previousEnd = region.range.end
        }

        guard renderedFrames > 0 else {
            throw VoxScriptaError.noSpeechDetected
        }
        progress(1)

        return SilenceRemovalMap(
            spans: spans,
            originalDuration: map.sourceDuration,
            renderedDuration: MediaTime(samples: renderedFrames, sampleRate: rate),
            crossfade: crossfade)
    }

    // MARK: - Helpers

    private func makeOutput(at destination: URL, matching input: AVAudioFile) throws -> AVAudioFile {
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)

        // Lossless, so the shortened copy is not a second generation of lossy
        // encoding on top of whatever the source already was — but at the
        // source's own bit depth rather than a fixed 24. Forcing 24-bit made a
        // shortened copy of a 16-bit recording *larger* than the original, which
        // is a confusing thing to hand someone who asked to remove silence.
        let sourceDepth = input.fileFormat.streamDescription.pointee.mBitsPerChannel
        let depth = sourceDepth >= 16 && sourceDepth <= 32 ? Int(sourceDepth) : 24
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: Int(input.processingFormat.channelCount),
            AVLinearPCMBitDepthKey: depth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            return try AVAudioFile(forWriting: destination, settings: settings,
                                   commonFormat: input.processingFormat.commonFormat,
                                   interleaved: input.processingFormat.isInterleaved)
        } catch {
            throw VoxScriptaError.ioFailure(path: destination.path,
                                          reason: error.localizedDescription)
        }
    }

    /// Applies linear fades to the head and tail of a buffer, in place.
    private func applyFades(to buffer: AVAudioPCMBuffer, fadeIn: Int, fadeOut: Int) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        let head = Swift.min(fadeIn, frames / 2)
        let tail = Swift.min(fadeOut, frames / 2)

        for channel in 0..<channelCount {
            let samples = channels[channel]
            for i in 0..<head {
                samples[i] *= Float(i) / Float(head)
            }
            for i in 0..<tail {
                samples[frames - 1 - i] *= Float(i) / Float(tail)
            }
        }
    }
}
