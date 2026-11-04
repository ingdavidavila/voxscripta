import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'auth_widgets.dart';

/// Asking for a reset message.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({
    super.key,
    required this.auth,
    this.initialEmail = '',
    this.emailCheck,
  });

  final AuthService auth;
  final String initialEmail;
  final bool Function(String)? emailCheck;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail);
  String? _emailError;
  String? _banner;
  bool _busy = false;
  bool _sent = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reset your password')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _sent ? _confirmation(theme) : _form(theme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the email you signed up with and we will send you a link to '
            'choose a new password.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          if (_banner case final message?) ...[
            AuthBanner(message: message),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofocus: true,
            autofillHints: const [AutofillHints.username],
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() => _emailError = null),
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              labelText: 'Email',
              errorText: _emailError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _busy ? null : _send,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            child: _busy
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Send reset link'),
          ),
        ],
      );

  Widget _confirmation(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.mark_email_read_outlined,
              size: 44, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text('Check your email', style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            // Deliberately does not say whether that address has an account.
            // Confirming it would turn this form into a way for anyone to
            // discover who has signed up.
            'If ${_email.text.trim()} has an account, a reset link is on its '
            'way. It expires after a short while, so use it soon.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 22),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Back to sign in'),
          ),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _sent = false),
            child: const Text('Use a different email'),
          ),
        ],
      );

  Future<void> _send() async {
    final email = _email.text.trim();
    final check = widget.emailCheck;
    setState(() {
      _emailError = email.isEmpty
          ? 'Enter your email address.'
          : (check != null && !check(email))
              ? 'That does not look like an email address.'
              : null;
    });
    if (_emailError != null) return;

    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      await widget.auth.sendPasswordReset(email);
      if (mounted) setState(() => _sent = true);
    } on AuthException catch (failure) {
      if (mounted) setState(() => _banner = failure.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
