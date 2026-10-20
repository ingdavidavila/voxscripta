import Foundation
import AVFoundation
import CoreMedia
import Speech
import VoxScriptaCore

/// The default engine: Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+).
///
/// Chosen over Whisper for English on this platform because published independent
/// benchmarks put it ahead on word error rate at roughly three times the speed,
/// its models are managed by the OS through `AssetInventory` (so they add nothing
/// to the app bundle and need no download UI), it emits `audioTimeRange` word
/// timings that the merger and the polish validator both depend on, and it runs
/// in a system process — so ASR model memory never appears in this app's footprint
/// and an engine crash cannot take down the app.
///
/// An actor because it owns prepared model state across calls.
public actor AppleSpeechEngine: TranscriptionEngine {
    public nonisolated let identifier = EngineID.appleSpeech

    private var preparedLocale: Locale?
    /// The format the analyzer wants, discovered during `prepare`.
    private var analyzerFormat: AVAudioFormat?

    public init() {}

    public func capabilities() async -> EngineCapabilities {
        EngineCapabilities(
            supportsWordTimestamps: true,
            supportsDiarization: false,
            supportsTranslation: false,
            supportedLocales: Set(await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }),
            maximumChunkDuration: nil
        )
    }

    /// Locales whose assets are already on the machine, so no download is needed.
    public func installedLocales() async -> Set<String> {
        Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    }

    // MARK: - Preparation

    /// Locales whose models are already on this Mac.
    ///
    /// The language probe is restricted to these. Probing a locale that is
    /// merely *supported* would make the OS download a speech model as a side
    /// effect of opening a file, which is not a thing an app should do while
    /// someone waits — and not a thing this app should do at all without
    /// being asked.
    public static func installedLocaleIdentifiers() async -> Set<String> {
        Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    }

    /// Every locale this engine can transcribe, as BCP-47 identifiers.
    ///
    /// Asked of the system rather than listed, because which locales exist is
    /// not a compile-time fact — it varies by OS version and by what the user
    /// has installed.
    public static func supportedLocaleIdentifiers() async -> Set<String> {
        Set(await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) })
    }

    public func prepare(locale localeIdentifier: String) async throws {
        let locale = Locale(identifier: localeIdentifier)

        guard SpeechTranscriber.isAvailable else {
            throw VoxScriptaError.engineUnavailable(
                identifier, reason: "on-device speech recognition is unavailable on this Mac")
        }

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.matches(localeIdentifier) }) else {
            throw VoxScriptaError.localeUnsupported(identifier, locale: localeIdentifier)
        }

        let transcriber = makeTranscriber(locale: locale)

        // Assets are OS-managed. Installing them is a local operation against
        // system storage, not an app-level network fetch, and nothing about the
        // user's audio is involved.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            do {
                try await request.downloadAndInstall()
            } catch {
                throw VoxScriptaError.modelAssetMissing(
                    description: "speech assets for \(localeIdentifier): \(error.localizedDescription)")
            }
        }

        // Reserving tells the OS this locale is in use so it is not reclaimed
        // mid-job. A failure here is not fatal — it only risks a re-download.
        _ = try? await AssetInventory.reserve(locale: locale)

        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        preparedLocale = locale
    }

    public func release() async {
        if let locale = preparedLocale {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
        preparedLocale = nil
        analyzerFormat = nil
    }

    /// The audio format the analyzer asked for, once prepared.
    ///
    /// Surfaced because it is the first thing to check when a chunk transcribes
    /// only partially: a format mismatch shows up as truncation, not as an error.
    public var analyzerAudioFormat: AVAudioFormat? { analyzerFormat }

    // MARK: - Transcription

    public func transcribe(
        _ range: SampleRange,
        in canonicalFile: URL,
        options: TranscriptionOptions
    ) async throws -> [TranscriptSegment] {
        guard let locale = preparedLocale else {
            throw VoxScriptaError.engineUnavailable(identifier, reason: "prepare(locale:) was not called")
        }
        guard !range.isEmpty else { return [] }

        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let source = try CanonicalSampleReader(url: canonicalFile)
        let target = analyzerFormat
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32,
                             sampleRate: Double(CanonicalFormat.sampleRate),
                             channels: 1, interleaved: false)!

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Results are consumed concurrently with feeding, because the analyzer
        // emits as it goes and would otherwise block on a full buffer.
        async let collected: [SpeechTranscriber.Result] = {
            var out: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results {
                out.append(result)
            }
            return out
        }()

        try await analyzer.start(inputSequence: stream)

        do {
            try Self.feed(range: range, from: source, to: target, into: continuation)
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            _ = try? await collected
            throw VoxScriptaError.transcriptionFailed(
                chunk: ChunkID(), reason: error.localizedDescription)
        }

        let results: [SpeechTranscriber.Result]
        do {
            results = try await collected
        } catch {
            throw VoxScriptaError.transcriptionFailed(
                chunk: ChunkID(), reason: error.localizedDescription)
        }

        // Audio was fed starting at zero rather than at the chunk's absolute
        // position, so results come back chunk-relative and are shifted here.
        // Feeding absolute times would work too, but relative feeding keeps the
        // analyzer's internal timeline independent of where the chunk sits.
        let offset = MediaTime(samples: range.start, sampleRate: CanonicalFormat.sampleRate)
        return results.compactMap { Self.segment(from: $0, offsetBy: offset) }
    }

    // MARK: - Audio feeding

    /// Streams a sample range into the analyzer, converting to its format.
    ///
    /// The converter pulls across the whole chunk rather than being restarted per
    /// buffer. Signalling end-of-stream after each buffer terminates an
    /// `AVAudioConverter` permanently — which silently truncates a chunk to its
    /// first buffer, and looks exactly like a model that stopped listening.
    private static func feed(
        range: SampleRange,
        from source: CanonicalSampleReader,
        to target: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let rate = CanonicalFormat.sampleRate
        guard let canonical = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Double(rate),
                                            channels: 1, interleaved: false) else {
            throw VoxScriptaError.decodingFailed(reason: "could not build the canonical format")
        }

        // One second per buffer: small enough that a cancelled chunk stops
        // promptly, large enough that per-buffer overhead is irrelevant.
        let blockSamples = rate

        // Fast path: the analyzer already speaks our format.
        if canonical.isEqual(target) {
            var position = range.start
            while position < range.end {
                let count = Int(Swift.min(Int64(blockSamples), range.end - position))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: canonical,
                                                    frameCapacity: AVAudioFrameCount(count)) else {
                    throw VoxScriptaError.decodingFailed(reason: "could not allocate an input buffer")
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try source.read(into: buffer, at: position, count: count)
                let time = CMTime(value: position - range.start, timescale: CMTimeScale(rate))
                continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time))
                position += Int64(count)
            }
            return
        }

        guard let converter = AVAudioConverter(from: canonical, to: target) else {
            throw VoxScriptaError.engineUnavailable(
                .appleSpeech, reason: "no conversion path to the analyzer's audio format")
        }

        let pull = try RangeSampleSource(reader: source, range: range,
                                         format: canonical, blockSamples: blockSamples)
        let ratio = target.sampleRate / canonical.sampleRate
        let capacity = AVAudioFrameCount(Double(blockSamples) * ratio) + 1024
        var outputPosition: Int64 = 0

        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw VoxScriptaError.decodingFailed(reason: "could not allocate a converted buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                pull.next(status: inputStatus)
            }
            if status == .error {
                throw VoxScriptaError.decodingFailed(
                    reason: conversionError?.localizedDescription ?? "audio conversion failed")
            }
            if out.frameLength > 0 {
                let time = CMTime(value: outputPosition, timescale: CMTimeScale(target.sampleRate))
                continuation.yield(AnalyzerInput(buffer: out, bufferStartTime: time))
                outputPosition += Int64(out.frameLength)
            }
            if status == .endOfStream { break }
            if status == .inputRanDry && pull.isExhausted && out.frameLength == 0 { break }
        }
    }

    // MARK: - Result mapping

    private static func segment(
        from result: SpeechTranscriber.Result,
        offsetBy offset: MediaTime
    ) -> TranscriptSegment? {
        let attributed = result.text
        let text = String(attributed.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var words: [Word] = []
        var confidences: [Double] = []

        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if let confidence = run.transcriptionConfidence { confidences.append(confidence) }
            guard !trimmed.isEmpty, let timing = run.audioTimeRange else { continue }
            words.append(Word(
                text: trimmed,
                originalStart: offset + MediaTime(seconds: timing.start.seconds),
                originalEnd: offset + MediaTime(seconds: timing.end.seconds),
                confidence: run.transcriptionConfidence.map(Float.init)
            ))
        }

        let start = words.first?.originalStart
            ?? offset + MediaTime(seconds: result.range.start.seconds)
        let end = words.last?.originalEnd
            ?? offset + MediaTime(seconds: result.range.end.seconds)

        let confidence = confidences.isEmpty
            ? nil
            : Float(confidences.reduce(0, +) / Double(confidences.count))

        return TranscriptSegment(
            originalStart: start,
            originalEnd: Swift.max(end, start),
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words,
            confidence: confidence
        )
    }

    private nonisolated func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            // Word timings are not optional for VoxScripta: the merger's overlap
            // de-duplication and the polish validator's alignment both need them.
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }
}

private extension Locale {
    /// Whether this locale satisfies a requested BCP-47 identifier.
    ///
    /// Matches on the language and, when the request names one, the region — so
    /// "en" is served by "en-US" but "en-GB" is not served by "en-US".
    func matches(_ requested: String) -> Bool {
        let mine = identifier(.bcp47).lowercased()
        let theirs = requested.replacingOccurrences(of: "_", with: "-").lowercased()
        if mine == theirs { return true }
        return theirs.split(separator: "-").count == 1
            && mine.split(separator: "-").first.map(String.init) == theirs
    }
}

/// Walks a sample range, handing successive blocks to a converter.
///
/// Boxed for the same reason as the decoder's cursor: the converter's input block
/// is declared `@Sendable` but is pulled synchronously on the calling thread.
private final class RangeSampleSource: @unchecked Sendable {
    private let reader: CanonicalSampleReader
    private let range: SampleRange
    private let buffer: AVAudioPCMBuffer
    private let blockSamples: Int
    private var position: Int64
    private(set) var isExhausted = false

    init(reader: CanonicalSampleReader, range: SampleRange,
         format: AVAudioFormat, blockSamples: Int) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(blockSamples)) else {
            throw VoxScriptaError.decodingFailed(reason: "could not allocate an input buffer")
        }
        self.reader = reader
        self.range = range
        self.buffer = buffer
        self.blockSamples = blockSamples
        self.position = range.start
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if isExhausted || position >= range.end {
            isExhausted = true
            status.pointee = .endOfStream
            return nil
        }
        let count = Int(Swift.min(Int64(blockSamples), range.end - position))
        do {
            try reader.read(into: buffer, at: position, count: count)
        } catch {
            isExhausted = true
            status.pointee = .endOfStream
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(count)
        position += Int64(count)
        status.pointee = .haveData
        return buffer
    }
}

/// Reads sample ranges out of the memory-mapped canonical file.
///
/// This is what makes a chunk a view rather than a file: the scheduler hands the
/// engine an offset and a length, and the bytes are paged in on demand.
final class CanonicalSampleReader {
    private let data: Data
    let sampleCount: Int64

    init(url: URL) throws {
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
        sampleCount = Int64(data.count / MemoryLayout<Float>.size)
    }

    func read(into buffer: AVAudioPCMBuffer, at offset: Int64, count: Int) throws {
        guard offset >= 0, offset + Int64(count) <= sampleCount else {
            throw VoxScriptaError.ioFailure(
                path: "canonical audio",
                reason: "requested samples \(offset)..<\(offset + Int64(count)) of \(sampleCount)")
        }
        guard let destination = buffer.floatChannelData?[0] else {
            throw VoxScriptaError.ioFailure(path: "canonical audio", reason: "buffer has no float storage")
        }
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            destination.update(from: samples.baseAddress! + Int(offset), count: count)
        }
    }
}
