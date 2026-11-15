import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api.dart';
import '../config.dart';
import '../screens/privacy_info.dart';
import 'common.dart';

/// 'approved' or 'rejected' (blocked by an admin). Older rows without a status count as approved.
String accessStatus(Map<String, dynamic>? account) => account?['status'] as String? ?? 'approved';

/// What stands between a signed-in person and the app: a verified email, not being blocked, and agreeing to the
/// current privacy notice. The database enforces the first two as well (is_approved(), migration 011).
class AccessGate extends StatefulWidget {
  const AccessGate({super.key, required this.child});
  final Widget child;

  @override
  State<AccessGate> createState() => _AccessGateState();
}

class _AccessGateState extends State<AccessGate> {
  late final Stream<List<Map<String, dynamic>>> _stream = Api.myAccountStream();
  late Future<Map<String, dynamic>?> _fallback = Api.account();

  Widget _decide(Map<String, dynamic>? account) {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null && user.emailConfirmedAt == null) return VerifyEmailScreen(email: user.email ?? '');
    if (account == null) return const _Loading();
    if (accessStatus(account) == 'rejected') return BlockedScreen(email: user?.email ?? '');
    final accepted = (account['privacy_version'] as int?) ?? (account['privacy_accepted_at'] == null ? 0 : 1);
    if (accepted < privacyVersion) {
      return PrivacyConsentScreen(
        updated: accepted > 0,
        onAccept: () async {
          await Api.acceptPrivacy();
          // first time in: show the setup guide
          if (accepted == 0 && mounted) GoRouter.of(context).go('/guide');
          setState(() => _fallback = Api.account());
        },
        onSignOut: () => Supabase.instance.client.auth.signOut(),
      );
    }
    return widget.child;
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) {
            // realtime unavailable: read the row once instead
            return FutureBuilder<Map<String, dynamic>?>(
              future: _fallback,
              builder: (context, once) {
                if (once.hasError) {
                  return Scaffold(body: ErrorView(once.error!, onRetry: () => setState(() => _fallback = Api.account())));
                }
                if (once.connectionState != ConnectionState.done) return const _Loading();
                return _decide(once.data);
              },
            );
          }
          if (!snap.hasData) return const _Loading();
          return _decide(snap.data!.firstOrNull);
        },
      );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _GateMessage extends StatelessWidget {
  const _GateMessage({required this.icon, required this.title, required this.text, required this.actions, this.error = false});
  final IconData icon;
  final String title;
  final String text;
  final List<Widget> actions;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Icon(icon, size: 56, color: error ? theme.colorScheme.error : theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(text, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ...actions,
            ]),
          ),
        ),
      ),
    );
  }
}

/// Only reached when sign-up gave a session before the email was confirmed (email confirmation switched off).
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});
  final String email;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  bool _busy = false;

  Future<void> _resend() async {
    setState(() => _busy = true);
    try {
      await Api.resendVerification(widget.email);
      if (mounted) toast(context, 'Sent. Check your inbox and spam folder.');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send it: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.auth.refreshSession();
      if (Supabase.instance.client.auth.currentUser?.emailConfirmedAt == null && mounted) {
        toast(context, 'Not verified yet. Open the link in the email first.');
      }
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _GateMessage(
        icon: Icons.mark_email_unread_outlined,
        title: 'Verify your email',
        text: 'We sent a link to ${widget.email}. Open it to verify your address, then come back here.',
        actions: [
          FilledButton(onPressed: _busy ? null : _check, child: const Text('I\'ve verified it')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _busy ? null : _resend, child: const Text('Send the link again')),
          const SizedBox(height: 8),
          TextButton(onPressed: () => Supabase.instance.client.auth.signOut(), child: const Text('Sign out')),
        ],
      );
}

class BlockedScreen extends StatelessWidget {
  const BlockedScreen({super.key, required this.email});
  final String email;

  @override
  Widget build(BuildContext context) => _GateMessage(
        icon: Icons.block,
        error: true,
        title: 'This account is blocked',
        text: 'If you think this is a mistake, email ${AppConfig.supportEmail} from $email.',
        actions: [
          OutlinedButton.icon(
            onPressed: () => Supabase.instance.client.auth.signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
        ],
      );
}
