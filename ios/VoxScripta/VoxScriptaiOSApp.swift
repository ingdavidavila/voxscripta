import SwiftUI
import VoxScriptaUI

/// The iOS entry point.
///
/// Deliberately the whole of the iOS-specific code. Everything the app shows
/// lives in the VoxScriptaUI package target, which the macOS executable
/// consumes the same way — so a change to a screen reaches both platforms
/// without being written twice, and this file stays something a person can
/// read in one go.
///
/// It exists at all because SwiftPM cannot produce an .app for iOS. The
/// package builds libraries; turning those into something a phone can install
/// needs an Xcode target, and an Xcode target needs a @main of its own.
@main
struct VoxScriptaiOSApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
        }
    }
}
