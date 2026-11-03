import 'package:flutter/foundation.dart';

/// Who is signed in.
@immutable
class AuthUser {
  const AuthUser({required this.id, required this.email, required this.provider});

  final String id;
  final String email;

  /// `apple`, `google` or `password`.
  final String provider;
}

/// Why a sign-in attempt did not work.
///
/// Carries a [field] where the problem belongs to one, so a form can put the
/// message under the control that caused it instead of in a banner the user
/// has to map back onto their own typing.
class AuthException implements Exception {
  const AuthException(this.message, {this.field});

  final String message;

  /// `email`, `password`, `confirm`, or null for the form as a whole.
  final String? field;

  @override
  String toString() => 'AuthException: $message';
}

/// Everything the sign-in screens ask of whatever ends up holding accounts.
///
/// An interface rather than an implementation, because there is no account
/// service yet and inventing one would be the worst kind of progress: screens
/// that look finished, wired to nothing, that someone later believes work.
/// Firebase, Supabase or a server of your own all satisfy this shape; none of
/// them is chosen here.
///
/// Note what is missing and must not stay missing: **deleting an account**.
/// App Store Review Guideline 5.1.1(v) requires any app offering account
/// creation to offer deletion from inside the app, and Google Play requires a
/// deletion route as well. It is declared here so that it is part of the
/// contract from the start rather than discovered during review.
abstract interface class AuthService {
  /// Who is signed in now, or null.
  AuthUser? get currentUser;

  /// Changes to [currentUser], for the shell to listen to.
  Stream<AuthUser?> get changes;

  /// Whether Sign in with Apple can be offered here. False on platforms where
  /// it is unavailable, so the button is absent rather than broken.
  bool get supportsApple;

  bool get supportsGoogle;

  Future<AuthUser> signInWithApple();
  Future<AuthUser> signInWithGoogle();
  Future<AuthUser> signInWithPassword({required String email, required String password});

  /// Creates an account. The caller has already checked the password against
  /// the engine's rules; this may still refuse it, because the service holding
  /// the credentials gets the last word.
  Future<AuthUser> signUp({required String email, required String password});

  /// Sends a reset message.
  ///
  /// Succeeds whether or not the address has an account, and the screen says
  /// so: telling an anonymous visitor which addresses are registered turns a
  /// password form into a membership oracle.
  Future<void> sendPasswordReset(String email);

  Future<void> signOut();

  /// Deletes the account and everything the service holds for it.
  Future<void> deleteAccount();
}

/// Stands in until an account service is chosen.
///
/// Every method fails with a message saying exactly that. It exists so the
/// screens can be built, run and tested now, and so that nothing silently
/// appears to work: a stub that returned a fake user would let a sign-in flow
/// look complete all the way to the library screen.
class UnconfiguredAuthService implements AuthService {
  @override
  AuthUser? get currentUser => null;

  @override
  Stream<AuthUser?> get changes => const Stream<AuthUser?>.empty();

  @override
  bool get supportsApple => true;

  @override
  bool get supportsGoogle => true;

  static Never _unconfigured() => throw const AuthException(
        'Accounts are not connected yet. Vox Scripta has no account service, '
        'so there is nothing to sign in to.',
      );

  @override
  Future<AuthUser> signInWithApple() async => _unconfigured();

  @override
  Future<AuthUser> signInWithGoogle() async => _unconfigured();

  @override
  Future<AuthUser> signInWithPassword({
    required String email,
    required String password,
  }) async =>
      _unconfigured();

  @override
  Future<AuthUser> signUp({required String email, required String password}) async =>
      _unconfigured();

  @override
  Future<void> sendPasswordReset(String email) async => _unconfigured();

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async => _unconfigured();
}
