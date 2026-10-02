import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api.dart';
import '../config.dart';
import 'common.dart';

/// 'approved', 'pending' or 'rejected'. Rows from before migration 008 have no status and count as approved.
String accessStatus(Map<String, dynamic>? account) {
  if (account == null) return 'pending';
  return account['status'] as String? ?? 'approved';
}

/// Shows the app only to approved accounts. The database enforces the same rule (migration 008);
/// this just explains it and opens up live when an admin approves.
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
    final status = accessStatus(account);
    return status == 'approved' ? widget.child : WaitingForApproval(account: account, rejected: status == 'rejected');
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

class WaitingForApproval extends StatelessWidget {
  const WaitingForApproval({super.key, required this.account, required this.rejected});
  final Map<String, dynamic>? account;
  final bool rejected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = account?['first_name'] as String?;
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Icon(rejected ? Icons.block : Icons.hourglass_top, size: 56,
                  color: rejected ? theme.colorScheme.error : theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                rejected
                    ? 'Your account wasn\'t approved'
                    : 'Thanks${name == null ? '' : ', $name'}! You\'re on the list',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                rejected
                    ? 'If you think this is a mistake, email ${AppConfig.supportEmail} from $email.'
                    : 'An admin reviews every new account. This screen opens Pounce by itself as soon as '
                        'you\'re approved, so you can leave it open or come back later.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text('Signed in as $email', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => Supabase.instance.client.auth.signOut(),
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
