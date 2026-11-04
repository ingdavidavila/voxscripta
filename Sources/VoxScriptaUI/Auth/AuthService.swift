import Foundation
import VoxScriptaCore

/// Somebody signed in.
public struct AuthUser: Sendable, Hashable, Codable {
    public let id: String
    public let email: String
    /// `apple`, `google` or `password`. A string rather than an enum because
    /// it crosses to storage and back, and an unknown value must survive a
    /// round trip rather than fail to decode.
    public let provider: String

    public init(id: String, email: String, provider: String) {
        self.id = id
        self.email = email
        self.provider = provider
    }
}

/// Something the account service refused.
public struct AuthError: Error, Sendable, Hashable {
    public let message: String
    /// Which field it belongs under, when it belongs under one: `email` or
    /// `password`. Nil for a failure about the attempt as a whole.
    public let field: String?

    public init(_ message: String, field: String? = nil) {
        self.message = message
        self.field = field
    }
}

/// What Apple hands back, reduced to what an account service needs.
///
/// A plain struct rather than `ASAuthorizationAppleIDCredential` so the
/// protocol can be satisfied, and tested, without conjuring an
/// AuthenticationServices object that has no public initializer.
public struct AppleCredential: Sendable, Hashable {
    public let userID: String
    public let identityToken: String
    public let authorizationCode: String
    /// Apple sends these on the first authorization only, and never again.
    /// A service that does not store them on that first call cannot get them
    /// back.
    public let email: String?
    public let fullName: String?

    public init(
        userID: String,
        identityToken: String,
        authorizationCode: String,
        email: String? = nil,
        fullName: String? = nil
    ) {
        self.userID = userID
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.email = email
        self.fullName = fullName
    }
}

/// Everything the account screens ask of whatever holds accounts.
///
/// Deliberately the same shape as the Flutter side's `AuthService`, method for
/// method, because `Docs/PARITY.md` is a contract and two interfaces that
/// described accounts differently would be two applications. The password
/// rules are not on this protocol at all: they live in
/// ``PasswordPolicy`` in the engine, which both interfaces read, so a password
/// accepted on a phone is accepted on a desktop.
///
/// Note what is required rather than optional: ``deleteAccount()``. App Store
/// Review Guideline 5.1.1(v) requires an app offering account creation to
/// offer deletion from inside the app. Declaring it here makes it part of the
/// contract from the start rather than a discovery during review.
public protocol AuthService: Sendable {
    /// Who is signed in now, or nil.
    func currentUser() async -> AuthUser?

    /// Whether Sign in with Apple can be offered. False only where it is
    /// genuinely unavailable, so the button is absent rather than broken.
    var supportsApple: Bool { get }
    var supportsGoogle: Bool { get }

    func signIn(with credential: AppleCredential) async throws -> AuthUser
    func signInWithGoogle() async throws -> AuthUser
    func signIn(email: String, password: String) async throws -> AuthUser

    /// Creates an account. The caller has already checked the password
    /// against the engine's rules; this may still refuse it, because whoever
    /// holds the credentials gets the last word.
    func signUp(email: String, password: String) async throws -> AuthUser

    /// Sends a reset message.
    ///
    /// Succeeds whether or not the address has an account, and the screen
    /// says so: telling an anonymous visitor which addresses are registered
    /// turns a password form into a membership oracle.
    func sendPasswordReset(to email: String) async throws

    func signOut() async throws

    /// Deletes the account and everything the service holds for it.
    func deleteAccount() async throws
}

/// Stands in until an account service is chosen.
///
/// Every route fails saying exactly that. A stub that returned a plausible
/// user would let the whole flow look finished all the way to the library,
/// and nobody would find out the accounts were imaginary until a second
/// device failed to see them.
public struct UnconfiguredAuthService: AuthService {
    public init() {}

    public var supportsApple: Bool { true }
    public var supportsGoogle: Bool { true }

    public func currentUser() async -> AuthUser? { nil }

    private func unconfigured() throws -> Never {
        throw AuthError(
            "Accounts are not connected yet. Vox Scripta has no account "
            + "service, so there is nothing to sign in to.")
    }

    public func signIn(with credential: AppleCredential) async throws -> AuthUser {
        try unconfigured()
    }
    public func signInWithGoogle() async throws -> AuthUser { try unconfigured() }
    public func signIn(email: String, password: String) async throws -> AuthUser {
        try unconfigured()
    }
    public func signUp(email: String, password: String) async throws -> AuthUser {
        try unconfigured()
    }
    public func sendPasswordReset(to email: String) async throws { try unconfigured() }
    public func signOut() async throws {}
    public func deleteAccount() async throws { try unconfigured() }
}

/// The account service this build talks to, or nil when there is none.
///
/// Nil, and deliberately so — the same decision, for the same reasons, as the
/// Flutter side's `configuredAuthService()`. When it is nil the app never asks
/// anyone to sign in and Settings shows no account rows, because there is
/// genuinely nothing to sign in to.
///
/// Wiring a real one also changes what the app must declare: an email address
/// stored anywhere means the App Privacy entry can no longer say "Data Not
/// Collected", and it means a network connection in an application whose
/// premise is that it needs none. The transcription side stays local either
/// way; the declaration has to say both things.
public func configuredAuthService() -> (any AuthService)? { nil }
