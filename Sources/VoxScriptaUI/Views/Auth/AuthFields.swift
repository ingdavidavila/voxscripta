import AuthenticationServices
import SwiftUI
import VoxScriptaCore

/// A password field with its own reveal toggle.
///
/// Its own view, holding its own `isRevealed`, because SwiftUI swaps
/// `SecureField` for `TextField` when the toggle flips. Keeping that state
/// local means the swap happens inside one subtree; hoisting it to the parent
/// rebuilds the whole form and the caret lands back at the start of the text,
/// which is maddening three-quarters of the way through typing a password.
struct PasswordField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var textContentType: UITextContentTypeCompat

    @State private var isRevealed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .contentType(textContentType)
            .focused($isFocused)
            #if !os(macOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()

            Button {
                isRevealed.toggle()
                // Typing should continue where it left off, not restart.
                isFocused = true
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? Strings.hidePassword : Strings.showPassword)
            .accessibilityLabel(isRevealed ? Strings.hidePassword : Strings.showPassword)
        }
    }
}

/// `UITextContentType` does not exist on macOS, and the two platforms spell
/// the modifier differently. One shim rather than `#if` at every call site.
enum UITextContentTypeCompat {
    case password
    case newPassword
    case email
}

extension View {
    @ViewBuilder
    func contentType(_ type: UITextContentTypeCompat) -> some View {
        #if os(macOS)
        switch type {
        case .password: self.textContentType(.password)
        case .newPassword: self.textContentType(.newPassword)
        case .email: self.textContentType(.username)
        }
        #else
        switch type {
        case .password: self.textContentType(.password)
        case .newPassword: self.textContentType(.newPassword)
        case .email: self.textContentType(.emailAddress)
        }
        #endif
    }
}

/// Every password rule, each ticked or not.
///
/// All four are shown from the moment the field appears, not revealed one
/// failure at a time. Someone choosing a password should be able to see what
/// is being asked before they start guessing at it.
struct PasswordChecklist: View {
    let rules: [PasswordPolicy.Rule]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.passwordRequirements)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(rules, id: \.id) { rule in
                Label {
                    Text(rule.demand)
                        .font(.caption)
                        .foregroundStyle(rule.satisfied ? .secondary : .primary)
                } icon: {
                    Image(systemName: rule.satisfied ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(rule.satisfied ? Color.accentColor : .secondary)
                }
                .accessibilityLabel(Text(rule.demand))
                .accessibilityValue(rule.satisfied
                    ? Text("met", comment: "a password rule the password satisfies")
                    : Text("not met", comment: "a password rule the password does not satisfy"))
            }
        }
    }
}

/// A failure about the attempt as a whole.
struct AuthBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}

/// A failure belonging to one field.
struct FieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Apple and Google, in that order.
///
/// Apple is offered wherever Google is. Review Guideline 4.8 requires an
/// equivalent privacy-preserving option alongside any third-party sign-in
/// that collects personal data, and Sign in with Apple is the one Apple
/// accepts. The real `SignInWithAppleButton` rather than a drawn imitation,
/// because Apple's guidelines govern that button's appearance too.
struct ProviderButtons: View {
    let model: AuthModel
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if model.supportsApple {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email, .fullName]
                } onCompletion: { result in
                    handle(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 44)
                .disabled(model.isBusy)
            }

            if model.supportsGoogle {
                Button {
                    Task {
                        if await model.signInWithGoogle() { onFinished() }
                    }
                } label: {
                    Label(Strings.continueWithGoogle, systemImage: "g.circle")
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
            }
        }
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential
                    as? ASAuthorizationAppleIDCredential,
                let identityData = credential.identityToken,
                let identity = String(data: identityData, encoding: .utf8),
                let codeData = credential.authorizationCode,
                let code = String(data: codeData, encoding: .utf8)
            else {
                // Apple returned an authorization without the tokens an
                // account service needs. Saying so beats signing nobody in
                // and showing nothing.
                model.report(appleFailure: String(localized:
                    "Apple did not return a usable credential. Try again."))
                return
            }
            let name = credential.fullName.map {
                PersonNameComponentsFormatter().string(from: $0)
            }
            Task {
                let signedIn = await model.signIn(with: AppleCredential(
                    userID: credential.user,
                    identityToken: identity,
                    authorizationCode: code,
                    email: credential.email,
                    // Apple sends the name on the first authorization only.
                    fullName: (name?.isEmpty ?? true) ? nil : name))
                if signedIn { onFinished() }
            }
        case .failure(let error):
            // A cancelled sheet is not a failure and must not be shown as
            // one. Everything else is.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            model.report(appleFailure: error.localizedDescription)
        }
    }
}

/// A rule line with "or" through it.
struct OrDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            Text(Strings.orDivider).font(.caption).foregroundStyle(.secondary)
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
        }
    }
}
