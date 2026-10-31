import Foundation
import CWhisper
import VoxScriptaCore

/// Recognition that is not Apple's, for the platforms that are not Apple's.
///
/// whisper.cpp, linked as a static library and called through a header shim.
/// It exists because `SpeechAnalyzer` does not, off Apple's platforms: Android,
/// Windows and Linux need a recogniser that is plain portable C++, runs on the
/// CPU, needs no network, and carries its own model.
///
/// It also covers a gap on Apple's side. Apple recognises roughly thirty
/// locales against Whisper's hundred-plus, and an OS-versioned model cannot
/// give the same words on two different machines — which is what the benchmark
/// suite needs in order to compare anything.
///
/// The canonical audio format lines up exactly: this project already decodes
/// everything to 16 kHz mono `Float32`, which is the only input Whisper takes.
/// So a chunk is a seek and a read, with no resampling and no AVFoundation,
/// and the reading code is portable for the same reason the engine is.
///
/// An actor because `whisper_context` is a C pointer with no thread safety of
/// its own, and `whisper_full` must not be re-entered on one context.
public actor WhisperEngine: TranscriptionEngine {
    public nonisolated let identifier = EngineID.whisper

    private var context: OpaquePointer?
    private let modelURL: URL
    private let threads: Int32

    /// - Parameters:
    ///   - modelURL: A ggml model file. Resolved by ``defaultModelURL()`` when
    ///     omitted, which looks where `Tools/fetch-whisper-model.sh` puts one.
    ///   - threads: CPU threads for decoding. Defaults to the physical core
    ///     count, which is what whisper.cpp's own tools use; more threads than
    ///     cores makes it slower, not faster.
    public init(modelURL: URL? = nil, threads: Int? = nil) {
        self.modelURL = modelURL ?? Self.defaultModelURL()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        self.threads = Int32(max(1, threads ?? max(1, cores / 2)))
    }

    /// Where a model is looked for when the caller does not name one.
    ///
    /// An environment variable first, so a benchmark can point at a specific
    /// model without editing anything, then the project's own models folder.
    public static func defaultModelURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VOXSCRIPTA_WHISPER_MODEL"] {
            return URL(filePath: override)
        }
        return URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "build/models/ggml-base.bin")
    }

    // MARK: - Capabilities

    public func capabilities() async -> EngineCapabilities {
        EngineCapabilities(
            supportsWordTimestamps: true,
            supportsDiarization: false,
            // Whisper can translate to English, which the pipeline does not ask
            // for yet. Declared because it is true of the engine, not because
            // anything calls it.
            supportsTranslation: true,
            supportedLocales: Self.supportedLocales,
            // Whisper's encoder is trained on 30-second windows. Longer spans
            // are handled internally by sliding, but the chunk planner should
            // not be told it can hand over an hour in one call.
            maximumChunkDuration: MediaTime.seconds(30 * 60)
        )
    }

    /// The languages the multilingual models accept.
    ///
    /// Whisper names languages, not locales, and the rest of this project
    /// speaks locales — so these are written as the locales the project uses,
    /// and ``whisperLanguage(for:)`` reduces one to the other.
    public static let supportedLocales: Set<String> = [
        "en-US", "en-GB", "es-ES", "es-MX", "es-419", "fr-FR", "de-DE", "it-IT",
        "pt-BR", "pt-PT", "nl-NL", "ca-ES", "pl-PL", "ru-RU", "ja-JP", "ko-KR",
        "zh-CN", "zh-TW", "ar-SA", "tr-TR", "sv-SE", "da-DK", "nb-NO", "fi-FI",
        "uk-UA", "cs-CZ", "el-GR", "he-IL", "hi-IN", "id-ID", "th-TH", "vi-VN",
    ]

    /// The two-letter code Whisper wants, from the locale the project uses.
    static func whisperLanguage(for locale: String) -> String {
        let base = locale.split(separator: "-").first.map(String.init) ?? locale
        return base.lowercased()
    }

    // MARK: - Lifecycle

    public func prepare(locale: String) async throws {
        guard Self.supportedLocales.contains(locale)
                || Self.supportedLocales.contains(where: {
                    Self.whisperLanguage(for: $0) == Self.whisperLanguage(for: locale)
                }) else {
            throw VoxScriptaError.localeUnsupported(identifier, locale: locale)
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VoxScriptaError.modelAssetMissing(
                description: "no Whisper model at \(modelURL.path) — "
                    + "run Tools/fetch-whisper-model.sh")
        }
        if context != nil { return }

        var params = whisper_context_default_params()
        // Left to the library to decide. On Apple hardware that means Metal,
        // and everywhere else the CPU backend that was built with it.
        params.use_gpu = true
        guard let opened = whisper_init_from_file_with_params(modelURL.path, params) else {
            throw VoxScriptaError.engineUnavailable(
                identifier, reason: "the model at \(modelURL.lastPathComponent) would not load")
        }
        context = opened
    }

    public func release() async {
        if let context { whisper_free(context) }
        context = nil
    }

    // MARK: - Transcribing

    public func transcribe(
        _ range: SampleRange,
        in canonicalFile: URL,
        options: TranscriptionOptions
    ) async throws -> [TranscriptSegment] {
        guard let context else {
            throw VoxScriptaError.engineUnavailable(
                identifier, reason: "transcribe called before prepare")
        }
        let samples = try Self.readSamples(range, from: canonicalFile)
        guard !samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // Deterministic, because a transcript that changes between runs cannot
        // be compared against a reference or resumed from a content hash.
        params.temperature = 0
        params.temperature_inc = 0
        params.greedy.best_of = 1
        params.n_threads = threads
        params.token_timestamps = true
        params.translate = false
        params.no_timestamps = false
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.single_segment = false
        params.suppress_blank = true

        let language = Self.whisperLanguage(for: options.locale)
        let status: Int32 = language.withCString { languagePointer in
            params.language = languagePointer
            return samples.withUnsafeBufferPointer { audio in
                whisper_full(context, params, audio.baseAddress, Int32(audio.count))
            }
        }
        guard status == 0 else {
            throw VoxScriptaError.transcriptionFailed(
                chunk: ChunkID(), reason: "whisper_full returned \(status)")
        }

        // Whisper's times are relative to the chunk; the rest of the project
        // works on the original recording's timeline, so everything is shifted
        // back by where the chunk started.
        let offset = MediaTime(samples: range.start, sampleRate: CanonicalFormat.sampleRate)
        return (0..<whisper_full_n_segments(context)).compactMap { index in
            Self.segment(from: context, at: index, offset: offset)
        }
    }

    // MARK: - Reading the canonical file

    /// Reads one span of the canonical 16 kHz mono `Float32` file.
    ///
    /// Deliberately `FileHandle` and arithmetic rather than an audio framework:
    /// the canonical file has no header and one fixed format, so there is
    /// nothing to parse, and this then works unchanged on every platform the
    /// engine is for.
    static func readSamples(_ range: SampleRange, from url: URL) throws -> [Float] {
        let width = Int64(CanonicalFormat.bytesPerSample)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(range.start * width))
            guard let data = try handle.read(upToCount: Int(range.count * width)),
                  !data.isEmpty else { return [] }
            return data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
        } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
    }

    /// One whisper segment, on the recording's timeline.
    ///
    /// Confidence is the mean of the token probabilities the decoder reports.
    /// Worth knowing: that is not the same quantity Apple reports, so the
    /// CLEAN confidence floor — measured at 0.65 against Apple's numbers —
    /// has to be recalibrated before it is trusted against this engine.
    private static func segment(from context: OpaquePointer,
                                at index: Int32,
                                offset: MediaTime) -> TranscriptSegment? {
        guard let raw = whisper_full_get_segment_text(context, index) else { return nil }
        let text = String(cString: raw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // Whisper counts in hundredths of a second.
        let start = offset + MediaTime.milliseconds(
            Double(whisper_full_get_segment_t0(context, index)) * 10)
        let end = offset + MediaTime.milliseconds(
            Double(whisper_full_get_segment_t1(context, index)) * 10)

        var probabilities: [Float] = []
        var words: [Word] = []
        for token in 0..<whisper_full_n_tokens(context, index) {
            let data = whisper_full_get_token_data(context, index, token)
            // Timestamp and other special tokens carry no text worth keeping.
            if data.id >= whisper_token_eot(context) { continue }
            probabilities.append(data.p)
            guard let tokenText = whisper_full_get_token_text(context, index, token) else { continue }
            let piece = String(cString: tokenText)
            guard !piece.hasPrefix("[") else { continue }
            words.append(Word(
                text: piece.trimmingCharacters(in: .whitespaces),
                originalStart: offset + MediaTime.milliseconds(Double(data.t0) * 10),
                originalEnd: offset + MediaTime.milliseconds(Double(data.t1) * 10),
                confidence: data.p))
        }

        let confidence = probabilities.isEmpty
            ? nil
            : probabilities.reduce(0, +) / Float(probabilities.count)

        return TranscriptSegment(
            originalStart: start,
            originalEnd: end,
            text: text,
            // Whisper's tokens are sub-word pieces, not words. They are kept
            // because subtitle export needs timings, but they are not a word
            // list and nothing should treat them as one until they are merged.
            words: words.filter { !$0.text.isEmpty },
            confidence: confidence)
    }
}
