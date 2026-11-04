import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'auth_widgets.dart';
import 'forgot_password_screen.dart';
import 'sign_up_screen.dart';

/// Signing in: Apple, Google, or an email and password.
class SignInScreen extends StatefulWidget {
  const SignInScreen({
    super.key,
    required this.auth,
    this.onSignedIn,
    this.onSkip,
  });

  final AuthService auth;
  final void Function(BuildContext, AuthUser)? onSignedIn;

  /// Carries on without an account.
  ///
  /// Offered unless something genuinely needs an account, because the app
  /// transcribes perfectly well without one — and because Apple's Review
  /// Guideline 5.1.1(i) refuses apps that demand personal information for
  /// features that do not need it.
  final void Function(BuildContext)? onSkip;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _emailError;
  String? _passwordError;
  String? _banner;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
        actions: [
          if (widget.onSkip case final skip?)
            TextButton(
              onPressed: _busy ? null : () => skip(context),
              child: const Text('Not now'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Welcome back', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      'Your recordings stay on this device either way. '
                      'An account is only for settings that follow you.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    if (_banner case final message?) ...[
                      AuthBanner(message: message),
                      const SizedBox(height: 16),
                    ],
                    ProviderButtons(
                      showApple: widget.auth.supportsApple,
                      showGoogle: widget.auth.supportsGoogle,
                      busy: _busy,
                      onApple: () => _run(widget.auth.signInWithApple),
                      onGoogle: () => _run(widget.auth.signInWithGoogle),
                    ),
                    const SizedBox(height: 20),
                    const OrDivider(),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() => _emailError = null),
                      decoration: InputDecoration(
                        labelText: 'Email',
                        errorText: _emailError,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    PasswordField(
                      controller: _password,
                      label: 'Password',
                      error: _passwordError,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() => _passwordError = null),
                      onSubmitted: _signIn,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _busy ? null : _forgot,
                        child: const Text('Forgot password?'),
                      ),
                    ),
                    const SizedBox(height: 4),
                    FilledButton(
                      onPressed: _busy ? null : _signIn,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Sign in'),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('No account yet?',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        TextButton(
                          onPressed: _busy ? null : _signUp,
                          child: const Text('Create one'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _signIn() {
    final email = _email.text.trim();
    // Both checked before anything is sent. An empty field is not a failed
    // sign-in, and reporting it as one teaches people their password is wrong
    // when it is not.
    setState(() {
      _emailError = email.isEmpty ? 'Enter your email.' : null;
      _passwordError = _password.text.isEmpty ? 'Enter your password.' : null;
    });
    if (_emailError != null || _passwordError != null) return;
    _run(() => widget.auth.signInWithPassword(
        email: email, password: _password.text));
  }

  Future<void> _run(Future<AuthUser> Function() attempt) async {
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      final user = await attempt();
      if (!mounted) return;
      widget.onSignedIn?.call(context, user);
    } on AuthException catch (failure) {
      if (!mounted) return;
      setState(() {
        // Under the field it belongs to where the service says which, in the
        // banner otherwise.
        switch (failure.field) {
          case 'email':
            _emailError = failure.message;
          case 'password':
            _passwordError = failure.message;
          default:
            _banner = failure.message;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _forgot() => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ForgotPasswordScreen(
            auth: widget.auth, initialEmail: _email.text.trim()),
      ));

  void _signUp() => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SignUpScreen(
          auth: widget.auth,
          onSignedIn: widget.onSignedIn,
        ),
      ));
}
