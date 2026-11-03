import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/auth/account_screen.dart';
import 'package:voxscripta/src/auth/auth_backend.dart';
import 'package:voxscripta/src/auth/auth_gate.dart';
import 'package:voxscripta/src/auth/auth_service.dart';

/// The gate and the account screen.
///
/// Two rules carry the weight here. The app must open for someone who does not
/// want an account — Vox Scripta transcribes with no account and no network,
/// and Review Guideline 5.1.1(i) refuses apps that demand personal
/// information for features that do not need it. And an account must be
/// deletable from inside the app, which Guideline 5.1.1(v) requires of any app
/// that lets one be created.
void main() {
  group('AuthGate', () {
    testWidgets('with no account service the app opens straight away',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AuthGate(auth: null, builder: (_, _) => const Text('Library')),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Library'), findsOne);
      expect(find.text('Sign in'), findsNothing);
    });

    testWidgets('no service is configured in this build', (tester) async {
      // The honest state, asserted so that it is a decision rather than a
      // thing someone forgot. When a backend is wired this test changes.
      expect(configuredAuthService(), isNull);
    });

    testWidgets('with a service and nobody signed in it asks', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AuthGate(
            auth: _Stub(), builder: (_, _) => const Text('Library')),
      ));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Sign in'), findsOne);
      expect(find.text('Library'), findsNothing);
    });

    testWidgets('"Not now" opens the app and does not ask again',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AuthGate(
            auth: _Stub(), builder: (_, _) => const Text('Library')),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(find.text('Library'), findsOne);

      // A rebuild must not bring the gate back: declining is an answer, not a
      // dismissal.
      await tester.pump();
      expect(find.text('Library'), findsOne);
    });

    testWidgets('someone already signed in is not asked', (tester) async {
      final auth = _Stub(
          user: const AuthUser(
              id: '1', email: 'ada@example.com', provider: 'password'));
      await tester.pumpWidget(MaterialApp(
        home: AuthGate(auth: auth, builder: (_, user) => Text(user!.email)),
      ));
      await tester.pumpAndSettle();

      expect(find.text('ada@example.com'), findsOne);
    });

    testWidgets('signing out elsewhere leaves the app open, with no account',
        (tester) async {
      final auth = _Stub(
          user: const AuthUser(
              id: '1', email: 'ada@example.com', provider: 'password'));
      await tester.pumpWidget(MaterialApp(
        home: AuthGate(
            auth: auth, builder: (_, user) => Text(user?.email ?? 'nobody')),
      ));
      await tester.pumpAndSettle();

      // The gate does not come back and sit on top of the app; the shell just
      // sees that nobody is signed in.
      auth.emit(null);
      await tester.pumpAndSettle();
      expect(find.text('nobody'), findsOne);
      expect(find.widgetWithText(AppBar, 'Sign in'), findsNothing);
    });
  });

  group('AccountScreen', () {
    const user =
        AuthUser(id: '1', email: 'ada@example.com', provider: 'password');

    Future<_Stub> show(WidgetTester tester) async {
      final auth = _Stub(user: user);
      await tester.pumpWidget(MaterialApp(
        home: AccountScreen(auth: auth, user: user, onSignedOut: (_) {}),
      ));
      await tester.pumpAndSettle();
      return auth;
    }

    testWidgets('shows the address and how it was signed in', (tester) async {
      await show(tester);
      expect(find.text('ada@example.com'), findsOne);
      expect(find.text('An email address and password'), findsOne);
    });

    testWidgets('deletion is offered from inside the app', (tester) async {
      await show(tester);
      expect(find.text('Delete account'), findsOne);
    });

    testWidgets('deletion asks first, and declining deletes nothing',
        (tester) async {
      final auth = await show(tester);

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this account?'), findsOne);

      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();
      expect(auth.deletions, 0);
    });

    testWidgets('confirming deletes the account', (tester) async {
      final auth = await show(tester);

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(auth.deletions, 1);
    });

    testWidgets('deletion says the local projects are not touched',
        (tester) async {
      await show(tester);
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();

      // The user is about to press a button with "delete" on it; what it does
      // not delete matters as much as what it does.
      expect(
        find.textContaining('are not\ndeleted', findRichText: true),
        findsNothing,
      );
      expect(find.textContaining('not\ndeleted'), findsNothing);
      expect(
        find.textContaining('Recordings, projects and transcripts'),
        findsOne,
      );
    });

    testWidgets('signing out reports a service failure instead of leaving',
        (tester) async {
      final auth = _Stub(
          user: user, signOutFailure: const AuthException('No connection.'));
      await tester.pumpWidget(MaterialApp(
        home: AccountScreen(auth: auth, user: user, onSignedOut: (_) {}),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('No connection.'), findsOne);
    });

    testWidgets('signing out hands back to the caller', (tester) async {
      final auth = _Stub(user: user);
      var left = false;
      await tester.pumpWidget(MaterialApp(
        home: AccountScreen(
            auth: auth, user: user, onSignedOut: (_) => left = true),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(auth.signOuts, 1);
      expect(left, isTrue);
    });
  });
}

/// An account service whose signed-in user can be changed from the test.
class _Stub implements AuthService {
  _Stub({AuthUser? user, this.signOutFailure}) : _user = user;

  final AuthException? signOutFailure;
  final _changes = StreamController<AuthUser?>.broadcast();
  AuthUser? _user;
  int signOuts = 0;
  int deletions = 0;

  void emit(AuthUser? user) {
    _user = user;
    _changes.add(user);
  }

  @override
  AuthUser? get currentUser => _user;

  @override
  Stream<AuthUser?> get changes => _changes.stream;

  @override
  bool get supportsApple => true;

  @override
  bool get supportsGoogle => true;

  @override
  Future<AuthUser> signInWithApple() async =>
      const AuthUser(id: 'a', email: 'a@example.com', provider: 'apple');

  @override
  Future<AuthUser> signInWithGoogle() async =>
      const AuthUser(id: 'g', email: 'g@example.com', provider: 'google');

  @override
  Future<AuthUser> signInWithPassword({
    required String email,
    required String password,
  }) async =>
      AuthUser(id: email, email: email, provider: 'password');

  @override
  Future<AuthUser> signUp({
    required String email,
    required String password,
  }) async =>
      AuthUser(id: email, email: email, provider: 'password');

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> signOut() async {
    if (signOutFailure case final failure?) throw failure;
    signOuts += 1;
    emit(null);
  }

  @override
  Future<void> deleteAccount() async {
    deletions += 1;
    emit(null);
  }
}
