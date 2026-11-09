import SwiftUI
import VoxScriptaCore

/// Creating an account: an email, a password that meets the rules, and the
/// password again.
///
/// The rules come from ``PasswordPolicy`` in the engine, read through
/// ``AuthModel/passwordRules(for:)``. Not reimplemented here — that is the
/// entire reason they live in the engine, so the Flutter app and this one
/// accept exactly the same passwords.
struct SignUpView: View {
    let model: AuthModel
    var onFinished: () -> Void = {}

    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @Environment(\.dismiss) private var dismiss

    private var rules: [PasswordPolicy.Rule] {
        model.passwordRules(for: password)
    }

    var body: some View {
        Form {
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
                PasswordField(
                    title: Strings.passwordField,
                    text: $password,
                    textContentType: .newPassword)
                PasswordChecklist(rules: rules)

                PasswordField(
                    title: Strings.confirmPasswordField,
                    text: $confirmation,
                    textContentType: .newPassword)
                FieldError(message: model.passwordError)
            }

            Section {
                Button {
                    Task {
                        let made = await model.signUp(
                            email: email,
                            password: password,
                            confirmation: confirmation)
                        if made { onFinished() }
                    }
                } label: {
                    Text(Strings.signUp).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)

                OrDivider()
                ProviderButtons(model: model, onFinished: onFinished)
            }

            Section {
                HStack {
                    Text(Strings.haveAccount).foregroundStyle(.secondary)
                    Button(Strings.signIn) { dismiss() }
                        .linkButtonStyle()
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Strings.signUp)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(Strings.cancel) { dismiss() }.disabled(model.isBusy)
            }
        }
        .overlay { if model.isBusy { ProgressView() } }
        .onAppear { model.clearErrors() }
    }
}
