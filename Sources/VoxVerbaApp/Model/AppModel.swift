import Foundation
import SwiftUI
import Observation
import VoxVerbaCore
import VoxVerbaDSP
import VoxVerbaTranscription
import VoxVerbaLanguage
import VoxVerbaProject
import VoxVerbaPipeline

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

        var options = JobOptions()
        options.transcription.concurrency = settings.concurrency
        options.transcription.locale = settings.locale
        options.clean = settings.cleanParameters
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
