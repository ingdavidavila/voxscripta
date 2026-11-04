import 'package:flutter/material.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// A password field with a show/hide control.
///
/// The reveal is a `StatefulWidget` of its own so that toggling it rebuilds
/// one field rather than the whole form, which would move focus and lose the
/// caret mid-word.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.error,
    this.autofillHints,
    this.textInputAction = TextInputAction.next,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? error;
  final Iterable<String>? autofillHints;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: !_shown,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: (_) => widget.onSubmitted?.call(),
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: widget.error,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_shown ? Icons.visibility_off : Icons.visibility),
          // Named for what it will do, not for what is showing, and announced
          // to a screen reader — the icon alone tells a sighted user and
          // nobody else.
          tooltip: _shown ? 'Hide password' : 'Show password',
          onPressed: () => setState(() => _shown = !_shown),
        ),
      ),
    );
  }
}

/// The password rules, ticking off as someone types.
///
/// Every rule is shown from the start, including the ones not yet met. A form
/// that reveals one requirement at a time makes a person fail repeatedly at a
/// test whose terms they were never given.
class PasswordChecklist extends StatelessWidget {
  const PasswordChecklist({super.key, required this.rules, required this.dimmed});

  final List<PasswordRule> rules;

  /// True before the field has been touched, so the list reads as guidance
  /// rather than as a column of failures.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final rule in rules)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  rule.satisfied ? Icons.check_circle : Icons.circle_outlined,
                  size: 16,
                  color: rule.satisfied
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    rule.demand,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: rule.satisfied
                          ? theme.colorScheme.onSurface
                          : dimmed
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Sign in with Apple and with Google, as big as the email form.
///
/// Apple's Review Guideline 4.8 requires an equivalent privacy-preserving
/// option wherever a third-party login is offered, and Sign in with Apple is
/// one — so where Google appears, Apple appears with it.
class ProviderButtons extends StatelessWidget {
  const ProviderButtons({
    super.key,
    required this.showApple,
    required this.showGoogle,
    required this.onApple,
    required this.onGoogle,
    required this.busy,
  });

  final bool showApple;
  final bool showGoogle;
  final VoidCallback onApple;
  final VoidCallback onGoogle;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (!showApple && !showGoogle) return const SizedBox.shrink();
    return Column(
      children: [
        if (showApple)
          _Provider(
            icon: Icons.apple,
            label: 'Continue with Apple',
            onPressed: busy ? null : onApple,
          ),
        if (showApple && showGoogle) const SizedBox(height: 10),
        if (showGoogle)
          _Provider(
            icon: Icons.g_mobiledata,
            label: 'Continue with Google',
            onPressed: busy ? null : onGoogle,
          ),
      ],
    );
  }
}

class _Provider extends StatelessWidget {
  const _Provider({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      );
}

/// A horizontal rule with a word in it.
class OrDivider extends StatelessWidget {
  const OrDivider({super.key, this.label = 'or'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      const Expanded(child: Divider()),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
      const Expanded(child: Divider()),
    ]);
  }
}

/// A failure, shown where the user is looking rather than in a toast.
class AuthBanner extends StatelessWidget {
  const AuthBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(message,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onErrorContainer)),
    );
  }
}
