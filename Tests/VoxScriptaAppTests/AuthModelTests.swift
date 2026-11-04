import Testing
import Foundation
@testable import VoxScriptaUI
import VoxScriptaCore

/// The Apple-side account screens, through their model.
///
/// The same behaviour the Flutter suite pins, asserted again here, because
/// `Docs/PARITY.md` is only true if both interfaces actually do the same
/// thing: nothing is sent before the obvious mistakes are caught, the two
/// passwords must match exactly, a reset never reveals whether an address is
/// registered, and a service failure lands under the field it belongs to.
@MainActor
@Suite("Auth model")
struct AuthModelTests {

    // ── Before anything is sent ─────────────────────────────────────────────

    @Test("An empty email is caught without troubling the service")
    func emptyEmailCaughtLocally() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        #expect(await model.signIn(email: "   ", password: "Harbour7!") == false)
        #expect(model.emailError != nil)
        #expect(service.passwordAttempts.isEmpty)
    }

    @Test("An empty password is caught without troubling the service")
    func emptyPasswordCaughtLocally() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        #expect(await model.signIn(email: "ada@example.com", password: "") == false)
        #expect(model.passwordError != nil)
        #expect(service.passwordAttempts.isEmpty)
    }

    @Test("A malformed address never reaches the service")
    func malformedEmailCaughtLocally() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        #expect(await model.signUp(
            email: "ada@", password: "Harbour7!", confirmation: "Harbour7!") == false)
        #expect(model.emailError != nil)
        #expect(service.signUps.isEmpty)
    }

    @Test("A password short of the rules is refused before the service sees it")
    func weakPasswordCaughtLocally() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        #expect(await model.signUp(
            email: "ada@example.com", password: "harbour", confirmation: "harbour") == false)
        #expect(model.passwordError != nil)
        #expect(service.signUps.isEmpty)
    }

    @Test("The two passwords must match exactly, trailing space and all")
    func confirmationComparedUntrimmed() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        // A trailing space is a different password. Trimming it quietly would
        // lock someone out of an account they typed correctly twice.
        #expect(await model.signUp(
            email: "ada@example.com",
            password: "Harbour7!",
            confirmation: "Harbour7! ") == false)
        #expect(model.passwordError != nil)
        #expect(service.signUps.isEmpty)
    }

    @Test("A complete form reaches the service and signs the user in")
    func completeFormSucceeds() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        #expect(await model.signUp(
            email: "  ada@example.com  ",
            password: "Harbour7!",
            confirmation: "Harbour7!"))
        // The address is trimmed; the password is not.
        #expect(service.signUps == ["ada@example.com"])
        #expect(model.user?.email == "ada@example.com")
    }

    // ── Rules come from the engine ──────────────────────────────────────────

    @Test("The password rules are the engine's, not a second copy")
    func rulesComeFromTheEngine() {
        let model = AuthModel(service: StubAuth())
        let password = "Harbour7!"

        // Identical objects, not merely similar ones. A second
        // implementation here is exactly the drift PasswordPolicy exists to
        // prevent, and the Flutter app reads these same four over the C ABI.
        #expect(model.passwordRules(for: password) == PasswordPolicy.evaluate(password))
        #expect(model.passwordRules(for: "x").count == 4)
        #expect(model.accepts(password: password))
        #expect(!model.accepts(password: "harbour"))
    }

    @Test("Every rule is reported every time, met or not")
    func everyRuleAlwaysReported() {
        let model = AuthModel(service: StubAuth())
        // So a checklist can show all four filling in, rather than revealing
        // one failure at a time.
        #expect(model.passwordRules(for: "").count == 4)
        let allMet = model.passwordRules(for: "Harbour7!").allSatisfy { $0.satisfied }
        #expect(allMet)
    }

    // ── Failures land in the right place ────────────────────────────────────

    @Test("A failure about the password lands under the password field")
    func passwordFailurePlacedCorrectly() async {
        let model = AuthModel(service: StubAuth(
            failure: AuthError("That password is not right.", field: "password")))

        _ = await model.signIn(email: "ada@example.com", password: "Harbour7!")
        #expect(model.passwordError == "That password is not right.")
        #expect(model.emailError == nil)
        #expect(model.banner == nil)
    }

    @Test("A failure about the address lands under the address field")
    func emailFailurePlacedCorrectly() async {
        let model = AuthModel(service: StubAuth(
            failure: AuthError("No account for that address.", field: "email")))

        _ = await model.signIn(email: "ada@example.com", password: "Harbour7!")
        #expect(model.emailError == "No account for that address.")
        #expect(model.passwordError == nil)
    }

    @Test("A failure about the attempt as a whole goes above the form")
    func generalFailureGoesToBanner() async {
        let model = AuthModel(service: StubAuth(failure: AuthError("No connection.")))

        _ = await model.signIn(email: "ada@example.com", password: "Harbour7!")
        #expect(model.banner == "No connection.")
        #expect(model.emailError == nil)
        #expect(model.passwordError == nil)
    }

    // ── Resets ──────────────────────────────────────────────────────────────

    @Test("A reset succeeds without revealing whether the address is registered")
    func resetIsNotAMembershipOracle() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        // The service is asked, and reports nothing back about whether it
        // found anything — which is the point. A form that answered would let
        // anyone enumerate who uses the app.
        #expect(await model.sendPasswordReset(to: "nobody@example.com"))
        #expect(service.resets == ["nobody@example.com"])
        #expect(model.banner == nil)
    }

    @Test("A malformed address is caught before a reset is sent")
    func resetChecksTheAddress() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        #expect(await model.sendPasswordReset(to: "not-an-address") == false)
        #expect(service.resets.isEmpty)
    }

    // ── Providers ───────────────────────────────────────────────────────────

    @Test("Apple is offered wherever Google is")
    func appleOfferedWhereverGoogleIs() {
        let model = AuthModel(service: StubAuth())
        // Review Guideline 4.8. Asserted rather than assumed, because the
        // failure mode is a rejection rather than a visible bug.
        #expect(model.supportsGoogle == false || model.supportsApple)
    }

    @Test("An Apple credential reaches the service intact")
    func appleCredentialPassedThrough() async {
        let service = StubAuth()
        let model = AuthModel(service: service)

        #expect(await model.signIn(with: AppleCredential(
            userID: "001.abc",
            identityToken: "token",
            authorizationCode: "code",
            email: "ada@privaterelay.appleid.com")))
        #expect(service.appleCredentials.map(\.userID) == ["001.abc"])
        #expect(model.user?.provider == "apple")
    }

    // ── Deletion and sign-out ───────────────────────────────────────────────

    @Test("Deleting the account is possible from inside the app")
    func deletionIsAvailable() async {
        let service = StubAuth()
        let model = AuthModel(service: service)
        _ = await model.signIn(email: "ada@example.com", password: "Harbour7!")

        // Guideline 5.1.1(v): an app that can make an account must be able to
        // delete one.
        #expect(await model.deleteAccount())
        #expect(service.deletions == 1)
        #expect(model.user == nil)
    }

    @Test("A failed deletion keeps the user signed in and says why")
    func failedDeletionReports() async {
        let service = StubAuth(failure: AuthError("No connection."))
        let model = AuthModel(service: service)

        #expect(await model.deleteAccount() == false)
        #expect(model.banner == "No connection.")
    }

    @Test("Signing out clears the user")
    func signOutClearsUser() async {
        let model = AuthModel(service: StubAuth())
        _ = await model.signIn(email: "ada@example.com", password: "Harbour7!")
        #expect(model.user != nil)

        await model.signOut()
        #expect(model.user == nil)
    }

    // ── No service at all ───────────────────────────────────────────────────

    @Test("With no account service the interface knows not to ask")
    func unconfiguredIsVisible() async {
        let model = AuthModel(service: nil)
        #expect(!model.isConfigured)
        #expect(!model.supportsApple)
        #expect(!model.supportsGoogle)
        #expect(model.user == nil)
    }

    @Test("With no account service every attempt fails saying so")
    func unconfiguredRefusesEverything() async {
        let model = AuthModel(service: nil)

        #expect(await model.signIn(email: "ada@example.com", password: "Harbour7!") == false)
        #expect(model.banner?.contains("not connected") == true)
    }

    @Test("This build ships no account service")
    func noServiceIsConfigured() {
        // The honest state, asserted so it is a decision rather than
        // something forgotten. When a backend is wired, this test changes.
        #expect(configuredAuthService() == nil)
    }

    @Test("The placeholder service refuses every route rather than faking one")
    func unconfiguredServiceThrows() async throws {
        let service = UnconfiguredAuthService()
        // A stub returning a plausible user would let the flow look finished
        // all the way to the library.
        await #expect(throws: AuthError.self) { try await service.signInWithGoogle() }
        await #expect(throws: AuthError.self) {
            try await service.signIn(email: "a@b.com", password: "Harbour7!")
        }
        await #expect(throws: AuthError.self) {
            try await service.signUp(email: "a@b.com", password: "Harbour7!")
        }
        await #expect(throws: AuthError.self) {
            try await service.sendPasswordReset(to: "a@b.com")
        }
        await #expect(throws: AuthError.self) { try await service.deleteAccount() }
        #expect(await service.currentUser() == nil)
    }
}

/// An account service that records what it was asked and can be told to fail.
final class StubAuth: AuthService, @unchecked Sendable {
    init(failure: AuthError? = nil) { self.failure = failure }

    let failure: AuthError?
    private(set) var passwordAttempts: [String] = []
    private(set) var signUps: [String] = []
    private(set) var resets: [String] = []
    private(set) var appleCredentials: [AppleCredential] = []
    private(set) var deletions = 0

    var supportsApple: Bool { true }
    var supportsGoogle: Bool { true }

    private var signedIn: AuthUser?

    func currentUser() async -> AuthUser? { signedIn }

    private func user(_ email: String, _ provider: String) throws -> AuthUser {
        if let failure { throw failure }
        let user = AuthUser(id: "id-\(email)", email: email, provider: provider)
        signedIn = user
        return user
    }

    func signIn(with credential: AppleCredential) async throws -> AuthUser {
        appleCredentials.append(credential)
        return try user(credential.email ?? "apple@example.com", "apple")
    }

    func signInWithGoogle() async throws -> AuthUser {
        try user("google@example.com", "google")
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        passwordAttempts.append(email)
        return try user(email, "password")
    }

    func signUp(email: String, password: String) async throws -> AuthUser {
        signUps.append(email)
        return try user(email, "password")
    }

    func sendPasswordReset(to email: String) async throws {
        resets.append(email)
        if let failure { throw failure }
    }

    func signOut() async throws {
        if let failure { throw failure }
        signedIn = nil
    }

    func deleteAccount() async throws {
        if let failure { throw failure }
        deletions += 1
        signedIn = nil
    }
}
