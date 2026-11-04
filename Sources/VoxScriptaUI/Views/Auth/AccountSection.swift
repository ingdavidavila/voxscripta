import SwiftUI

/// The account rows in Settings: sign in, or manage the account you have.
///
/// Settings is the only place the app mentions accounts, which is the right
/// size for something nothing in the pipeline depends on. There is no gate at
/// launch, for the same reason the Flutter app has none: transcription needs
/// no account, and Review Guideline 5.1.1(i) refuses apps that require
/// personal information for features that do not need it.
struct AccountSection: View {
    let auth: AuthModel

    @State private var isShowingSignIn = false
    @State private var isShowingAccount = false

    var body: some View {
        Section(Strings.account) {
            if let user = auth.user {
                Button {
                    isShowingAccount = true
                } label: {
                    LabeledContent(Strings.signedInAs) { Text(user.email) }
                }
                .buttonStyle(.plain)
            } else {
                Button(Strings.signIn) { isShowingSignIn = true }
                Text(Strings.signInSubtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await auth.refresh() }
        .sheet(isPresented: $isShowingSignIn) {
            NavigationStack {
                SignInView(
                    model: auth,
                    onFinished: { isShowingSignIn = false },
                    onSkip: { isShowingSignIn = false })
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 540)
            #endif
        }
        .sheet(isPresented: $isShowingAccount) {
            NavigationStack {
                if let user = auth.user {
                    AccountView(
                        model: auth,
                        user: user,
                        onSignedOut: { isShowingAccount = false })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(Strings.done) { isShowingAccount = false }
                        }
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 360)
            #endif
        }
    }
}
