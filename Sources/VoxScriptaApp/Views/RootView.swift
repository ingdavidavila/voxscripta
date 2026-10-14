import SwiftUI
import UniformTypeIdentifiers
import VoxScriptaCore

/// The window: a library on the left, the work on the right.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
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
        .toolbar { toolbarContent }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
            Button { model.presentImportPanel() } label: {
                Label(Strings.openAudio, systemImage: "waveform.badge.plus")
            }
            .disabled(model.isRunning)
            .help(Strings.openAudioHelp)
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

/// States the privacy guarantee where it can be seen.
///
/// §26 asks for this to be a visible product feature. It reflects the binary's
/// actual capability rather than a hardcoded label.
struct PrivacyBadge: View {
    var body: some View {
        Label(Strings.onThisMac, systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(Strings.privacyBadgeHelp)
    }
}

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selectedProjectID) {
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
        // Delete key on the selection, as a Mac list is expected to behave.
        // It belongs on the List, which is what actually holds focus.
        .onDeleteCommand {
            guard let id = model.selectedProjectID,
                  let project = model.projects.first(where: { $0.id == id })
            else { return }
            model.requestDelete(project)
        }
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
