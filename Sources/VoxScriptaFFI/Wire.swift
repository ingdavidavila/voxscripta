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
