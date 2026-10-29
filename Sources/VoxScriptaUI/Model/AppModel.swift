import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaTranscription
import VoxScriptaLanguage
import VoxScriptaProject
import VoxScriptaPipeline
import VoxScriptaMLX
import VoxScriptaExport
import VoxScriptaDSP

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
public final class AppModel {
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
        return base.appending(path: "VoxScripta/Projects")
    }

    public init() {
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

    /// What the open panel offers.
    ///
    /// `.movie` on its own is too generous. macOS registers types for WebM, WMV,
    /// Flash and RealMedia that AVFoundation has no demuxer for, so the panel
    /// would accept a file and the decode would then fail on something the user
    /// had just been told was fine. Asking AVFoundation what it can actually
    /// read keeps the offer and the capability in step, and needs no hardcoded
    /// list to drift out of date.
    static let importableContentTypes: [UTType] = {
        let movies = AVURLAsset.audiovisualTypes()
            .compactMap { UTType($0.rawValue) }
            .filter { $0.conforms(to: .movie) }
        return [.audio] + movies
    }()

    /// Drives the file importer in `RootView`.
    ///
    /// The panels used to be run imperatively from here with AppKit, which
    /// worked and did not exist on iOS. SwiftUI's own importer is presented by
    /// a view rather than called, so the model holds the flag and the view
    /// holds the sheet — and the same code serves both platforms instead of
    /// one being a port of the other.
    var isImportingAudio = false

    public func presentImportPanel() { isImportingAudio = true }

    /// Called by the importer when the user picks something.
    func importPicked(_ result: Result<[URL], any Error>) {
        isImportingAudio = false
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // A URL from the picker is security-scoped and must be opened
            // before it can be read; the project takes its own bookmark during
            // import, so access is only needed for that moment.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importAudio(at: url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Creates a project for `url` and starts processing.
    func importAudio(at url: URL) {
        errorMessage = nil

        // Drag and drop reaches here without passing the panel's filter, so the
        // same rule is applied to both routes.
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .movie), !CanonicalDecoder.isDemuxable(type) {
            errorMessage = VoxScriptaError.unsupportedContainer(
                fileExtension: url.pathExtension.lowercased()).errorDescription
            return
        }

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

    // ── Recording ───────────────────────────────────────────────────────────

    /// The microphone, when one is open.
    ///
    /// Observable in its own right, so a view reading `model.recorder.elapsed`
    /// is updated by the recorder's ticker without this type forwarding
    /// anything.
    let recorder = AudioRecorder()

    /// Whether the settings sheet is up.
    ///
    /// On the model rather than the view because the button that opens it and
    /// the sheet that it opens are no longer in the same view: iOS hangs the
    /// toolbar off the sidebar and the sheet off the root.
    var isShowingSettings = false

    /// Whether the recording screen is up.
    ///
    /// Held separately from the recorder's own state so the screen can be
    /// presented for the instant before capture begins, and torn down in one
    /// place when it ends.
    var isShowingRecorder = false

    /// Set when the microphone has been refused, to offer the way to fix it.
    var isMicrophoneDenied = false

    /// Opens the microphone, asking for permission first if it has never been asked.
    ///
    /// The permission prompt is the reason this is not simply `recorder.start()`:
    /// the system sheet is asynchronous, and starting before the user answers
    /// records nothing.
    func beginRecording() {
        errorMessage = nil
        switch AudioRecorder.permission {
        case .granted:
            startRecording()
        case .denied:
            isMicrophoneDenied = true
        case .undetermined:
            Task { [weak self] in
                let granted = await AudioRecorder.requestPermission()
                guard let self else { return }
                if granted { self.startRecording() } else { self.isMicrophoneDenied = true }
            }
        }
    }

    /// Shows the recording screen, then opens the microphone behind it.
    ///
    /// In that order on purpose. Opening the microphone is not instant, and
    /// presenting only once it succeeds means the button does nothing visible
    /// for as long as the audio route takes — which, when the route is
    /// broken, is forever.
    private func startRecording() {
        isShowingRecorder = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start()
            } catch {
                isShowingRecorder = false
                fail(error)
            }
        }
    }

    /// Stops the microphone and sends the recording through the ordinary import.
    ///
    /// The file keeps its place on disk and is referenced, not consumed: from
    /// here on it is an original like any other, and §5 applies to it in full.
    func finishRecording() {
        let url = recorder.finish()
        isShowingRecorder = false
        guard let url else {
            errorMessage = String(localized: "That recording was too short to transcribe.")
            return
        }
        importAudio(at: url)
    }

    /// Stops the microphone and deletes what was captured.
    ///
    /// Called only from a confirmation the user answered, and only while the
    /// recording has not yet become a project.
    func discardRecording() {
        recorder.discard()
        isShowingRecorder = false
    }

    /// Opens the system page where microphone access is granted.
    ///
    /// There is nothing this app can do about a refused microphone except
    /// point at the switch, so it points precisely rather than describing a
    /// path through a settings app.
    func openMicrophoneSettings() {
        isMicrophoneDenied = false
        #if os(macOS)
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        if let url { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
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
        // Detection is a preference rather than a project property: it changes
        // what the locale becomes, and the locale itself still comes from the
        // manifest so an existing project is never re-detected.
        options.transcription.detectLanguage = settings.detectLanguage
        // Both conditions, because the setting is the user's preference and
        // polishSupported is whether we can honour it safely.
        options.polish = (settings.polishEnabled && settings.polishSupported)
            ? settings.polishParameters : nil

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
        errorMessage = (error as? VoxScriptaError)?.errorDescription ?? error.localizedDescription
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
            let name = summary.displayName
            errorMessage = String(localized: "“\(name)” is still being transcribed. Stop it first, then delete it.")
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

        // One literal per case rather than concatenated fragments: Foundation
        // builds the lookup key from the literal, so a string assembled with +
        // is never translated. The path goes on its own line via a second
        // interpolation so translators do not have to preserve an escape.
        let newline = "\n\n"
        if let kept = plan.originalKept {
            let path = kept.path
            return String(localized: "The transcripts and working files move to the Trash, freeing \(size).\(newline)Your recording stays where it is:\n\(path)")
        }
        if plan.removesAudioCopy {
            return String(localized: "This project holds its own copy of the audio, so the copy goes to the Trash along with the transcripts, freeing \(size).\(newline)Any recording you imported from elsewhere is untouched.")
        }
        return String(localized: "The transcripts and working files move to the Trash, freeing \(size).")
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
            errorMessage = (error as? VoxScriptaError)?.errorDescription ?? error.localizedDescription
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
        // The two platforms spell the clipboard differently and agree on
        // nothing else about it.
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif

        let words = transcript.wordCount
        let count = words.formatted()
        copyConfirmation = words == 1
            ? String(localized: "Copied 1 word")
            : String(localized: "Copied \(count) words")
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

    // ── Polish cost ─────────────────────────────────────────────────────────

    /// Seconds of polishing per second of recording.
    ///
    /// Measured, not guessed: seventeen minutes of Spanish took twenty-three
    /// minutes to polish — 179 sentences at one model call each, about 7.8
    /// seconds a sentence. Transcription runs at 120× real time, so polish is
    /// slower than the recording by two orders of magnitude more than
    /// everything else put together, and it is the only stage worth warning
    /// about.
    ///
    /// One measurement, on one machine, with the bundled model. It is used to
    /// set expectations, not to make a promise, which is why the interface
    /// says "about".
    static let polishSecondsPerSecondOfAudio = 1.4

    /// How long polishing this project is expected to take, or `nil` when the
    /// stage will not run.
    var estimatedPolishDuration: Duration? {
        guard settings.polishEnabled, settings.polishSupported,
              let seconds = openProject?.manifest.source.duration.seconds, seconds > 0
        else { return nil }
        return .seconds(seconds * Self.polishSecondsPerSecondOfAudio)
    }

    /// A warning, when polishing will take long enough that silence would be
    /// mistaken for a hang. `nil` when it is quick enough not to matter.
    var polishTimeNotice: String? {
        guard let estimate = estimatedPolishDuration,
              estimate > .seconds(300) else { return nil }
        let formatted = Self.approximate(estimate)
        return String(localized: "Polishing will take about \(formatted) — it makes one request to the language model for every sentence. Transcription finishes long before that, and you can read it while polishing continues.")
    }

    /// Rounded to something a person would say out loud.
    private static func approximate(_ duration: Duration) -> String {
        // Every interpolated value is a String first, so the lookup key uses
        // %@ rather than %lld and the catalogue stays predictable.
        let minutes = Int((Double(duration.components.seconds) / 60).rounded())
        if minutes < 90 {
            let count = minutes.formatted()
            return String(localized: "\(count) minutes")
        }
        let hours = (Double(minutes) / 60 * 2).rounded() / 2
        let count = hours == hours.rounded()
            ? Int(hours).formatted()
            : hours.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(count) hours")
    }

    // ── Languages ───────────────────────────────────────────────────────────

    /// Locales the app offers, loaded once from the engine.
    ///
    /// Asked of the engine rather than hardcoded. The previous list named three
    /// English variants and was wrong twice over: it omitted locales the engine
    /// supports, and it would have gone stale the moment the OS added one.
    private(set) var availableLocales: [LocaleOption] = []

    struct LocaleOption: Identifiable, Hashable, Sendable {
        let identifier: String
        let displayName: String
        /// False when the engine can transcribe this locale but the text
        /// stages have no lexicons for it, so Clean and Polished are
        /// unavailable and only Verbatim is produced.
        let hasTextSupport: Bool
        var id: String { identifier }
    }

    /// Fills `availableLocales` with the intersection of what the engine
    /// supports and what the app is willing to offer.
    func loadAvailableLocales() async {
        let supported = await AppleSpeechEngine.supportedLocaleIdentifiers()
        let offered = TranscriptLanguage.allCases.flatMap(\.offeredLocales)

        var options = offered.filter(supported.contains).map { identifier in
            LocaleOption(
                identifier: identifier,
                displayName: Self.describe(identifier),
                hasTextSupport: TranscriptLanguage(localeIdentifier: identifier) != nil)
        }
        // Keep whatever the project was built with selectable even if the OS
        // has since dropped it, so an existing project still opens.
        if !options.contains(where: { $0.identifier == settings.locale }) {
            options.append(LocaleOption(identifier: settings.locale,
                                        displayName: Self.describe(settings.locale),
                                        hasTextSupport: settings.transcriptLanguage != nil))
        }
        availableLocales = options
    }

    /// "Spanish (Mexico)", in the user's own language.
    private static func describe(_ identifier: String) -> String {
        let current = Locale.current
        let locale = Locale(identifier: identifier)
        guard let code = locale.language.languageCode?.identifier,
              let language = current.localizedString(forLanguageCode: code) else {
            return identifier
        }
        let name = language.prefix(1).uppercased() + language.dropFirst()
        guard let region = locale.region?.identifier,
              let regionName = current.localizedString(forRegionCode: region) else {
            return name
        }
        return "\(name) (\(regionName))"
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

    /// The export waiting for the user to choose a destination.
    private(set) var pendingExport: (document: ExportDocument, filename: String)?
    var isExporting: Bool {
        get { pendingExport != nil }
        set { if !newValue { pendingExport = nil } }
    }

    /// Prepares the visible transcript in `format` and asks where to put it.
    ///
    /// The bytes are produced before the sheet opens rather than after it
    /// closes, so a failure to render is reported immediately instead of
    /// after the user has chosen a filename.
    func export(_ format: ExportFormat) {
        guard let transcript = currentTranscript, let project = openProject else { return }
        let base = URL(filePath: project.manifest.source.displayName)
            .deletingPathExtension().lastPathComponent
        let exporter = Exporters.make(format)

        do {
            var options = ExportOptions.default
            options.includeTimestamps = exportIncludesTimestamps
            let data = try exporter.export(transcript, options: options)
            pendingExport = (ExportDocument(data: data, contentType: .data),
                             exporter.filename(base: base, variant: selectedVariant))
        } catch {
            errorMessage = (error as? VoxScriptaError)?.errorDescription ?? error.localizedDescription
        }
    }

    func exportFinished(_ result: Result<URL, any Error>) {
        pendingExport = nil
        if case .failure(let error) = result {
            errorMessage = error.localizedDescription
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

        pendingFolderAction = .renderSilenceRemoved(base: base)
    }

    /// What a chosen folder is for.
    ///
    /// Both of these write several files or a file plus its sidecar, so they
    /// ask for a folder rather than a filename — which is also the one file
    /// dialog that behaves the same on both platforms.
    enum FolderAction: Equatable {
        case exportEveryVariant
        case renderSilenceRemoved(base: String)
    }

    private(set) var pendingFolderAction: FolderAction?
    var isChoosingFolder: Bool {
        get { pendingFolderAction != nil }
        set { if !newValue { pendingFolderAction = nil } }
    }

    func folderPicked(_ result: Result<[URL], any Error>) {
        let action = pendingFolderAction
        pendingFolderAction = nil
        guard case .success(let urls) = result, let directory = urls.first else {
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            return
        }
        switch action {
        case .exportEveryVariant: writeEveryVariant(into: directory)
        case .renderSilenceRemoved(let base): renderSilenceRemoved(base: base, into: directory)
        case nil: break
        }
    }

    private func renderSilenceRemoved(base: String, into directory: URL) {
        guard let project = openProject, let map = silenceMap else { return }
        let scoped = directory.startAccessingSecurityScopedResource()
        let url = directory.appending(path: "\(base) — silence removed.wav")

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
                errorMessage = (error as? VoxScriptaError)?.errorDescription
                    ?? error.localizedDescription
            }
            if scoped { directory.stopAccessingSecurityScopedResource() }
            isRendering = false
        }
    }

    /// Writes every available format for every produced variant, into one folder.
    func exportAll() {
        guard openProject != nil else { return }
        pendingFolderAction = .exportEveryVariant
    }

    private func writeEveryVariant(into directory: URL) {
        guard let project = openProject else { return }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }

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
            #if os(macOS)
            NSWorkspace.shared.open(directory)
            #endif
        } catch {
            errorMessage = (error as? VoxScriptaError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reveal(_ summary: ProjectSummary) {
        // Revealing a file in a file manager is a desktop idea. iOS has no
        // equivalent, and the control that calls this is hidden there rather
        // than being wired to something that does nothing.
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([summary.url])
        #endif
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
