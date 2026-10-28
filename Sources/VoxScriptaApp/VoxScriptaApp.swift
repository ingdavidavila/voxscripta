import SwiftUI
import VoxScriptaUI

@main
struct VoxScriptaApp: App {
    @State private var model = AppModel()

    /// The window's contents, shared so the two platforms differ only in the
    /// scenes they declare and not in what those scenes show.
    private var root: some View {
        RootView().environment(model)
    }

    // The scene graphs are written out separately rather than assembled with
    // conditionals inside one body: `#if` cannot wrap a trailing modifier and
    // a following scene in the same block, and SceneBuilder gives a worse
    // error than that sentence does.
    #if os(macOS)
    var body: some Scene {
        WindowGroup {
            root.frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audio…") { model.presentImportPanel() }
                    .keyboardShortcut("o")
            }
        }

        // Settings get their own window here, reached from the app menu.
        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520, height: 420)
        }
    }
    #else
    var body: some Scene {
        // iOS has no Settings scene and no app menu, so the same view is
        // presented as a sheet from the toolbar instead. See RootView.
        WindowGroup { root }
    }
    #endif
}
