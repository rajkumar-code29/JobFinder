import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth_links.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error = AuthLinks.linkError == null
      ? null
      : 'That email link didn\'t work (${AuthLinks.linkError}). Links can only be used once and expire after a day. '
          'Enter your email and tap "Forgot password?" to get a fresh one.';
  String? _info;

  void _show({String? error, String? info}) => setState(() {
        _error = error;
        _info = info;
      });

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      _show(error: 'Enter your email above first');
      return;
    }
    setState(() => _busy = true);
    try {
      // null on iOS -> Supabase uses the site URL
      await Supabase.instance.client.auth.resetPasswordForEmail(email, redirectTo: kIsWeb ? Uri.base.origin : null);
      _show(info: 'If $email has an account, a link to set a new password is on its way. Check spam too.');
    } on AuthException catch (e) {
      _show(error: e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth
          .signInWithPassword(email: _email.text.trim(), password: _password.text);
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
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(Icons.travel_explore, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text('JobFinder', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                Text('Your job-hunting agents', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 32),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _signIn(),
                  decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ],
                if (_info != null) ...[
                  const SizedBox(height: 12),
                  Text(_info!, style: TextStyle(color: theme.colorScheme.primary)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _signIn,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: _busy
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Sign in'),
                ),
                const SizedBox(height: 8),
                TextButton(onPressed: _busy ? null : _forgotPassword, child: const Text('Forgot password?')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
