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

    #if !os(macOS)
    /// Whether the split view has collapsed to a single column.
    ///
    /// Read here, outside the NavigationSplitView, because that is the only
    /// place it means the window. Inside the sidebar the same environment
    /// value describes *that column*, which is narrow on an iPad showing both
    /// — so a check made there called a two-column iPad compact and drew the
    /// import screen into a 320-point sidebar while the detail pane drew it
    /// again beside it.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isOneColumn: Bool { horizontalSizeClass == .compact }
    #endif

    /// The trial, so the banner can say where it stands and the wall has a
    /// door. The engine refuses work on its own; this is what offers a way
    /// out of that refusal instead of leaving a dead end.
    @State private var entitlement = EntitlementModel()
    @State private var isShowingPaywall = false

    public var body: some View {
        #if os(macOS)
        window
        #else
        // A strip of its own above the navigation stack rather than an inset
        // inside it. The trial is a fact about the app, not about the screen
        // you happen to be looking at, so it holds its place while the list
        // scrolls, while the large title collapses, and while a sheet or a
        // detail view comes and goes. An inset placed inside the stack moves
        // with whatever the stack is showing; one placed around it lands in
        // the navigation bar's own strip, which is the collision this started
        // as.
        VStack(spacing: 0) {
            TrialBanner(model: entitlement) { isShowingPaywall = true }
            window
        }
        #endif
    }

    /// Always false on a Mac, which has two columns by construction.
    private var isOneColumnForSidebar: Bool {
        #if os(macOS)
        false
        #else
        isOneColumn
        #endif
    }

    /// The window proper: the library beside the work, and everything
    /// presented over it.
    private var window: some View {
        @Bindable var model = model

        return NavigationSplitView {
            LibrarySidebar(isOneColumn: isOneColumnForSidebar)
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
        #endif
        // On iOS the recording screen is not presented at all — see
        // `LibrarySidebar`, which shows it in place of the library. A sheet
        // and then a `fullScreenCover` attached here both failed to appear
        // on a phone while the alerts beside them worked, and a Record button
        // that silently does nothing is worse than a screen without a
        // dimmed backdrop.
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
        // Above everything, spanning the window. `safeAreaInset` rather than
        // a VStack so the split view keeps its own layout and the banner does
        // not become a column of it.
        //
        // The Mac only: both columns are on screen there and the banner is
        // meant to span them. A phone has one column and a navigation bar in
        // the same place, so it is attached to the sidebar instead, above.
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            TrialBanner(model: entitlement) { isShowingPaywall = true }
        }
        #endif
        .sheet(isPresented: $isShowingPaywall) {
            NavigationStack {
                PaywallView(model: entitlement)
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 560)
            #endif
        }
        .onAppear { entitlement.start() }
        .onDisappear { entitlement.stop() }
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

        // The Mac only. In a phone's navigation bar a Label is rendered as its
        // icon alone, so this arrived as an unexplained padlock in the corner
        // — a privacy claim reduced to a glyph says nothing. On iOS the same
        // promise is made in words, on the empty state and in Settings.
        #if os(macOS)
        ToolbarItem(placement: .navigation) {
            PrivacyBadge()
        }
        #endif
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

    /// Whether this column is the whole window.
    ///
    /// Passed in rather than read here. The substitutions below are for a
    /// window with nowhere else to put things, and the environment's size
    /// class inside this view describes the *column*, which is narrow on an
    /// iPad that has a detail pane as well.
    var isOneColumn: Bool

    var body: some View {
        #if os(macOS)
        // Two columns: the detail pane beside this one is already showing the
        // import screen, so an empty list only has to say it is empty.
        list
        #else
        // One column, which makes this the first screen, so everything that
        // would be presented over it is shown *as* it instead.
        if model.isShowingRecorder {
            // Shown here whatever the width, because there is nowhere else:
            // the sheet that presents it on a Mac is Mac-only, and a recorder
            // that never appears is worse than one in a narrow column. On an
            // iPad with both columns this is cramped, and that is a thing to
            // improve rather than a thing that is broken.
            RecordingView()
                .navigationTitle(Strings.recordingInProgress)
                .navigationBarBackButtonHidden(true)
        } else if !isOneColumn {
            // Two columns, as on a Mac. The detail pane beside this one is
            // already showing the job or the transcript, so the library stays
            // a library — substituting here would render the workspace twice,
            // once squeezed into a 320-point sidebar.
            list
        } else if model.mode == .processing {
            // In place of the list, for the same reason the recorder is: the
            // detail column these used to live in is never presented on a
            // collapsed split view, so on a phone there was nowhere for a job
            // to be watched or a transcript to be read. Tapping a recording
            // started the work and then showed the library, unchanged, as
            // though nothing had happened.
            ProcessingView()
                .navigationTitle(Strings.recordings)
        } else if model.mode == .transcript {
            TranscriptWorkspace()
                .navigationTitle(Strings.recordings)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Text rather than a Label: a phone's navigation bar
                        // renders a Label as its icon alone, which is how the
                        // privacy badge became an unexplained padlock.
                        Button(Strings.recordings) { model.closeWorkspace() }
                    }
                }
        } else if model.projects.isEmpty {
            // An empty list with nothing to tap is a dead end, so the import
            // screen takes its place until there is something to list.
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
                LibraryEmptyState()
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

/// The library's empty state, written for the width it actually gets.
///
/// `ContentUnavailableView` is designed for a full pane and behaves badly in
/// a column: at 240 points its title truncated to "No recording…" and its
/// description broke a word per line. This only ever appears in a sidebar —
/// a phone shows the import screen in place of an empty list — so it is
/// sized for one rather than borrowing a layout meant for the pane beside it.
///
/// `fixedSize(horizontal:vertical:)` is the part that matters: without it
/// text in a narrow column truncates rather than taking the lines it needs.
private struct LibraryEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(Strings.noRecordings)
                .font(.subheadline.weight(.medium))
            Text(Strings.noRecordingsDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}

struct ProjectRow: View {
    let project: ProjectSummary

    /// What to say about a project's state, or nil when saying nothing is
    /// right: a finished transcript is the expected case and labelling every
    /// row "Transcribed" would be noise on a library where most are.
    static func stateNote(for state: JobState) -> (text: String, tint: Color)? {
        switch state {
        case .complete: nil
        case .failed: (String(localized: "Failed"), .red)
        case .cancelled: (String(localized: "Not finished"), .secondary)
        case .imported: (String(localized: "Not transcribed"), .secondary)
        default: (String(localized: "In progress"), .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.displayName)
                .lineLimit(1)
                .font(.body)
            HStack(spacing: 6) {
                Text(project.duration.description)
                    .monospacedDigit()
                // Whether this one has been transcribed yet. ProjectSummary
                // has carried `state` all along and no interface showed it,
                // so the library listed finished work and abandoned work
                // identically and the only way to tell them apart was to
                // open one.
                if let note = Self.stateNote(for: project.state) {
                    Text("·")
                    Text(note.text).foregroundStyle(note.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
