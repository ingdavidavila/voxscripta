import Foundation
import AVFoundation
import VoxScriptaCore

/// A passage of known text rendered to speech.
///
/// This is the other half of the corpus strategy. The signal synthesizer produces
/// audio with speech-like *acoustics* for testing the detector; this produces
/// audio with actual *words* for testing transcription. Both are generated, so
/// ground truth is exact and no human transcription or licensed recording is
/// involved.
public struct SpeechPassage: Sendable {
    public let name: String
    /// The exact words spoken, which is the reference for word error rate.
    public let text: String
    /// Seconds of silence inserted after this passage.
    public let trailingSilence: Double

    public init(name: String, text: String, trailingSilence: Double = 1.0) {
        self.name = name
        self.text = text
        self.trailingSilence = trailingSilence
    }
}

/// Renders passages to audio with `AVSpeechSynthesizer`, entirely offline.
public enum SpeechCorpus {

    /// Passages chosen to exercise what the polish validator must later protect:
    /// numbers, names, dates, negations and hedges.
    public static let standard: [SpeechPassage] = [
        SpeechPassage(
            name: "numbers",
            text: "We sold five hundred units in the third quarter, up from three hundred and twelve."),
        SpeechPassage(
            name: "names",
            text: "David met with Sarah Chen and the team from Northwind Trading on Tuesday."),
        SpeechPassage(
            name: "negation",
            text: "We did not approve the revised budget, and the committee has not scheduled a follow up."),
        SpeechPassage(
            name: "hedges",
            text: "It might be possible to finish by Friday, but I would probably plan for the following week."),
        SpeechPassage(
            name: "plain",
            text: "The quick brown fox jumps over the lazy dog near the river bank at sunrise."),
    ]

    /// Passages containing real disfluencies, for exercising the CLEAN pass.
    ///
    /// The fillers are spoken, not inserted afterwards, so the engine has to
    /// transcribe them and CLEAN has to remove them from genuine output — which
    /// is a materially different test from feeding it a hand-built transcript.
    public static let disfluent: [SpeechPassage] = [
        SpeechPassage(
            name: "fillers",
            text: "Uh, so I think we should, um, start on Monday if that works."),
        SpeechPassage(
            name: "stutter",
            text: "I, I wanted to ask about the, the budget for next quarter."),
        SpeechPassage(
            name: "mixed",
            text: "Um, we did not approve it, uh, because the numbers were wrong."),
        SpeechPassage(
            name: "affirmation",
            text: "Uh-huh, that is right, and we sold five hundred units."),
    ]

    /// The reference transcript for a set of passages, joined as spoken.
    public static func referenceText(for passages: [SpeechPassage]) -> String {
        passages.map(\.text).joined(separator: " ")
    }

    /// Renders passages to canonical-rate mono float samples.
    ///
    /// - Note: Voice availability differs between machines, so the audio is not
    ///   bit-reproducible across hosts the way the signal corpus is. Word error
    ///   rate against the known text remains exact regardless.
    public static func render(
        _ passages: [SpeechPassage],
        voiceIdentifier: String? = nil,
        rate: Float = 0.45
    ) async throws -> [Float] {
        var out: [Float] = []
        for passage in passages {
            out += try await renderOne(passage.text, voiceIdentifier: voiceIdentifier, rate: rate)
            let silence = Int(passage.trailingSilence * Double(CanonicalFormat.sampleRate))
            out += [Float](repeating: 0, count: silence)
        }
        return out
    }

    private static func renderOne(
        _ text: String,
        voiceIdentifier: String?,
        rate: Float
    ) async throws -> [Float] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }

        let collector = BufferCollector()
        let synthesizer = AVSpeechSynthesizer()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeGuard(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // A zero-length buffer is the synthesizer's end-of-stream signal.
                if pcm.frameLength == 0 {
                    resumed.resumeOnce()
                    return
                }
                collector.append(pcm)
            }
        }

        let raw = collector.samples()
        guard let format = collector.format else {
            throw VoxScriptaError.decodingFailed(reason: "the synthesizer produced no audio")
        }
        return try resample(raw, from: format.sampleRate, to: Double(CanonicalFormat.sampleRate))
    }

    /// Linear resampling to the canonical rate.
    ///
    /// Adequate here because the result is re-encoded to a real audio file and
    /// decoded through `CanonicalDecoder` before any measurement happens.
    private static func resample(_ input: [Float], from source: Double, to target: Double) throws -> [Float] {
        guard source > 0 else {
            throw VoxScriptaError.decodingFailed(reason: "the synthesizer reported a zero sample rate")
        }
        if abs(source - target) < 1 { return input }
        let ratio = source / target
        let count = Int(Double(input.count) / ratio)
        guard count > 0 else { return [] }

        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * ratio
            let low = Int(position)
            let high = Swift.min(low + 1, input.count - 1)
            let fraction = Float(position - Double(low))
            out[i] = input[low] * (1 - fraction) + input[high] * fraction
        }
        return out
    }
}

/// Accumulates synthesizer output across callbacks.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    private var captured: AVAudioFormat?

    var format: AVAudioFormat? { lock.lock(); defer { lock.unlock() }; return captured }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        captured = buffer.format
        let n = Int(buffer.frameLength)
        if let floats = buffer.floatChannelData?[0] {
            storage.append(contentsOf: UnsafeBufferPointer(start: floats, count: n))
        } else if let ints = buffer.int16ChannelData?[0] {
            storage.append(contentsOf: UnsafeBufferPointer(start: ints, count: n)
                .map { Float($0) / 32768 })
        }
    }

    func samples() -> [Float] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Ensures a continuation resumes exactly once, whatever the callback does.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resumeOnce() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
