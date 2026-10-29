import SwiftUI
import UniformTypeIdentifiers
import VoxScriptaCore

/// The window: a library on the left, the work on the right.
public struct RootView: View {
    /// Public so the app shells — this package's executable and the iOS
    /// Xcode target — can construct it from outside the module.
    public init() {}

    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    public var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Group {
                switch model.mode {
                case .empty: ImportView()
                case .processing: ProcessingView()
                case .transcript: TranscriptWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // On the Mac both columns are on screen and the window has one toolbar.
        // On a phone the split view collapses to the sidebar alone, and a
        // toolbar attached here lands in the detail column — which is to say,
        // off screen. Running it on the sidebar is the only way the Record
        // button exists at all on the device the Record button is for.
        #if os(macOS)
        .toolbar { RootToolbar() }
        #endif
        // Drag and drop anywhere in the window, per §25: drop a file, get a
        // transcript. The drop target is the whole window rather than a small
        // well, because aiming at a well is a needless bit of precision.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        #if !os(macOS)
        .sheet(isPresented: $model.isShowingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(Strings.done) { model.isShowingSettings = false }
                        }
                    }
            }
        }
        #endif
        // Presented over everything rather than being a mode of the main pane:
        // recording is a thing you are doing, not a thing you are looking at.
        //
        // Full screen on iOS for two reasons. It is the right shape — the
        // timer and the meter are the only things that matter while the
        // microphone is open — and a second `.sheet` on the same view as the
        // settings sheet simply does not present, which is how this was
        // found: the recorder started and nothing appeared.
        #if os(macOS)
        .sheet(isPresented: $model.isShowingRecorder) {
            RecordingView()
                .frame(minWidth: 380, minHeight: 360)
        }
        #else
        .fullScreenCover(isPresented: $model.isShowingRecorder) {
            RecordingView()
        }
        #endif
        .alert(Strings.microphoneNeeded, isPresented: $model.isMicrophoneDenied) {
            Button(Strings.openSystemSettings) { model.openMicrophoneSettings() }
                .help(Strings.openSystemSettingsHelp)
            Button(Strings.cancel, role: .cancel) { model.isMicrophoneDenied = false }
                .help(Strings.dismissHelp)
        } message: {
            Text(VoxScriptaError.microphoneDenied.errorDescription ?? "")
        }
        // The three file dialogs. They belong on the root rather than beside
        // the buttons that raise them, because the model owns the request and
        // the window owns the presentation — and because an export can be
        // started from a toolbar that is not on screen on a phone.
        //
        // Their absence is how a working Open and Download turned into two
        // buttons that set a flag and did nothing: the model kept the state
        // when the AppKit panels were replaced, and nothing ever presented it.
        .fileImporter(isPresented: $model.isImportingAudio,
                      allowedContentTypes: AppModel.importableContentTypes) { result in
            model.importPicked(result.map { [$0] })
        }
        .fileExporter(isPresented: $model.isExporting,
                      document: model.pendingExport?.document,
                      contentType: .data,
                      defaultFilename: model.pendingExport?.filename) { result in
            model.exportFinished(result)
        }
        .fileImporter(isPresented: $model.isChoosingFolder,
                      allowedContentTypes: [.folder]) { result in
            model.folderPicked(result.map { [$0] })
        }
        .alert(Strings.somethingWrong,
               isPresented: .constant(model.errorMessage != nil)) {
            Button(Strings.ok) { model.dismissError() }
                .help(Strings.dismissHelp)
        } message: {
            Text(model.errorMessage ?? "")
        }
        // Names what will actually happen rather than asking "are you sure?" —
        // what deleting removes depends on how the recording was imported.
        .alert("Delete “\(model.pendingDeletion?.plan.projectName ?? "")”?",
               isPresented: .constant(model.pendingDeletion != nil)) {
            Button(Strings.moveToTrash, role: .destructive) { model.confirmDelete() }
                .help(Strings.moveToTrashHelp)
            Button(Strings.cancel, role: .cancel) { model.cancelDelete() }
                .help(Strings.keepRecordingHelp)
        } message: {
            Text(model.deletionMessage)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isRunning, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.importAudio(at: url) }
        }
        return true
    }
}

/// The actions that are always available, wherever the platform puts them.
///
/// One definition rather than two: the Mac hangs it on the window and the
/// phone hangs it on the only column it has, and an action added here cannot
/// go missing from one of them.
struct RootToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {

        ToolbarItem(placement: .navigation) {
            PrivacyBadge()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isRunning {
                Button(role: .cancel) { model.cancel() } label: {
                    Label(Strings.stop, systemImage: "stop.fill")
                }
                .help(Strings.stopHelp)
            }
            Button { model.beginRecording() } label: {
                Label(Strings.record, systemImage: "mic.fill")
            }
            .disabled(model.isRunning || model.recorder.state.isActive)
            .help(Strings.recordHelp)

            Button { model.presentImportPanel() } label: {
                Label(Strings.openAudio, systemImage: "waveform.badge.plus")
            }
            .disabled(model.isRunning)
            .help(Strings.openAudioHelp)

            #if !os(macOS)
            Button { model.isShowingSettings = true } label: {
                Label(Strings.settings, systemImage: "gearshape")
            }
            #endif
        }
    
    }
}

/// States the privacy guarantee where it can be seen.
///
/// §26 asks for this to be a visible product feature. It reflects the binary's
/// actual capability rather than a hardcoded label.
struct PrivacyBadge: View {
    var body: some View {
        Label(Strings.onThisMachine(), systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(Strings.privacyBadgeHelp())
    }
}

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        // Two columns: the detail pane beside this one is already showing the
        // import screen, so an empty list only has to say it is empty.
        list
        #else
        // One column, which makes this the first screen. An empty list with
        // nothing to tap is a dead end, so the import screen takes its place
        // until there is something to list.
        if model.projects.isEmpty {
            ImportView()
                .navigationTitle(Strings.recordings)
                .toolbar { RootToolbar() }
        } else {
            list
        }
        #endif
    }

    private var list: some View {
        @Bindable var model = model

        return List(selection: $model.selectedProjectID) {
            if model.projects.isEmpty {
                ContentUnavailableView(Strings.noRecordings,
                                       systemImage: "waveform",
                                       description: Text(Strings.noRecordingsDetail))
                .listRowSeparator(.hidden)
            } else {
                Section(Strings.recordings) {
                    ForEach(model.projects) { project in
                        ProjectRow(project: project)
                            .tag(project.id)
                            .help("\(project.displayName) · \(project.duration). "
                                  + "Click to open its transcript.")
                            .contextMenu {
                                Button(Strings.showInFinder) { model.reveal(project) }
                                    .help(Strings.showInFinderHelp)
                                Divider()
                                Button(Strings.deleteEllipsis, role: .destructive) {
                                    model.requestDelete(project)
                                }
                                .help(Strings.deleteHelp)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(Strings.recordings)
        #if !os(macOS)
        .toolbar { RootToolbar() }
        #endif
        // Delete key on the selection, as a Mac list is expected to behave.
        // It belongs on the List, which is what actually holds focus. There
        // is no key to press on a phone; the context menu carries the action
        // there, and a swipe would be the idiomatic addition later.
        #if os(macOS)
        .onDeleteCommand {
            guard let id = model.selectedProjectID,
                  let project = model.projects.first(where: { $0.id == id })
            else { return }
            model.requestDelete(project)
        }
        #endif
        // Driven by selection rather than a tap gesture. A List with a selection
        // binding consumes taps for its own hit testing, so an `onTapGesture` on
        // the row never fires — and reacting to selection means arrow-key
        // navigation opens projects too.
        .onChange(of: model.selectedProjectID) { _, id in
            guard let id, let project = model.projects.first(where: { $0.id == id }) else { return }
            model.openIfNeeded(project)
        }
    }
}

struct ProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.displayName)
                .lineLimit(1)
                .font(.body)
            Text(project.duration.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}
