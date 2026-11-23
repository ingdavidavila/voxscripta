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

    /// The model file this engine will load, by name and byte count.
    ///
    /// Name and size rather than a content hash: hashing 141 MB on every job
    /// to learn something a filename already tells us is a poor trade, and
    /// the case this guards against — base swapped for small, or a model
    /// replaced by a different one — changes both. Re-downloading the same
    /// weights leaves both alone, so the cache is not thrown away for nothing,
    /// which an mtime would have done.
    ///
    /// A missing file is reported as missing rather than as nothing, so a
    /// resume cannot silently match a job that ran when the model was there.
    public nonisolated var modelIdentity: String {
        let name = modelURL.lastPathComponent
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: modelURL.path)[.size] as? Int64 else {
            return "\(name)|absent"
        }
        // The decoding mode belongs in the identity because the identity is
        // the transcription stage's cache key. A beam-search transcript and a
        // greedy one are different outputs from the same audio, and serving
        // one for the other is the stale-chunk bug the model name was added to
        // this string to prevent.
        return "\(name)|\(size)|\(decoding.slug)"
    }

    /// How the decoder searches.
    ///
    /// Whisper has been run here on the cheapest setting available since the
    /// engine was added — greedy, `best_of` 1 — and nothing had measured what
    /// that costs. Greedy takes the highest-probability token at every step and
    /// never reconsiders; beam search keeps several candidate sequences alive
    /// and picks the best complete one, which recovers exactly the case where a
    /// locally attractive token leads somewhere worse.
    ///
    /// Both are deterministic at temperature 0, which is the property that
    /// matters here: resume and the content-hash cache both require that the
    /// same audio produces the same transcript. Determinism never required
    /// greedy — that was a conflation, and it cost accuracy for nothing.
    public enum Decoding: Sendable, Hashable {
        case greedy
        /// Keeps `size` candidate sequences. whisper.cpp's own default is 5.
        case beamSearch(size: Int32)

        /// Beam search, because the project optimizes for accuracy.
        ///
        /// At the measured real-time factor of 0.01 there is roughly a
        /// hundredfold headroom over playback speed, so spending some of it on
        /// search quality is close to free in anything a person would notice.
        public static let standard = Decoding.beamSearch(size: 5)

        /// Part of the cache key, so a transcript decoded one way is never
        /// served for a request decoded the other.
        public var slug: String {
            switch self {
            case .greedy: "greedy"
            case .beamSearch(let size): "beam\(size)"
            }
        }
    }

    private var context: OpaquePointer?
    private let modelURL: URL
    private let threads: Int32
    private let decoding: Decoding

    /// - Parameters:
    ///   - modelURL: A ggml model file. Resolved by ``defaultModelURL()`` when
    ///     omitted, which looks where `Tools/fetch-whisper-model.sh` puts one.
    ///   - threads: CPU threads for decoding. Defaults to the physical core
    ///     count, which is what whisper.cpp's own tools use; more threads than
    ///     cores makes it slower, not faster.
    ///   - decoding: How the decoder searches. Defaults to
    ///     ``Decoding/standard``, which is beam search, overridable from the
    ///     environment so a benchmark can compare the two without an edit.
    public init(modelURL: URL? = nil, threads: Int? = nil, decoding: Decoding? = nil) {
        self.modelURL = modelURL ?? Self.defaultModelURL()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        self.threads = Int32(max(1, threads ?? max(1, cores / 2)))
        self.decoding = decoding ?? Self.decodingFromEnvironment()
    }

    /// `VOXSCRIPTA_WHISPER_DECODING` as `greedy` or `beam<N>`.
    ///
    /// An unrecognized value falls back to the standard setting rather than
    /// throwing: this is a benchmarking convenience, and a typo should not stop
    /// someone transcribing.
    static func decodingFromEnvironment() -> Decoding {
        guard let raw = ProcessInfo.processInfo.environment["VOXSCRIPTA_WHISPER_DECODING"],
              !raw.isEmpty else { return .standard }
        if raw == "greedy" { return .greedy }
        if raw.hasPrefix("beam"), let size = Int32(raw.dropFirst(4)), size > 0 {
            return .beamSearch(size: size)
        }
        return .standard
    }

    /// Where a model is looked for when the caller does not name one.
    ///
    /// An environment variable first, so a benchmark can point at a specific
    /// model without editing anything, then the project's own models folder.
    public static func defaultModelURL() -> URL {
        ModelSearch.locate("ggml-base.bin", environmentKey: "VOXSCRIPTA_WHISPER_MODEL")
    }

    // MARK: - Capabilities

    public func capabilities() async -> EngineCapabilities {
        EngineCapabilities(
            supportsWordTimestamps: true,
            supportsDiarization: false,
            supportedLocales: Self.supportedLocales,
            // Whisper's encoder is trained on 30-second windows. Longer spans
            // are handled internally by sliding, but the chunk planner should
            // not be told it can hand over an hour in one call.
            maximumChunkDuration: MediaTime.seconds(30 * 60),
            // One instance cannot serve two calls at once: whisper_full is
            // synchronous and holds the actor for the whole inference.
            supportsConcurrentCalls: false,
            recommendedConcurrency: Self.recommendedWorkers,
            // The language is applied from `options.locale` inside
            // `transcribe`; `prepare` only validates the locale and loads the
            // weights. So one context serves every language the model knows,
            // which is what lets the language probe hold one engine instead of
            // loading 487 MB of `ggml-small` once per candidate.
            localeSelectedPerCall: true
        )
    }

    /// How many contexts this machine should hold, from measurement.
    ///
    /// Measured on an M-series Mac, 4 performance and 6 efficiency cores,
    /// over baseline, with ggml-base:
    ///
    ///     CPU   1 context   431 MB   49x real time
    ///           2 contexts  869 MB   67x
    ///           4 contexts 1821 MB   32x   — slower in aggregate than one
    ///
    /// Two things set the ceiling. Memory, because contexts do not share
    /// weights and each costs about as much as the first — three times the
    /// 141 MB file. And cores, because the engine already asks for cores/2
    /// threads per context, so four contexts want twenty threads on ten
    /// cores and spend their time contending rather than decoding.
    ///
    /// So: two where there is memory and cores to spare, one otherwise. A
    /// phone gets one, which is the honest answer for 869 MB of resident
    /// weights on a device whose low-memory killer is the real constraint.
    static var recommendedWorkers: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        guard cores >= 8, gigabytes >= 8 else { return 1 }
        return 2
    }

    /// The languages the multilingual models accept.
    ///
    /// Whisper names languages, not locales, and the rest of this project
    /// speaks locales — so these are written as the locales the project uses,
    /// and ``whisperLanguage(for:)`` reduces one to the other.
    /// Narrowed to what this version ships, not to what the model can do.
    ///
    /// The multilingual weights handle around a hundred languages and this
    /// list used to name thirty-two of them. CLEAN and the POLISH gauntlet
    /// have been measured in two, so two is what is offered — see
    /// ``ShippingLanguages`` for why that is a correctness boundary rather
    /// than a product decision, and why it saves no download size.
    public static let supportedLocales: Set<String> = ShippingLanguages.set

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

        var params: whisper_full_params
        switch decoding {
        case .greedy:
            params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.greedy.best_of = 1
        case .beamSearch(let size):
            params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
            params.beam_search.beam_size = size
            // `best_of` is read by the beam decoder too, and leaving it at 1
            // while asking for a beam of five is a contradiction that whisper
            // resolves in the direction of doing less work.
            params.greedy.best_of = size
        }
        // Temperature stays at zero in both modes, because resume and the
        // content-hash cache require the same audio to produce the same
        // transcript. Zero temperature is what makes it deterministic; the
        // search strategy above does not affect that, which is why beam search
        // is available at all.
        params.temperature = 0
        params.temperature_inc = 0
        params.n_threads = threads
        params.token_timestamps = true
        // Whisper can translate to English. Vox Scripta does not: a
        // transcript is a record of what was said, and silently returning it
        // in another language would make it something else. Set explicitly
        // rather than left to the default, because this is a decision.
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
