import Foundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaTranscription
import VoxScriptaLanguage
import VoxScriptaProject
import VoxScriptaPipeline
import VoxScriptaExport

// Structured data crossing the ABI, as JSON.
//
// The split is deliberate: scalars for the hot path — polling a job ten times a
// second is four integer reads and no allocation — and JSON for everything with
// shape. The alternative for settings was a dozen scalar parameters, which is
// not a signature anyone should write and which breaks every time a setting is
// added, or a C struct, whose layout three languages and three platforms would
// have to agree about forever. A JSON string is one parameter that never
// changes shape, and the engine's parameter types are already `Codable`.
//
// These are *wire* types rather than the engine's own. That is not ceremony.
// ``JobOptions`` carries `crashPoint`, a test affordance that deliberately
// sends `SIGKILL` to the process; exposing the engine's struct directly would
// put that one JSON key away from any caller that passed untrusted input. It is
// absent here by construction rather than by filtering.

/// What an interface may set about a job.
///
/// Every field is optional and a missing one means the engine's default, so a
/// caller sets what it cares about. ``defaults`` hands back the whole set, and
/// `vs_job_options_defaults` exists so that an interface shows the engine's
/// numbers rather than a second copy of them that can fall out of step.
struct JobOptionsWire: Codable {
    var locale: String?
    var detectLanguage: Bool?
    var concurrency: Int?
    var silence: SilenceParameters?
    var chunking: ChunkParameters?
    var clean: CleanParameters?
    /// Polish settings. `polishEnabled: false` stops after CLEAN.
    var polish: PolishParameters?
    var polishEnabled: Bool?
    /// `automatic`, `system` or `bundled`.
    var polishBackend: String?
    var keepIntermediates: Bool?

    static var defaults: JobOptionsWire {
        let base = JobOptions()
        return JobOptionsWire(
            locale: base.transcription.locale,
            detectLanguage: base.transcription.detectLanguage,
            concurrency: base.transcription.concurrency,
            silence: .default,
            chunking: .default,
            clean: base.clean,
            polish: base.polish,
            polishEnabled: base.polish != nil,
            polishBackend: base.polishBackend.rawValue,
            keepIntermediates: base.keepIntermediates)
    }

    /// Folds this onto the engine's defaults.
    ///
    /// - Throws: When a named backend does not exist. A misspelling is a
    ///   refusal rather than a silent fall back to `automatic`, for the same
    ///   reason `.system` is refused by name off Apple: a caller that asked for
    ///   something specific should be told it is unavailable.
    func resolved() throws -> JobOptions {
        var options = JobOptions()
        if let locale { options.transcription.locale = locale }
        if let detectLanguage { options.transcription.detectLanguage = detectLanguage }
        if let concurrency { options.transcription.concurrency = concurrency }
        if let clean { options.clean = clean }
        if let polish { options.polish = polish }
        if let polishEnabled, !polishEnabled { options.polish = nil }
        if let keepIntermediates { options.keepIntermediates = keepIntermediates }
        if let polishBackend {
            guard let backend = PolishBackendPreference(rawValue: polishBackend) else {
                throw VoxScriptaError.notImplemented(
                    String(localized: "no such polish backend: \(polishBackend)"))
            }
            options.polishBackend = backend
        }
        return options
    }
}

/// One project, as a library list reports it.
struct ProjectEntryWire: Codable {
    let id: String
    let path: String
    let displayName: String
    let durationSeconds: Double
    let state: String
    /// Seconds since 1970, which every platform can read without a date format
    /// being agreed on.
    let modifiedAt: Double
}

/// What an export may be asked for, beyond the format.
struct ExportOptionsWire: Codable {
    var includeTimestamps: Bool?
    var includeSpeakerLabels: Bool?
    var maximumCueLength: Int?

    static var defaults: ExportOptionsWire {
        let base = ExportOptions.default
        return ExportOptionsWire(
            includeTimestamps: base.includeTimestamps,
            includeSpeakerLabels: base.includeSpeakerLabels,
            maximumCueLength: base.maximumCueLength)
    }

    func resolved() -> ExportOptions {
        var options = ExportOptions.default
        if let includeTimestamps { options.includeTimestamps = includeTimestamps }
        if let includeSpeakerLabels { options.includeSpeakerLabels = includeSpeakerLabels }
        if let maximumCueLength { options.maximumCueLength = maximumCueLength }
        return options
    }
}

// MARK: - Coding

enum Wire {
    /// JSON out, with keys in a stable order so a diff of two responses is
    /// readable and a test can compare strings.
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// JSON in. A null or empty string means "defaults", which is what a
    /// caller that has no opinion should be able to pass.
    static func decode<T: Decodable>(_ type: T.Type, from json: String?) throws -> T?
    where T: Decodable {
        guard let json, !json.isEmpty else { return nil }
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Scans a directory for projects.
    ///
    /// Mirrors what the SwiftUI library pane does, including its one
    /// inaccuracy: `state` is reported as `complete` for every project that has
    /// a readable manifest, because the real state lives in each project's
    /// SQLite job store and opening one per row would make listing a library
    /// cost a database open per entry. Both interfaces therefore say the same
    /// slightly-too-optimistic thing, which is better than each saying a
    /// different thing. Fixing it means a cheap state column in the manifest.
    static func library(at directory: URL) -> [ProjectEntryWire] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        var found: [ProjectEntryWire] = []
        for url in contents where url.pathExtension == ProjectPackage.fileExtension {
            let manifestURL = ProjectPackage(root: url).manifestURL
            guard let manifest = try? AtomicFile.readJSON(ProjectManifest.self,
                                                          from: manifestURL)
            else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? manifest.createdAt
            found.append(ProjectEntryWire(
                id: manifest.projectID.rawValue.uuidString,
                path: url.path,
                displayName: manifest.source.displayName,
                durationSeconds: manifest.source.duration.seconds,
                state: JobState.complete.rawValue,
                modifiedAt: modified.timeIntervalSince1970))
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

// MARK: - A project's outputs

/// One transcript that exists on disk.
struct VariantWire: Codable {
    let variant: String
    let words: Int
    let segments: Int
}

/// One sentence POLISH did not simply accept.
///
/// Only the ones worth looking at are carried. A clean run of a long interview
/// is thousands of accepted sentences, and sending them all so that an
/// interface can count them and throw them away would be a megabyte of JSON to
/// render one number. The counts come separately; this list is the evidence.
struct FlaggedSentenceWire: Codable {
    let disposition: String
    let original: String
    let revised: String
    let reasons: [String]
}

/// What POLISH did, as the review panel shows it.
struct PolishReviewWire: Codable {
    /// False when the stage declined. ``skipReason`` then says why, in the
    /// engine's own words — §26 asks that a missing polished transcript never
    /// be unexplained.
    let ran: Bool
    let skipReason: String?
    let accepted: Int
    let acceptedAfterRetry: Int
    /// Validation failed twice, or the model errored. The CLEAN text stands.
    let keptClean: Int
    let flagged: [FlaggedSentenceWire]
}

/// What is known about a project's audio.
///
/// Present as soon as the stage that produced it has run, so the processing
/// screen can show something real during the long wait rather than only a bar.
struct AudioFactsWire: Codable {
    let durationSeconds: Double
    /// Nil until silence detection has run.
    let speechRegions: Int?
    let speechFraction: Double?
    /// Buckets available from `vs_waveform`, or nil before analysis.
    let waveformBuckets: Int?
    /// Where speech was detected, as `[start, end]` pairs in seconds.
    ///
    /// The spans themselves and not only the fraction, because an interface
    /// drawing them needs to know *where*. The first version of the processing
    /// screen had the fraction alone and shaded that share of the width from
    /// the left, which looks like a finding and is not one — it says the first
    /// 71% of the recording is speech when the truth is that 71% of it is,
    /// scattered throughout.
    let speechSpans: [[Double]]?
    /// Roughly how long POLISH will take, at the measured 1.4 seconds per
    /// second of audio. The rate is a measurement and therefore a rule, so it
    /// is applied here and not in an interface.
    let polishEstimateSeconds: Double?

    // Encoded by hand so that an absent value is written as `null` rather than
    // dropped. `JSONEncoder` omits nil optionals, which would make the keys
    // appear and disappear as stages ran — and a consumer in another language
    // cannot tell "not measured yet" from "this build does not report it" when
    // the key is simply missing. The documented shape is the shape.
    enum CodingKeys: String, CodingKey {
        case durationSeconds, speechRegions, speechFraction
        case waveformBuckets, speechSpans, polishEstimateSeconds
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try encodeOptional(speechRegions, .speechRegions, into: &container)
        try encodeOptional(speechFraction, .speechFraction, into: &container)
        try encodeOptional(waveformBuckets, .waveformBuckets, into: &container)
        try encodeOptional(speechSpans, .speechSpans, into: &container)
        try encodeOptional(polishEstimateSeconds, .polishEstimateSeconds,
                           into: &container)
    }

    private func encodeOptional<T: Encodable>(
        _ value: T?,
        _ key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

/// Everything the transcript and processing screens need that is not text.
struct ProjectSummaryWire: Codable {
    let variants: [VariantWire]
    let polish: PolishReviewWire
    let audio: AudioFactsWire
}

extension Wire {
    /// Reads a project's outputs without decoding more than it must.
    ///
    /// Each variant is decoded to count its words and segments, which is the
    /// honest cost of reporting a count the interface must not compute itself:
    /// `wordCount` is a rule, and a Dart reimplementation of it would be a
    /// second answer waiting to disagree with the first.
    static func summary(of package: ProjectPackage) -> ProjectSummaryWire {
        let sources: [(TranscriptVariant, URL)] = [
            (.verbatim, package.transcriptURL),
            (.clean, package.cleanTranscriptURL),
            (.polished, package.polishedTranscriptURL),
        ]

        var variants: [VariantWire] = []
        for (variant, url) in sources {
            guard let transcript = try? AtomicFile.readJSON(Transcript.self, from: url)
            else { continue }
            variants.append(VariantWire(variant: variant.rawValue,
                                        words: transcript.wordCount,
                                        segments: transcript.segments.count))
        }

        return ProjectSummaryWire(variants: variants,
                                  polish: polishReview(in: package),
                                  audio: audioFacts(in: package))
    }

    /// Seconds of polishing per second of recording.
    ///
    /// Measured rather than guessed: seventeen minutes of Spanish took
    /// twenty-three minutes, at one model call per sentence. Here rather than
    /// in an interface because a measurement is a fact about the engine, and
    /// two interfaces quoting different numbers for the same wait would be
    /// two applications.
    static let polishSecondsPerSecondOfAudio = 1.4

    private static func audioFacts(in package: ProjectPackage) -> AudioFactsWire {
        let manifest = try? AtomicFile.readJSON(ProjectManifest.self,
                                                from: package.manifestURL)
        let duration = manifest?.source.duration.seconds ?? 0

        let map = try? AtomicFile.readJSON(SilenceMap.self, from: package.silenceMapURL)
        let peaks = try? AtomicFile.readJSON(WaveformPeaks.self, from: package.peaksURL)

        return AudioFactsWire(
            durationSeconds: duration,
            speechRegions: map?.speechRegions.count,
            speechFraction: map?.speechFraction,
            waveformBuckets: peaks?.maxima.count,
            speechSpans: map?.speechRegions.map {
                [$0.range.start.seconds, $0.range.end.seconds]
            },
            polishEstimateSeconds: duration > 0
                ? duration * polishSecondsPerSecondOfAudio
                : nil)
    }

    /// The waveform, as interleaved little-endian Float32 min/max pairs.
    ///
    /// Bytes rather than JSON because a few thousand buckets as decimal text
    /// is twenty times the size for a drawing that is redrawn on every resize.
    /// Downsampled here rather than in the interface: picking the extremes of
    /// each span is the only reduction that keeps a waveform looking like the
    /// audio, and averaging — which is what a naive interface would do —
    /// flattens every transient.
    static func waveform(in package: ProjectPackage, buckets requested: Int) -> Data? {
        guard let peaks = try? AtomicFile.readJSON(WaveformPeaks.self,
                                                   from: package.peaksURL),
              peaks.maxima.count > 0
        else { return nil }

        let source = peaks.maxima.count
        let target = requested > 0 ? Swift.min(requested, source) : source

        var out = Data(capacity: target * 2 * MemoryLayout<Float>.size)
        for bucket in 0..<target {
            let start = bucket * source / target
            let end = Swift.max(start + 1, (bucket + 1) * source / target)
            var low = Float.greatestFiniteMagnitude
            var high = -Float.greatestFiniteMagnitude
            for index in start..<Swift.min(end, source) {
                low = Swift.min(low, peaks.minima[index])
                high = Swift.max(high, peaks.maxima[index])
            }
            withUnsafeBytes(of: low.bitPattern.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: high.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    private static func polishReview(in package: ProjectPackage) -> PolishReviewWire {
        // The skip reason is plain text rather than JSON because the pipeline
        // writes it in one line at the moment it decides not to run.
        let skipReason = (try? String(contentsOf: package.polishSkippedURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let report = (try? AtomicFile.readJSON([PolishedSentence].self,
                                               from: package.polishReportURL)) ?? []

        if report.isEmpty, let skipReason, !skipReason.isEmpty {
            return PolishReviewWire(ran: false, skipReason: skipReason,
                                    accepted: 0, acceptedAfterRetry: 0,
                                    keptClean: 0, flagged: [])
        }

        var accepted = 0, retried = 0, kept = 0
        var flagged: [FlaggedSentenceWire] = []
        for sentence in report {
            switch sentence.disposition {
            case .accepted:
                accepted += 1
            case .acceptedAfterRetry:
                retried += 1
                // Carried: it passed, but only on a second attempt, which is
                // the one case where a reader may want to see what changed.
                flagged.append(entry(for: sentence))
            case .fellBackToClean, .modelFailed:
                kept += 1
                flagged.append(entry(for: sentence))
            }
        }

        return PolishReviewWire(
            ran: !report.isEmpty,
            skipReason: report.isEmpty ? skipReason : nil,
            accepted: accepted, acceptedAfterRetry: retried,
            keptClean: kept, flagged: flagged)
    }

    private static func entry(for sentence: PolishedSentence) -> FlaggedSentenceWire {
        FlaggedSentenceWire(
            disposition: sentence.disposition.rawValue,
            original: sentence.original,
            revised: sentence.revised,
            reasons: sentence.report.failureReasons)
    }
}

// MARK: - What this machine can do

/// One transcription language the interface may offer.
struct LocaleOptionWire: Codable {
    let identifier: String
    let displayName: String
    /// Whether CLEAN and POLISH understand this language. Transcription works
    /// either way; the text stages do not, because applying one language's
    /// filler list to another deletes real words.
    let hasTextSupport: Bool
    /// Whether POLISH is allowed to run in it at all. A language whose polarity
    /// lexicon is empty has no defence against a reversed meaning, so the
    /// gauntlet refuses it rather than running unguarded.
    let polishValidated: Bool
}

/// Which model POLISH would use if a job started now.
struct PolishCapabilityWire: Codable {
    let systemModelAvailable: Bool
    /// The bundled model's name, or nil when this build ships none.
    let bundledModel: String?
    /// What `describedAs` would say — "Apple on-device model", "llama.cpp,
    /// polish.gguf" — or nil when nothing would run.
    let effective: String?
    /// Why nothing would run, when nothing would.
    let unavailableReason: String?
}

/// Everything the settings screen needs to describe this machine.
struct CapabilitiesWire: Codable {
    let locales: [LocaleOptionWire]
    let polish: PolishCapabilityWire
}

extension Wire {
    /// What this build on this machine can actually do.
    ///
    /// Here rather than computed by each interface, because every line of it is
    /// a rule: which languages the text stages understand, which have enough
    /// defence for POLISH to be allowed, and which model would really run. A
    /// settings screen that worked any of that out for itself would be a second
    /// copy of the engine's judgement, free to disagree with the first.
    static func capabilities() async -> CapabilitiesWire {
        CapabilitiesWire(locales: await locales(), polish: polishCapability())
    }

    private static func locales() async -> [LocaleOptionWire] {
        let offered = TranscriptLanguage.allCases.flatMap(\.offeredLocales)
        #if canImport(Speech)
        // Apple's recogniser supports a fixed set, which is narrower than the
        // list the text stages know.
        let supported = await AppleSpeechEngine.supportedLocaleIdentifiers()
        let usable = offered.filter(supported.contains)
        #else
        // whisper.cpp is one multilingual model, so everything the text stages
        // support is transcribable.
        let usable = offered
        #endif

        return usable.map { identifier in
            let language = TranscriptLanguage(localeIdentifier: identifier)
            return LocaleOptionWire(
                identifier: identifier,
                displayName: describe(identifier),
                hasTextSupport: language != nil,
                polishValidated: language.map(PolishReadiness.isValidated) ?? false)
        }
    }

    /// A human name for a locale, from the system where there is one.
    private static func describe(_ identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        return Locale.current.localizedString(forIdentifier: identifier)
            ?? locale.identifier
    }

    private static func polishCapability() -> PolishCapabilityWire {
        #if canImport(FoundationModels)
        let systemAvailable = (try? LanguageModelHost.availability().get()) != nil
        #else
        let systemAvailable = false
        #endif

        // Asked rather than inferred: the resolver is the only thing that knows
        // what a registration has put in the bundled slot, and `describedAs` is
        // the same string the provenance records.
        let bundled = try? PolishBackendResolver.resolve(.bundled)

        // One resolve, and the refusal kept rather than discarded. `try?`
        // throws away exactly the sentence the settings screen needs to show.
        do {
            let resolved = try PolishBackendResolver.resolve(.automatic)
            return PolishCapabilityWire(
                systemModelAvailable: systemAvailable,
                bundledModel: bundled?.describedAs,
                effective: resolved.describedAs,
                unavailableReason: nil)
        } catch {
            return PolishCapabilityWire(
                systemModelAvailable: systemAvailable,
                bundledModel: bundled?.describedAs,
                effective: nil,
                unavailableReason: (error as? VoxScriptaError)?.errorDescription
                    ?? error.localizedDescription)
        }
    }
}
