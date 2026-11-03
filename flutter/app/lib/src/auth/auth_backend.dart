import 'auth_service.dart';

/// The account service this build talks to, or null when there is none.
///
/// It is null, and will stay null until a backend is actually chosen and
/// wired. That is a deliberate state, not an oversight:
///
///  * Vox Scripta transcribes with no account and no network. Shipping a
///    sign-in screen that cannot sign anyone in would be a placeholder
///    presented as a finished feature.
///  * Returning a stub that handed back a fake user would be worse. The
///    library would open, settings would save, and nobody would discover the
///    accounts were imaginary until a second device failed to see them.
///
/// Whoever wires the real service replaces this one function. Everything
/// above it — the three screens, the shared widgets, the gate, the account
/// screen — is already written against [AuthService] and needs no change.
///
/// Whatever is chosen must satisfy, at minimum:
///
///  * Sign in with Apple, wherever Google sign-in is offered (App Store
///    Review Guideline 4.8).
///  * Deletion of the account from inside the app (Guideline 5.1.1(v), and
///    Google Play's data-deletion requirement).
///  * The password rules the engine defines, so a password accepted on one
///    platform is accepted on all of them.
///
/// Wiring one also changes what the app must declare. An account means a
/// network connection, an `INTERNET` permission in the Android manifest, and
/// an App Privacy entry that is no longer "Data Not Collected" — the email
/// address is collected, and it is linked to the user's identity. The
/// transcription side of the app stays local either way; the declaration has
/// to say both things.
AuthService? configuredAuthService() => null;
