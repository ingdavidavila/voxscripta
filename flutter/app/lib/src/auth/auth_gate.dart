import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'sign_in_screen.dart';

/// Decides whether to ask for an account before the app opens.
///
/// It asks once, at launch, and takes no for an answer. "Not now" goes
/// straight to the library and does not come back, because the app works
/// without an account:
/// transcription is local, the projects are on disk, and nothing in the
/// pipeline consults a server. Apple's Review Guideline 5.1.1(i) refuses apps
/// that require personal information for features that do not need it, and
/// this one does not need it.
///
/// Once the app has been let through it stays through for the session, even if
/// the account is later signed out or deleted. Re-gating mid-session would
/// rebuild the shell underneath whatever screens are already pushed on top of
/// it, and the user would find a sign-in form where the library used to be.
/// Signing back in is in Settings, where the signing out happened.
///
/// When [auth] is null there is no account service in this build, so the gate
/// is not shown at all — the sign-in screens are still reachable from
/// Settings, which is the honest place for a feature that is not connected.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.auth, required this.builder});

  final AuthService? auth;

  /// Builds the app. [user] is whoever is signed in, or null if nobody is.
  final Widget Function(BuildContext context, AuthUser? user) builder;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthUser?>? _watch;
  AuthUser? _user;

  /// Whether the gate has been answered. Set by signing in, by declining, and
  /// at launch when somebody is already signed in.
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    final auth = widget.auth;
    if (auth == null) return;
    _user = auth.currentUser;
    _opened = _user != null;
    _watch = auth.changes.listen((user) {
      if (mounted) setState(() => _user = user);
    });
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = widget.auth;
    if (auth == null || _opened) {
      return widget.builder(context, _user);
    }
    return SignInScreen(
      auth: auth,
      onSignedIn: (_, user) => setState(() {
        _user = user;
        _opened = true;
      }),
      onSkip: (_) => setState(() => _opened = true),
    );
  }
}
