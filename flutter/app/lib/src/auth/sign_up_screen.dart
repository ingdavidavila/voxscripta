import 'package:flutter/material.dart';

import '../l10n.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'auth_service.dart';
import 'auth_widgets.dart';

/// Creating an account: an email, a password that meets the rules, and the
/// password again.
class SignUpScreen extends StatefulWidget {
  const SignUpScreen({
    super.key,
    required this.auth,
    this.onSignedIn,
    this.rules,
    this.emailCheck,
  });

  final AuthService auth;
  final void Function(BuildContext, AuthUser)? onSignedIn;

  /// Reads the password rules. Defaults to the engine's, which is the point —
  /// one definition, so the same password is accepted on every platform.
  final List<PasswordRule> Function(String)? rules;

  final bool Function(String)? emailCheck;

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _emailError;
  String? _confirmError;
  String? _banner;
  bool _busy = false;
  bool _touchedPassword = false;
  List<PasswordRule> _rules = const [];

  @override
  void initState() {
    super.initState();
    _rules = _evaluate('');
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  List<PasswordRule> _evaluate(String password) {
    final read = widget.rules;
    if (read != null) return read(password);
    // No reader supplied and no engine handed in: show the rules as unmet
    // rather than inventing a second copy of them here. A duplicated rule is
    // how two interfaces start accepting different passwords.
    return const [];
  }

  bool get _passwordOk => _rules.isNotEmpty && _rules.every((r) => r.satisfied);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.createAnAccount)),
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
                    OrDivider(label: context.l10n.orSignUpWithEmail),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.newUsername],
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() => _emailError = null),
                      decoration: InputDecoration(
                        labelText: context.l10n.emailField,
                        helperText: context.l10n.emailHelper,
                        errorText: _emailError,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    PasswordField(
                      controller: _password,
                      label: context.l10n.passwordField,
                      autofillHints: const [AutofillHints.newPassword],
                      onChanged: (value) => setState(() {
                        _touchedPassword = true;
                        _rules = _evaluate(value);
                        if (_confirmError != null && _confirm.text == value) {
                          _confirmError = null;
                        }
                      }),
                    ),
                    const SizedBox(height: 10),
                    PasswordChecklist(rules: _rules, dimmed: !_touchedPassword),
                    const SizedBox(height: 14),
                    PasswordField(
                      controller: _confirm,
                      label: context.l10n.confirmPasswordField,
                      error: _confirmError,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() => _confirmError = null),
                      onSubmitted: _submit,
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(context.l10n.createAccount),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      context.l10n.deleteAnytimeNote,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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

  void _submit() {
    final email = _email.text.trim();
    final check = widget.emailCheck;
    setState(() {
      _emailError = email.isEmpty
          ? context.l10n.enterAnEmailAddress
          : (check != null && !check(email))
              ? context.l10n.notAnEmailAddress
              : null;
      // Checked against what was actually typed, not against a trimmed copy:
      // a trailing space is part of a password and the two fields must match
      // exactly or the account is created with one the person cannot retype.
      _confirmError = _confirm.text.isEmpty
          ? context.l10n.typePasswordAgain
          : _confirm.text != _password.text
              ? context.l10n.passwordsDoNotMatch
              : null;
    });
    if (_emailError != null || _confirmError != null) return;
    if (!_passwordOk) {
      // The checklist already says which rule is unmet, so the banner does not
      // repeat it — it says why the button did nothing.
      setState(() {
        _touchedPassword = true;
        _banner = context.l10n.passwordRequirementsUnmet;
      });
      return;
    }
    _run(() => widget.auth.signUp(email: email, password: _password.text));
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
        switch (failure.field) {
          case 'email':
            _emailError = failure.message;
          case 'confirm':
            _confirmError = failure.message;
          default:
            _banner = failure.message;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
