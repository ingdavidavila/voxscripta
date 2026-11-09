import SwiftUI

/// Signing in: Apple, Google, or an email and password.
///
/// Reachable, dismissible, and never compulsory. The app transcribes with no
/// account and no network, and Review Guideline 5.1.1(i) refuses apps that
/// demand personal information for features that do not need it — so "Not
/// Now" is always there and always takes no for an answer.
struct SignInView: View {
    let model: AuthModel
    var onFinished: () -> Void = {}
    var onSkip: (() -> Void)?

    @State private var email = ""
    @State private var password = ""
    @State private var isShowingSignUp = false
    @State private var isShowingReset = false

    var body: some View {
        Form {
            Section {
                Text(Strings.signInSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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

                PasswordField(
                    title: Strings.passwordField,
                    text: $password,
                    textContentType: .password)
                FieldError(message: model.passwordError)

                Button(Strings.forgotPassword) { isShowingReset = true }
                    .linkButtonStyle()
                    .disabled(model.isBusy)
            }

            Section {
                Button {
                    Task { if await model.signIn(email: email, password: password) { onFinished() } }
                } label: {
                    Text(Strings.signIn).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)

                OrDivider()
                ProviderButtons(model: model, onFinished: onFinished)
            }

            Section {
                HStack {
                    Text(Strings.noAccountYet).foregroundStyle(.secondary)
                    Button(Strings.signUp) { isShowingSignUp = true }
                        .linkButtonStyle()
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Strings.signIn)
        .toolbar {
            if let onSkip {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.notNow) { onSkip() }
                        .disabled(model.isBusy)
                }
            }
        }
        .overlay { if model.isBusy { ProgressView() } }
        .sheet(isPresented: $isShowingSignUp) {
            NavigationStack {
                SignUpView(model: model, onFinished: {
                    isShowingSignUp = false
                    onFinished()
                })
            }
        }
        .sheet(isPresented: $isShowingReset) {
            NavigationStack {
                ForgotPasswordView(model: model, initialEmail: email)
            }
        }
        .onAppear { model.clearErrors() }
    }
}
