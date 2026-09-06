import Foundation
import SwiftUI
import Observation
import VoxVerbaCore
import VoxVerbaDSP
import VoxVerbaTranscription
import VoxVerbaLanguage
import VoxVerbaProject
import VoxVerbaPipeline
import VoxVerbaMLX
import VoxVerbaExport
import VoxVerbaDSP

/// One row in the library.
struct ProjectSummary: Identifiable, Sendable, Hashable {
    let id: ProjectID
    let url: URL
    let displayName: String
    let duration: MediaTime
    let state: JobState
    let modifiedAt: Date
}

/// What the main pane is showing.
enum WorkspaceMode: Equatable {
    case empty
    case processing
    case transcript
}

/// The application's state, and the only place the UI talks to the pipeline.
///
/// `@MainActor` throughout: every property here is read during layout, so
/// isolating the whole type removes a class of races rather than guarding
/// individual fields. The pipeline runs off it, and reports back through a
/// coalesced channel.
@MainActor
@Observable
final class AppModel {
    // ── Library ─────────────────────────────────────────────────────────────
    private(set) var projects: [ProjectSummary] = []
    var selectedProjectID: ProjectID?

    // ── Current job ─────────────────────────────────────────────────────────
    private(set) var mode: WorkspaceMode = .empty
    private(set) var phase: JobState = .imported
    private(set) var progress: Double = 0
    private(set) var detail: String = ""
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    // ── Current result ──────────────────────────────────────────────────────
    private(set) var openProject: Project?
    private(set) var peaks: WaveformPeaks?
    private(set) var silenceMap: SilenceMap?
    private(set) var transcripts: [TranscriptVariant: Transcript] = [:]
    private(set) var polishReport: [PolishedSentence] = []
    private(set) var polishSkipReason: String?
    var selectedVariant: TranscriptVariant = .clean
    var showsValidationDetail = false
    var exportIncludesTimestamps = false
    private(set) var isRendering = false
    private(set) var lastRenderSummary: String?

    /// A pending delete awaiting confirmation, and what it would remove.
    private(set) var pendingDeletion: (summary: ProjectSummary, plan: ProjectStore.DeletionPlan)?
    /// Briefly set after copying, so the button can confirm it did something.
    private(set) var copyConfirmation: String?

    // ── Settings ────────────────────────────────────────────────────────────
    var settings = AppSettings.load() {
        didSet { settings.save() }
    }

    private var jobTask: Task<Void, Never>?
    private let store = ProjectStore()

    /// Where projects live when the user does not choose somewhere else.
    static var libraryDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appending(path: "VoxVerba/Projects")
    }

    init() {
        refreshLibrary()
    }

    // ── Library ─────────────────────────────────────────────────────────────

    func refreshLibrary() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.libraryDirectory, withIntermediateDirectories: true)
        let entries = (try? fm.contentsOfDirectory(
            at: Self.libraryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        var found: [ProjectSummary] = []
        for url in entries where url.pathExtension == ProjectPackage.fileExtension {
            let manifestURL = url.appending(path: "manifest.json")
            guard let manifest = try? AtomicFile.readJSON(ProjectManifest.self, from: manifestURL)
            else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? manifest.createdAt
            found.append(ProjectSummary(
                id: manifest.projectID, url: url,
                displayName: manifest.source.displayName,
                duration: manifest.source.duration,
                state: .complete, modifiedAt: modified))
        }
        projects = found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // ── Import ──────────────────────────────────────────────────────────────

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recording. VoxVerba never modifies the original."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importAudio(at: url)
    }

    /// Creates a project for `url` and starts processing.
    func importAudio(at url: URL) {
        errorMessage = nil
        let name = url.deletingPathExtension().lastPathComponent
        let destination = Self.libraryDirectory
            .appending(path: "\(name).\(ProjectPackage.fileExtension)")

        jobTask = Task { [weak self] in
            guard let self else { return }
            do {
                let decoder = CanonicalDecoder()
                let project: Project
                if FileManager.default.fileExists(
                    atPath: destination.appending(path: "manifest.json").path) {
                    project = try await store.open(at: destination)
                } else {
                    project = try await store.create(
                        from: url, at: destination,
                        policy: settings.copyOriginalIntoProject ? .copy : .reference,
                        silence: settings.silenceParameters,
                        chunking: settings.chunkParameters,
                        locale: settings.locale,
                        concurrency: settings.concurrency,
                        probe: { (try await decoder.probe(url: $0), try decoder.duration(of: $0)) })
                }
                await run(project: project)
            } catch {
                self.fail(error)
            }
        }
    }

    /// Opens a project unless it is already the one on screen.
    ///
    /// Selection changes fire when a job opens a project too, so without this
    /// guard opening one would immediately re-enter itself.
    func openIfNeeded(_ summary: ProjectSummary) {
        guard !isRunning, openProject?.manifest.projectID != summary.id else { return }
        open(summary)
    }

    func open(_ summary: ProjectSummary) {
        errorMessage = nil
        selectedProjectID = summary.id
        jobTask = Task { [weak self] in
            guard let self else { return }
            do {
                let project = try await store.open(at: summary.url)
                await run(project: project)
            } catch {
                self.fail(error)
            }
        }
    }

    // ── Running ─────────────────────────────────────────────────────────────

    private func run(project: Project) async {
        openProject = project
        selectedProjectID = project.manifest.projectID
        // A finished project should show its transcript immediately rather than
        // flashing a progress screen for work that is already done.
        peaks = nil
        silenceMap = nil
        transcripts = [:]
        loadArtifacts(for: project)
        mode = transcripts.isEmpty ? .processing : .transcript
        isRunning = true
        progress = 0
        detail = "Preparing"

        // Locale and concurrency come from the project's manifest, not from the
        // current settings — changing a setting must not silently re-transcribe
        // every project you open afterwards.
        var options = JobOptions()
        options.clean = settings.cleanParameters
        options.keepIntermediates = settings.keepIntermediateFiles
        options.polishBackend = settings.polishBackend
        options.polish = settings.polishEnabled ? settings.polishParameters : nil

        // Progress arrives from background tasks far faster than a person can
        // read it. The relay coalesces to 10 Hz so the main actor spends its time
        // drawing rather than laying out the same label hundreds of times a
        // second — this is what keeps a six-hour job from feeling frozen.
        let relay = ProgressRelay { [weak self] report in
            Task { @MainActor in
                guard let self else { return }
                self.phase = report.state
                self.progress = report.fraction
                self.detail = report.detail
                if report.state == .analyzing || report.state == .silenceProcessing {
                    self.loadArtifacts(for: project)
                }
            }
        }

        do {
            _ = try await JobRunner().run(project: project, options: options) { report in
                relay.send(report)
            }
            loadArtifacts(for: project)
            mode = .transcript
            phase = .complete
            progress = 1
            detail = "Complete"
        } catch is CancellationError {
            detail = "Cancelled"
            phase = .cancelled
            loadArtifacts(for: project)
            mode = transcripts.isEmpty ? .empty : .transcript
        } catch {
            fail(error)
        }
        isRunning = false
        refreshLibrary()
    }

    func cancel() {
        jobTask?.cancel()
        detail = "Stopping…"
    }

    private func fail(_ error: any Error) {
        errorMessage = (error as? VoxVerbaError)?.errorDescription ?? error.localizedDescription
        isRunning = false
        phase = .failed
    }

    // ── Artifacts ───────────────────────────────────────────────────────────

    /// Reads whatever the project has produced so far.
    ///
    /// Called during processing as well as after, so the waveform and speech
    /// regions appear as soon as analysis finishes rather than at the end.
    private func loadArtifacts(for project: Project) {
        let package = project.package
        if peaks == nil {
            peaks = try? AtomicFile.readJSON(WaveformPeaks.self, from: package.peaksURL)
        }
        if silenceMap == nil {
            silenceMap = try? AtomicFile.readJSON(SilenceMap.self, from: package.silenceMapURL)
        }
        for variant in TranscriptVariant.allCases {
            if let transcript = try? JobRunner.transcript(variant, from: package) {
                transcripts[variant] = transcript
            }
        }
        polishReport = (try? AtomicFile.readJSON([PolishedSentence].self,
                                                 from: package.polishReportURL)) ?? []
        polishSkipReason = try? String(contentsOf: package.polishSkippedURL, encoding: .utf8)
        if transcripts[selectedVariant] == nil {
            selectedVariant = transcripts[.clean] != nil ? .clean : .verbatim
        }
    }

    /// The transcript currently on screen.
    var currentTranscript: Transcript? { transcripts[selectedVariant] }

    /// Variants that actually exist for the open project.
    var availableVariants: [TranscriptVariant] {
        TranscriptVariant.allCases.filter { transcripts[$0] != nil }
    }

    /// Sentences whose polish was rejected, for the validation panel.
    var flaggedSentences: [PolishedSentence] {
        polishReport.filter { $0.disposition != .accepted }
    }

    func dismissError() { errorMessage = nil }

    // ── Delete ──────────────────────────────────────────────────────────────

    /// Asks what deleting a recording would remove, then waits for confirmation.
    ///
    /// Deleting is the only destructive action in the app, and what it destroys
    /// depends on how the recording was imported — so the question names the
    /// consequence rather than asking "are you sure?".
    func requestDelete(_ summary: ProjectSummary) {
        // Deleting a project out from under a running job would leave the
        // runner writing into a directory that is on its way to the Trash.
        if isRunning, openProject?.manifest.projectID == summary.id {
            errorMessage = "“\(summary.displayName)” is still being transcribed. "
                + "Stop it first, then delete it."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await store.deletionPlan(for: summary.url)
                pendingDeletion = (summary, plan)
            } catch {
                // A project too damaged to describe can still be removed.
                pendingDeletion = (summary, ProjectStore.DeletionPlan(
                    projectName: summary.displayName,
                    bytesFreed: 0, originalKept: nil, removesAudioCopy: false))
            }
        }
    }

    func cancelDelete() { pendingDeletion = nil }

    /// Spells out exactly what deleting removes, and what it does not.
    var deletionMessage: String {
        guard let (_, plan) = pendingDeletion else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: plan.bytesFreed, countStyle: .file)

        if let kept = plan.originalKept {
            return "The transcripts and working files move to the Trash, freeing \(size).\n\n"
                + "Your recording stays where it is:\n\(kept.path)"
        }
        if plan.removesAudioCopy {
            return "This project holds its own copy of the audio, so the copy goes to the "
                + "Trash along with the transcripts, freeing \(size).\n\n"
                + "Any recording you imported from elsewhere is untouched."
        }
        return "The transcripts and working files move to the Trash, freeing \(size)."
    }

    /// Moves the confirmed project to the Trash.
    func confirmDelete() {
        guard let (summary, _) = pendingDeletion else { return }
        pendingDeletion = nil

        do {
            try store.delete(at: summary.url)
            if openProject?.manifest.projectID == summary.id {
                closeOpenProject()
            }
            refreshLibrary()
        } catch {
            errorMessage = (error as? VoxVerbaError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Clears whatever is on screen, after its project goes away.
    private func closeOpenProject() {
        openProject = nil
        selectedProjectID = nil
        transcripts = [:]
        polishReport = []
        polishSkipReason = nil
        peaks = nil
        silenceMap = nil
        mode = .empty
    }

    // ── Clipboard ───────────────────────────────────────────────────────────

    /// Copies the whole visible transcript.
    func copyTranscript() {
        guard let transcript = currentTranscript else { return }
        let text = transcript.plainText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let words = transcript.wordCount
        copyConfirmation = words == 1 ? "Copied 1 word" : "Copied \(words) words"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copyConfirmation = nil
        }
    }

    // ── Models (§28) ────────────────────────────────────────────────────────

    /// What the bundled model is, if this build shipped one.
    var bundledModelDescription: String? {
        guard let directory = ModelLocator.bundledDirectory else { return nil }
        let bytes = ModelLocator.size(of: directory)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(ModelLocator.displayName(for: directory)) · \(size)"
    }

    /// Whether Apple's system model can run here.
    var systemModelAvailable: Bool {
        (try? LanguageModelHost.availability().get()) != nil
    }

    /// Which backend a job would actually use right now.
    var effectiveBackendDescription: String {
        guard let resolved = try? PolishBackendResolver.resolve(settings.polishBackend) else {
            return "unavailable — polish will be skipped"
        }
        return resolved.describedAs
    }

    // ── Export ──────────────────────────────────────────────────────────────

    /// Formats that can faithfully represent the variant on screen.
    var exportableFormats: [ExportFormat] {
        currentTranscript.map { Exporters.available(for: $0) } ?? []
    }

    /// What a plain click on Download writes: plain text unless the transcript
    /// cannot be represented that way.
    var defaultExportFormat: ExportFormat {
        let formats = exportableFormats
        return formats.contains(.plainText) ? .plainText : (formats.first ?? .plainText)
    }

    /// Writes the visible transcript in `format`, asking where to put it.
    func export(_ format: ExportFormat) {
        guard let transcript = currentTranscript, let project = openProject else { return }
        let base = URL(filePath: project.manifest.source.displayName)
            .deletingPathExtension().lastPathComponent
        let exporter = Exporters.make(format)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = exporter.filename(base: base, variant: selectedVariant)
        panel.canCreateDirectories = true
        panel.message = "Export the \(selectedVariant.displayName.lowercased()) transcript."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            var options = ExportOptions.default
            options.includeTimestamps = exportIncludesTimestamps
            try exporter.export(transcript, options: options).write(to: url)
        } catch {
            errorMessage = (error as? VoxVerbaError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Writes a copy of the recording with the detected silence removed.
    ///
    /// Explicitly opt-in. The pipeline never splices audio on its own, because
    /// doing so hurts transcription — this is for someone who wants the shortened
    /// recording for its own sake.
    func renderSilenceRemovedAudio() {
        guard let project = openProject, let map = silenceMap else { return }
        let base = URL(filePath: project.manifest.source.displayName)
            .deletingPathExtension().lastPathComponent

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(base) — silence removed.wav"
        panel.canCreateDirectories = true
        panel.message = "Save a copy with the detected silence removed. "
            + "The original recording is not modified."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isRendering = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let (source, release) = try project.resolveSource()
                defer { release() }
                let result = try await SilenceRemovalRenderer()
                    .render(source: source, to: url, using: map)
                // The time map ships beside the audio so a listener can still
                // locate themselves in the source recording.
                try AtomicFile.writeJSON(
                    result, to: url.deletingPathExtension().appendingPathExtension("json"))
                lastRenderSummary = "Removed \(result.removedDuration) of silence"
            } catch {
                errorMessage = (error as? VoxVerbaError)?.errorDescription
                    ?? error.localizedDescription
            }
            isRendering = false
        }
    }

    /// Writes every available format for every produced variant, into one folder.
    func exportAll() {
        guard let project = openProject else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder. Every transcript variant will be written in every format."
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let base = URL(filePath: project.manifest.source.displayName)
            .deletingPathExtension().lastPathComponent
        var options = ExportOptions.default
        options.includeTimestamps = exportIncludesTimestamps

        do {
            for (variant, transcript) in transcripts {
                for format in Exporters.available(for: transcript) {
                    let exporter = Exporters.make(format)
                    let url = directory.appending(
                        path: exporter.filename(base: base, variant: variant))
                    try exporter.export(transcript, options: options).write(to: url)
                }
            }
            NSWorkspace.shared.open(directory)
        } catch {
            errorMessage = (error as? VoxVerbaError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reveal(_ summary: ProjectSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([summary.url])
    }
}

/// Throttles progress reports to a rate a person can actually read.
///
/// A `final class` rather than an actor: `send` is called from whatever thread
/// the pipeline happens to be on, and must not suspend.
final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSent = ContinuousClock.now - .seconds(1)
    private var pending: JobProgressReport?
    private let interval: Duration
    private let deliver: @Sendable (JobProgressReport) -> Void

    init(interval: Duration = .milliseconds(100),
         deliver: @escaping @Sendable (JobProgressReport) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func send(_ report: JobProgressReport) {
        lock.lock()
        let now = ContinuousClock.now
        // A terminal report always goes through; intermediate ones wait their turn.
        let isFinal = report.fraction >= 1 || report.state.isTerminal
        guard isFinal || now - lastSent >= interval else {
            pending = report
            lock.unlock()
            return
        }
        lastSent = now
        pending = nil
        lock.unlock()
        deliver(report)
    }
}
