import SwiftUI

/// The signed-in account: who it is, how to leave, how to delete it.
///
/// Deletion is a button here, on the same screen as the account, rather than
/// a page on a website. App Store Review Guideline 5.1.1(v) requires any app
/// that lets an account be created to let it be deleted from inside the app,
/// and Google Play requires a deletion route as well.
struct AccountView: View {
    let model: AuthModel
    let user: AuthUser
    var onSignedOut: () -> Void = {}

    @State private var isConfirmingDelete = false

    var body: some View {
        Form {
            if let banner = model.banner {
                Section { AuthBanner(message: banner) }
            }

            Section {
                LabeledContent(Strings.signedInAs) {
                    Text(user.email).textSelection(.enabled)
                }
                LabeledContent(Strings.signedInWith) {
                    Text(Self.providerName(user.provider))
                }
            }

            Section {
                Button(Strings.signOut) {
                    Task {
                        await model.signOut()
                        if model.user == nil { onSignedOut() }
                    }
                }
                .disabled(model.isBusy)
            } footer: {
                Text(Strings.signOutKeepsWork)
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Text(Strings.deleteAccount)
                }
                .disabled(model.isBusy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Strings.account)
        .overlay { if model.isBusy { ProgressView() } }
        .confirmationDialog(
            Strings.deleteAccountTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(Strings.deleteAccount, role: .destructive) {
                Task { if await model.deleteAccount() { onSignedOut() } }
            }
            Button(Strings.keepAccount, role: .cancel) {}
        } message: {
            // Says what is *not* deleted as well as what is. Someone about to
            // press a button marked Delete assumes the worst about their
            // recordings, and here the worst is not true.
            #if os(macOS)
            Text(Strings.deleteAccountBody)
            #else
            Text(Strings.deleteAccountBodyPhone)
            #endif
        }
    }

    private static func providerName(_ provider: String) -> LocalizedStringKey {
        switch provider {
        case "apple": "Apple"
        case "google": "Google"
        case "password": "An email address and password"
        default: LocalizedStringKey(provider)
        }
    }
}
