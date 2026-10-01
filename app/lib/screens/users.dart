import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../widgets/common.dart';

/// Admin view of all users.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  late Future<List<Map<String, dynamic>>> _future = Api.adminUsers();

  void _reload() => setState(() => _future = Api.adminUsers());

  Future<void> _update(Map<String, dynamic> u, {bool? enabled, bool? shared, int? calls}) async {
    try {
      await Api.adminUpdateAccount(
        u['user_id'] as String,
        enabled: enabled ?? u['enabled'] == true,
        useSharedKeys: shared ?? u['use_shared_keys'] == true,
        llmCalls: calls ?? (u['llm_calls_per_run'] as num).toInt(),
      );
      _reload();
    } catch (e) {
      if (mounted) toast(context, 'Could not update: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/settings')),
          title: const Text('Users'),
          actions: [IconButton(onPressed: _reload, icon: const Icon(Icons.refresh))],
        ),
        body: !Api.isAdmin
            ? const Center(child: Text('Admins only'))
            : FutureBuilder<List<Map<String, dynamic>>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.hasError) return ErrorView('${snap.error}\n\nRun supabase/migrations/007_onboarding_and_users.sql.');
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final users = snap.data!;
                  final storage = users.fold<double>(0, (a, u) => a + ((u['storage_mb'] as num?)?.toDouble() ?? 0));
                  return PageBody(
                    maxWidth: 900,
                    child: ListView(padding: const EdgeInsets.all(16), children: [
                      Text('${users.length} users · ${storage.toStringAsFixed(0)} MB of files in total (Supabase free tier: 1 GB). '
                          'Add people in Supabase > Authentication > Users.', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 12),
                      for (final u in users) _UserCard(user: u, onUpdate: _update),
                    ]),
                  );
                },
              ),
      );
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user, required this.onUpdate});
  final Map<String, dynamic> user;
  final Future<void> Function(Map<String, dynamic>, {bool? enabled, bool? shared, int? calls}) onUpdate;

  @override
  Widget build(BuildContext context) {
    final u = user;
    final theme = Theme.of(context);
    int n(String k) => (u[k] as num?)?.toInt() ?? 0;
    DateTime? t(String k) => u[k] == null ? null : DateTime.parse(u[k] as String).toLocal();
    final setup = [
      ('Resume .docx', u['has_resume_docx'] == true),
      ('AI key', n('ai_keys') > 0 || u['use_shared_keys'] == true),
      ('Locations', u['has_locations'] == true),
      ('Roles', u['has_roles'] == true),
      ('Privacy notice', u['privacy_accepted'] == true),
    ];
    final lastRun = t('last_run_at');
    final calls = n('llm_calls_per_run');
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(u['enabled'] == true ? Icons.person : Icons.person_off, color: u['enabled'] == true ? null : Colors.grey),
            const SizedBox(width: 8),
            Expanded(child: Text('${u['email']}', style: theme.textTheme.titleMedium)),
            Text('${(u['storage_mb'] as num?) ?? 0} MB', style: theme.textTheme.bodySmall),
          ]),
          Text('Joined ${ago(t('created_at')!)} · last sign-in ${t('last_sign_in_at') == null ? 'never' : ago(t('last_sign_in_at')!)}',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final (label, ok) in setup)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(ok ? Icons.check_circle : Icons.cancel, size: 16, color: ok ? Colors.green : Colors.red),
                label: Text(label, style: const TextStyle(fontSize: 12)),
              ),
          ]),
          const SizedBox(height: 6),
          Text('Jobs ${n('jobs_total')} · ready ${n('jobs_ready')} · applied ${n('jobs_applied')} · errors ${n('jobs_error')}'
              '${u['open_batch'] != null ? ' · working on Batch #${u['open_batch']}' : ''}', style: theme.textTheme.bodyMedium),
          Text(lastRun == null ? 'No runs yet' : 'Last run ${ago(lastRun)} · ${u['last_run_status']} · ${n('last_run_errors')} errors',
              style: theme.textTheme.bodySmall),
          if (u['last_run_note'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${u['last_run_note']}', style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange.shade800)),
            ),
          const Divider(height: 20),
          Wrap(spacing: 16, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(value: u['enabled'] == true, onChanged: (v) => onUpdate(u, enabled: v)),
              const Text('Agents on'),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(value: u['use_shared_keys'] == true, onChanged: (v) => onUpdate(u, shared: v)),
              const Text('May use shared keys'),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Text('AI calls per run'),
              IconButton(onPressed: calls > 5 ? () => onUpdate(u, calls: calls - 10 < 5 ? 5 : calls - 10) : null, icon: const Icon(Icons.remove_circle_outline)),
              Text('$calls'),
              IconButton(onPressed: calls < 200 ? () => onUpdate(u, calls: calls + 10) : null, icon: const Icon(Icons.add_circle_outline)),
            ]),
          ]),
        ]),
      ),
    );
  }
}
