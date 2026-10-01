import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth_links.dart';

/// After an invite/reset link, or from Settings.
class SetPasswordScreen extends StatefulWidget {
  const SetPasswordScreen({super.key});

  @override
  State<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<SetPasswordScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _firstTime => AuthLinks.needsPassword.value;

  Future<void> _save() async {
    final wasFirstTime = _firstTime;
    final pw = _password.text;
    if (pw.length < 8) {
      setState(() => _error = 'Use at least 8 characters');
      return;
    }
    if (pw != _confirm.text) {
      setState(() => _error = 'The passwords don\'t match');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.updateUser(UserAttributes(password: pw));
      AuthLinks.needsPassword.value = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password saved')));
      // new users still need to set things up
      context.go(wasFirstTime ? '/settings' : '/');
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';
    final firstTime = _firstTime;
    return Scaffold(
      appBar: firstTime
          ? null
          : AppBar(
              title: const Text('Change password'),
              leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/settings')),
            ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (firstTime) ...[
                  Icon(Icons.lock_reset, size: 52, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('Choose your password', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text('You\'ll use it with $email to sign in to JobFinder on the web and on your phone.',
                      textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 28),
                ] else ...[
                  Text('Signed in as $email', style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(labelText: 'New password', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirm,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  onSubmitted: (_) => _save(),
                  decoration: const InputDecoration(labelText: 'Confirm password', border: OutlineInputBorder()),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: _busy
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save password'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
