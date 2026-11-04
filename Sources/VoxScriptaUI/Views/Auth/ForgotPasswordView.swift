import SwiftUI

/// Asking for a reset link.
///
/// The confirmation is deliberately the same whether or not the address has
/// an account. Telling an anonymous visitor which addresses are registered
/// turns this form into a membership oracle — type addresses, learn who uses
/// the app — and that is a worse leak than the inconvenience it saves.
struct ForgotPasswordView: View {
    let model: AuthModel
    var initialEmail: String = ""

    @State private var email = ""
    @State private var isSent = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if isSent {
                Section {
                    Label {
                        Text(Strings.resetSent)
                    } icon: {
                        Image(systemName: "envelope")
                    }
                }
            } else {
                if let banner = model.banner {
                    Section { AuthBanner(message: banner) }
                }
                Section {
                    TextField(Strings.emailField, text: $email)
                        .textFieldStyle(.roundedBorder)
                        .contentType(.email)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                    FieldError(message: model.emailError)
                }
                Section {
                    Button {
                        Task {
                            if await model.sendPasswordReset(to: email) { isSent = true }
                        }
                    } label: {
                        Text(Strings.sendResetLink).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Strings.resetPassword)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isSent ? Strings.done : Strings.cancel) { dismiss() }
                    .disabled(model.isBusy)
            }
        }
        .overlay { if model.isBusy { ProgressView() } }
        .onAppear {
            model.clearErrors()
            if email.isEmpty { email = initialEmail }
        }
    }
}
