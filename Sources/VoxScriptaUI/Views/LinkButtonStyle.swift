import SwiftUI

extension View {
    /// Styles a button so it reads as a link.
    ///
    /// `.buttonStyle(.link)` exists only on macOS, and on iOS it is a compile
    /// error rather than a quiet fallback — which is how the auth screens
    /// turned out to be the one part of this interface that had never been
    /// built for a phone. The choice is made here so the three call sites stay
    /// about what the button does.
    @ViewBuilder
    func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.plain).foregroundStyle(Color.accentColor)
        #endif
    }
}
