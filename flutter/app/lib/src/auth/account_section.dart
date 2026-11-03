import 'dart:async';

import 'package:flutter/material.dart';

import 'account_screen.dart';
import 'auth_service.dart';
import 'sign_in_screen.dart';

/// The account rows in Settings: sign in, or manage the account you have.
///
/// Settings is the only place in the app that mentions accounts once the gate
/// has been answered, which is the right size for a feature that nothing in
/// the pipeline depends on.
class AccountSection extends StatefulWidget {
  const AccountSection({super.key, required this.auth});

  final AuthService auth;

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  StreamSubscription<AuthUser?>? _watch;
  AuthUser? _user;

  @override
  void initState() {
    super.initState();
    _user = widget.auth.currentUser;
    _watch = widget.auth.changes.listen((user) {
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('ACCOUNT',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 0.8,
                )),
          ),
          Card(margin: EdgeInsets.zero, child: _tile()),
        ],
      ),
    );
  }

  Widget _tile() {
    if (_user case final user?) {
      return ListTile(
        title: const Text('Account'),
        subtitle: Text(user.email),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AccountScreen(auth: widget.auth, user: user),
          ),
        ),
      );
    }
    return ListTile(
      title: const Text('Sign in'),
      subtitle: const Text('Optional. Transcription works without one.'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SignInScreen(
            auth: widget.auth,
            onSignedIn: (context, _) => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }
}
