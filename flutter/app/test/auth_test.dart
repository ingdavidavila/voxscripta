import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/auth/auth_service.dart';
import 'package:voxscripta/src/auth/forgot_password_screen.dart';
import 'package:voxscripta/src/auth/sign_in_screen.dart';
import 'package:voxscripta/src/auth/sign_up_screen.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The account screens.
///
/// What is pinned here is the behaviour that costs a user something when it is
/// wrong: that nothing is sent before the obvious mistakes are caught, that
/// the two password fields must match exactly, that a reset never reveals
/// whether an address is registered, and that a service failure lands under
/// the field it belongs to.
void main() {
  /// Stands in for the engine's rules, with the same four ids.
  List<PasswordRule> rules(String password) => [
        PasswordRule(
            id: 'length',
            demand: 'At least 8 characters',
            satisfied: password.length >= 8),
        PasswordRule(
            id: 'uppercase',
            demand: 'One capital letter',
            satisfied: password.contains(RegExp('[A-Z]'))),
        PasswordRule(
            id: 'number',
            demand: 'One number',
            satisfied: password.contains(RegExp('[0-9]'))),
        PasswordRule(
            id: 'special',
            demand: 'One symbol, such as ! ? # or &',
            satisfied: password.contains(RegExp(r'[^A-Za-z0-9\s]'))),
      ];

  bool looksLikeEmail(String s) =>
      s.contains('@') && s.split('@').length == 2 && s.split('@')[1].contains('.');

  Future<void> showSignIn(WidgetTester tester, _Stub auth,
      {void Function(BuildContext, AuthUser)? onSignedIn}) async {
    await tester.pumpWidget(MaterialApp(
        home: SignInScreen(auth: auth, onSignedIn: onSignedIn, onSkip: (_) {})));
    await tester.pumpAndSettle();
  }

  Future<void> showSignUp(WidgetTester tester, _Stub auth,
      {void Function(BuildContext, AuthUser)? onSignedIn}) async {
    await tester.pumpWidget(MaterialApp(
      home: SignUpScreen(
          auth: auth, onSignedIn: onSignedIn, rules: rules,
          emailCheck: looksLikeEmail),
    ));
    await tester.pumpAndSettle();
  }

  group('Sign in', () {
    testWidgets('empty fields are caught before anything is sent',
        (tester) async {
      final auth = _Stub();
      await showSignIn(tester, auth);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your email.'), findsOne);
      expect(find.text('Enter your password.'), findsOne);
      // An empty field is not a failed sign-in. Sending it would teach people
      // their password is wrong when it is not.
      expect(auth.passwordAttempts, isEmpty);
    });

    testWidgets('a rejected password lands under the password field',
        (tester) async {
      final auth = _Stub(
          failure: const AuthException('That password is not right.',
              field: 'password'));
      await showSignIn(tester, auth);
      await tester.enterText(find.byType(TextField).first, 'david@example.com');
      await tester.enterText(find.byType(TextField).last, 'whatever');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('That password is not right.'), findsOne);
    });

    testWidgets('both providers are offered, and Apple wherever Google is',
        (tester) async {
      // Apple's Review Guideline 4.8 wants a privacy-preserving equivalent
      // wherever a third-party login appears.
      await showSignIn(tester, _Stub());
      expect(find.text('Continue with Apple'), findsOne);
      expect(find.text('Continue with Google'), findsOne);
    });

    testWidgets('the password is hidden until the reveal is tapped',
        (tester) async {
      await showSignIn(tester, _Stub());
      TextField field() => tester.widget<TextField>(find.byType(TextField).last);
      expect(field().obscureText, isTrue);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pumpAndSettle();
      expect(field().obscureText, isFalse);
      expect(find.byTooltip('Hide password'), findsOne);
    });
  });

  group('Sign up', () {
    testWidgets('every rule is listed from the start, not revealed one by one',
        (tester) async {
      await showSignUp(tester, _Stub());
      // A form that shows one requirement at a time makes someone fail
      // repeatedly at a test they were never given.
      expect(find.text('At least 8 characters'), findsOne);
      expect(find.text('One capital letter'), findsOne);
      expect(find.text('One number'), findsOne);
      expect(find.text('One symbol, such as ! ? # or &'), findsOne);
    });

    testWidgets('the checklist ticks off as the password is typed',
        (tester) async {
      await showSignUp(tester, _Stub());
      expect(find.byIcon(Icons.check_circle), findsNothing);

      await tester.enterText(find.byType(TextField).at(1), 'Harbour7!');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_circle), findsExactly(4));
    });

    testWidgets('a password short of the rules is refused locally',
        (tester) async {
      final auth = _Stub();
      await showSignUp(tester, auth);
      await tester.enterText(find.byType(TextField).first, 'david@example.com');
      await tester.enterText(find.byType(TextField).at(1), 'harbour');
      await tester.enterText(find.byType(TextField).at(2), 'harbour');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(find.textContaining('does not meet all the requirements'), findsOne);
      expect(auth.signUps, isEmpty);
    });

    testWidgets('the two passwords must match exactly', (tester) async {
      final auth = _Stub();
      await showSignUp(tester, auth);
      await tester.enterText(find.byType(TextField).first, 'david@example.com');
      await tester.enterText(find.byType(TextField).at(1), 'Harbour7!');
      await tester.enterText(find.byType(TextField).at(2), 'Harbour7! ');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      // Compared untrimmed: a trailing space is part of a password, and
      // trimming would create an account with one the person cannot retype.
      expect(find.text('The two passwords do not match.'), findsOne);
      expect(auth.signUps, isEmpty);
    });

    testWidgets('a malformed email is caught before the service sees it',
        (tester) async {
      final auth = _Stub();
      await showSignUp(tester, auth);
      await tester.enterText(find.byType(TextField).first, 'david@example');
      await tester.enterText(find.byType(TextField).at(1), 'Harbour7!');
      await tester.enterText(find.byType(TextField).at(2), 'Harbour7!');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(find.textContaining('does not look like an email'), findsOne);
      expect(auth.signUps, isEmpty);
    });

    testWidgets('a complete form reaches the service', (tester) async {
      final auth = _Stub();
      AuthUser? signedIn;
      await showSignUp(tester, auth, onSignedIn: (_, user) => signedIn = user);
      await tester.enterText(find.byType(TextField).first, 'david@example.com');
      await tester.enterText(find.byType(TextField).at(1), 'Harbour7!');
      await tester.enterText(find.byType(TextField).at(2), 'Harbour7!');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();

      expect(auth.signUps, ['david@example.com']);
      expect(signedIn?.email, 'david@example.com');
    });

    testWidgets('account deletion is promised where the account is made',
        (tester) async {
      // Apple 5.1.1(v) requires in-app deletion for any app offering account
      // creation, so the promise is made at the point of signing up.
      await showSignUp(tester, _Stub());
      expect(find.textContaining('delete your account'), findsOne);
    });
  });

  group('Forgot password', () {
    testWidgets('the confirmation does not say whether the address exists',
        (tester) async {
      final auth = _Stub();
      await tester.pumpWidget(MaterialApp(
        home: ForgotPasswordScreen(
            auth: auth, initialEmail: 'nobody@example.com',
            emailCheck: looksLikeEmail),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pumpAndSettle();

      // Saying "no account found" would turn this form into a way for anyone
      // to discover who has signed up.
      expect(find.textContaining('If nobody@example.com has an account'), findsOne);
      expect(find.textContaining('not found'), findsNothing);
      expect(auth.resets, ['nobody@example.com']);
    });

    testWidgets('an empty address is caught before sending', (tester) async {
      final auth = _Stub();
      await tester.pumpWidget(MaterialApp(
          home: ForgotPasswordScreen(auth: auth, emailCheck: looksLikeEmail)));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pumpAndSettle();

      expect(find.text('Enter your email address.'), findsOne);
      expect(auth.resets, isEmpty);
    });
  });

  group('UnconfiguredAuthService', () {
    test('every route fails saying accounts are not connected', () async {
      final auth = UnconfiguredAuthService();
      // A stub that returned a fake user would let the whole flow look
      // finished all the way to the library screen.
      for (final attempt in <Future<Object?> Function()>[
        auth.signInWithApple,
        auth.signInWithGoogle,
        () => auth.signInWithPassword(email: 'a@b.com', password: 'Harbour7!'),
        () => auth.signUp(email: 'a@b.com', password: 'Harbour7!'),
        () => auth.sendPasswordReset('a@b.com'),
        auth.deleteAccount,
      ]) {
        await expectLater(attempt(), throwsA(isA<AuthException>()));
      }
      expect(auth.currentUser, isNull);
    });
  });
}

class _Stub implements AuthService {
  _Stub({this.failure});

  final AuthException? failure;
  final List<String> passwordAttempts = [];
  final List<String> signUps = [];
  final List<String> resets = [];

  AuthUser _user(String email, String provider) =>
      AuthUser(id: 'id-$email', email: email, provider: provider);

  @override
  AuthUser? get currentUser => null;

  @override
  Stream<AuthUser?> get changes => const Stream<AuthUser?>.empty();

  @override
  bool get supportsApple => true;

  @override
  bool get supportsGoogle => true;

  @override
  Future<AuthUser> signInWithApple() async {
    if (failure case final f?) throw f;
    return _user('apple@example.com', 'apple');
  }

  @override
  Future<AuthUser> signInWithGoogle() async {
    if (failure case final f?) throw f;
    return _user('google@example.com', 'google');
  }

  @override
  Future<AuthUser> signInWithPassword({
    required String email,
    required String password,
  }) async {
    passwordAttempts.add(email);
    if (failure case final f?) throw f;
    return _user(email, 'password');
  }

  @override
  Future<AuthUser> signUp({required String email, required String password}) async {
    signUps.add(email);
    if (failure case final f?) throw f;
    return _user(email, 'password');
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    resets.add(email);
    if (failure case final f?) throw f;
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<void> deleteAccount() async {}
}
