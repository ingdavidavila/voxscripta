import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'auth_widgets.dart';

/// The signed-in account: who it is, how to leave, how to delete it.
///
/// Deletion is not an extra. App Store Review Guideline 5.1.1(v) requires any
/// app that lets an account be created to let it be deleted from inside the
/// app, and Google Play requires a deletion route as well. So it is a button
/// here, on the same screen as the account itself, rather than a page on a
/// website.
class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.auth,
    required this.user,
    this.onSignedOut,
  });

  final AuthService auth;
  final AuthUser user;
  final void Function(BuildContext)? onSignedOut;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  String? _banner;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_banner case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: AuthBanner(message: message),
            ),
          ListTile(
            title: const Text('Signed in as'),
            subtitle: SelectableText(widget.user.email),
          ),
          ListTile(
            title: const Text('Signed in with'),
            subtitle: Text(_providerName(widget.user.provider)),
          ),
          const Divider(height: 32),
          ListTile(
            title: const Text('Sign out'),
            subtitle: const Text(
                'Your recordings and transcripts stay on this machine.'),
            trailing: const Icon(Icons.logout),
            enabled: !_busy,
            onTap: _busy ? null : _signOut,
          ),
          ListTile(
            title: Text('Delete account',
                style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text(
                'Removes the account and everything the account service holds '
                'for it. Your local projects are not touched.'),
            trailing: Icon(Icons.delete_forever_outlined,
                color: theme.colorScheme.error),
            enabled: !_busy,
            onTap: _busy ? null : _confirmDelete,
          ),
        ],
      ),
    );
  }

  static String _providerName(String provider) => switch (provider) {
        'apple' => 'Apple',
        'google' => 'Google',
        'password' => 'An email address and password',
        final other => other,
      };

  Future<void> _signOut() async {
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      await widget.auth.signOut();
      if (!mounted) return;
      final leave = widget.onSignedOut;
      if (leave != null) {
        leave(context);
      } else {
        Navigator.of(context).pop();
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _banner = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this account?'),
        content: const Text(
          'The account and everything the account service holds for it are '
          'removed. This cannot be undone.\n\n'
          'Recordings, projects and transcripts on this machine are not '
          'deleted — they were never on the account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      await widget.auth.deleteAccount();
      if (!mounted) return;
      final leave = widget.onSignedOut;
      if (leave != null) {
        leave(context);
      } else {
        Navigator.of(context).pop();
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _banner = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
