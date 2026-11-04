import Foundation
import Observation
import SwiftUI
import VoxScriptaCore

/// The account screens' state, and the only place they talk to the service.
///
/// `@MainActor` throughout, like ``AppModel``: every property is read during
/// layout, so isolating the type removes a class of races rather than
/// guarding fields one at a time.
@MainActor
@Observable
public final class AuthModel {

    public init(service: (any AuthService)? = configuredAuthService()) {
        self.service = service
    }

    /// Nil when this build has no account service. The interface then never
    /// asks anyone to sign in.
    public let service: (any AuthService)?

    public private(set) var user: AuthUser?
    public private(set) var isBusy = false

    /// A failure about the attempt as a whole, shown above the fields.
    public private(set) var banner: String?
    /// A failure belonging to one field, shown under it.
    public private(set) var emailError: String?
    public private(set) var passwordError: String?

    /// Whether an account service exists at all.
    public var isConfigured: Bool { service != nil }

    public var supportsApple: Bool { service?.supportsApple ?? false }
    public var supportsGoogle: Bool { service?.supportsGoogle ?? false }

    /// Asks the service who is signed in. Safe to call repeatedly.
    public func refresh() async {
        user = await service?.currentUser()
    }

    // ── The rules, read from the engine ─────────────────────────────────────

    /// Every password rule, each marked met or not.
    ///
    /// Straight from ``PasswordPolicy`` rather than reimplemented here. That
    /// is the whole reason it sits in the engine: the Flutter app reads the
    /// same four rules over the C ABI, so a password accepted on a phone is
    /// accepted on a desktop.
    public func passwordRules(for password: String) -> [PasswordPolicy.Rule] {
        PasswordPolicy.evaluate(password)
    }

    public func accepts(password: String) -> Bool {
        PasswordPolicy.accepts(password)
    }

    public func looksLikeEmail(_ address: String) -> Bool {
        EmailAddress.looksValid(address)
    }

    // ── Attempts ────────────────────────────────────────────────────────────

    @discardableResult
    public func signIn(email: String, password: String) async -> Bool {
        clearErrors()
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            emailError = String(localized: "Enter your email address.")
            return false
        }
        // Not trimmed. A trailing space is a different password, and quietly
        // removing it would lock someone out of an account they typed
        // correctly.
        guard !password.isEmpty else {
            passwordError = String(localized: "Enter your password.")
            return false
        }
        return await attempt { service in
            try await service.signIn(email: address, password: password)
        }
    }

    @discardableResult
    public func signUp(email: String, password: String, confirmation: String) async -> Bool {
        clearErrors()
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeEmail(address) else {
            emailError = String(localized: "That does not look like an email address.")
            return false
        }
        guard accepts(password: password) else {
            passwordError = String(localized: "The password does not meet every rule yet.")
            return false
        }
        // Compared untrimmed, and compared exactly, for the same reason the
        // password is not trimmed above.
        guard password == confirmation else {
            passwordError = String(localized: "The two passwords are not the same.")
            return false
        }
        return await attempt { service in
            try await service.signUp(email: address, password: password)
        }
    }

    /// Sends a reset, and reports the same thing either way.
    ///
    /// Returns true when the request was accepted, which says nothing about
    /// whether the address has an account — and the screen must not imply
    /// otherwise.
    @discardableResult
    public func sendPasswordReset(to email: String) async -> Bool {
        clearErrors()
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeEmail(address) else {
            emailError = String(localized: "That does not look like an email address.")
            return false
        }
        guard let service else {
            banner = Self.notConnected
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.sendPasswordReset(to: address)
            return true
        } catch let error as AuthError {
            place(error)
            return false
        } catch {
            banner = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func signIn(with credential: AppleCredential) async -> Bool {
        clearErrors()
        return await attempt { service in
            try await service.signIn(with: credential)
        }
    }

    @discardableResult
    public func signInWithGoogle() async -> Bool {
        clearErrors()
        return await attempt { service in try await service.signInWithGoogle() }
    }

    public func signOut() async {
        clearErrors()
        guard let service else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.signOut()
            user = nil
        } catch let error as AuthError {
            place(error)
        } catch {
            banner = error.localizedDescription
        }
    }

    @discardableResult
    public func deleteAccount() async -> Bool {
        clearErrors()
        guard let service else {
            banner = Self.notConnected
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.deleteAccount()
            user = nil
            return true
        } catch let error as AuthError {
            place(error)
            return false
        } catch {
            banner = error.localizedDescription
            return false
        }
    }

    /// Reports an Apple authorization that failed before any account service
    /// saw it — a cancelled sheet, or a missing entitlement.
    public func report(appleFailure message: String) {
        banner = message
    }

    public func clearErrors() {
        banner = nil
        emailError = nil
        passwordError = nil
    }

    // ── Plumbing ────────────────────────────────────────────────────────────

    private static let notConnected = String(localized:
        "Accounts are not connected yet. Vox Scripta has no account service, so there is nothing to sign in to.")

    private func attempt(
        _ work: (any AuthService) async throws -> AuthUser
    ) async -> Bool {
        guard let service else {
            banner = Self.notConnected
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            user = try await work(service)
            return true
        } catch let error as AuthError {
            place(error)
            return false
        } catch {
            banner = error.localizedDescription
            return false
        }
    }

    /// Puts a failure under the field it belongs to, or above the form when
    /// it belongs to none. A message about the password shown next to the
    /// email field sends someone to re-check the wrong thing.
    private func place(_ error: AuthError) {
        switch error.field {
        case "email": emailError = error.message
        case "password": passwordError = error.message
        default: banner = error.message
        }
    }
}
