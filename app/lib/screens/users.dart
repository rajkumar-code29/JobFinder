import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../widgets/access_gate.dart';
import '../widgets/common.dart';
import 'admin.dart';

/// Admin view of all users.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  late Future<List<Map<String, dynamic>>> _future = Api.adminUsers();
  StreamSubscription? _sub;
  Timer? _debounce;
  Map<String, int> _credits = {};
  bool _first = true;

  @override
  void initState() {
    super.initState();
    // credits come live from the accounts rows; new sign-ups show up without a manual refresh
    if (Api.isAdmin) {
      _sub = Api.accountsStream().listen((rows) {
        setState(() => _credits = {for (final r in rows) '${r['user_id']}': (r['credits'] as num?)?.toInt() ?? 0});
        if (_first) {
          _first = false;
          return;
        }
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 600), () {
          if (mounted) _reload();
        });
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  void _reload() => setState(() => _future = Api.adminUsers());

  String _query = '';

  Future<void> _setStatus(Map<String, dynamic> u, String status) async {
    if (status == 'rejected') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Block this account?'),
          content: Text('${_name(u)} (${u['email']}) won\'t be able to use Pounce and their agents stop. '
              'You can unblock them later.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await Api.adminSetStatus(u['user_id'] as String, status);
      if (mounted) toast(context, status == 'approved' ? 'Unblocked ${u['email']}' : 'Blocked ${u['email']}');
      _reload();
    } catch (e) {
      if (mounted) toast(context, 'Could not update: $e');
    }
  }

  Future<void> _update(Map<String, dynamic> u, {bool? enabled, int? calls}) async {
    try {
      await Api.adminUpdateAccount(
        u['user_id'] as String,
        enabled: enabled ?? u['enabled'] == true,
        useSharedKeys: true,
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
                  if (snap.hasError) return ErrorView('${snap.error}\n\nRun the migrations up to 011.');
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final q = _query.toLowerCase();
                  final users = snap.data!
                      .where((u) => q.isEmpty || '${u['email']} ${_name(u)}'.toLowerCase().contains(q))
                      .toList()
                    ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
                  final active = users.where((u) => accessStatus(u) != 'rejected').toList();
                  final blocked = users.where((u) => accessStatus(u) == 'rejected').toList();
                  final storage = users.fold<double>(0, (a, u) => a + ((u['storage_mb'] as num?)?.toDouble() ?? 0));
                  final theme = Theme.of(context);
                  return PageBody(
                    maxWidth: 900,
                    child: ListView(padding: const EdgeInsets.all(16), children: [
                      TextField(
                        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by name or email'),
                        onChanged: (v) => setState(() => _query = v.trim()),
                      ),
                      const SizedBox(height: 8),
                      Text('${active.length} users · ${storage.toStringAsFixed(0)} MB of files in total (Supabase free tier: 1 GB). '
                          'Anyone can sign up; they verify their email and agree to the privacy notice first.',
                          style: theme.textTheme.bodySmall),
                      const SizedBox(height: 12),
                      for (final u in active)
                        _UserCard(
                          user: u,
                          credits: _credits['${u['user_id']}'],
                          onUpdate: _update,
                          onStatus: _setStatus,
                          onCredits: () => adjustCredits(context,
                              userId: '${u['user_id']}', email: '${u['email']}', current: _credits['${u['user_id']}'] ?? 0),
                        ),
                      if (blocked.isNotEmpty)
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: ExpansionTile(
                            leading: const Icon(Icons.block),
                            title: Text('Blocked (${blocked.length})'),
                            children: [
                              for (final u in blocked)
                                ListTile(
                                  title: Text(_name(u)),
                                  subtitle: Text('${u['email']}'),
                                  trailing: TextButton(onPressed: () => _setStatus(u, 'approved'), child: const Text('Unblock')),
                                ),
                            ],
                          ),
                        ),
                    ]),
                  );
                },
              ),
      );
}

String _name(Map<String, dynamic> u) {
  final name = [u['first_name'], u['last_name']].whereType<String>().join(' ');
  return name.isEmpty ? '${u['email']}' : name;
}

typedef _StatusAction = Future<void> Function(Map<String, dynamic>, String);

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user, required this.onUpdate, required this.onStatus, this.credits, required this.onCredits});
  final Map<String, dynamic> user;
  final int? credits;
  final VoidCallback onCredits;
  final Future<void> Function(Map<String, dynamic>, {bool? enabled, int? calls}) onUpdate;
  final _StatusAction onStatus;

  @override
  Widget build(BuildContext context) {
    final u = user;
    final theme = Theme.of(context);
    int n(String k) => (u[k] as num?)?.toInt() ?? 0;
    DateTime? t(String k) => u[k] == null ? null : DateTime.parse(u[k] as String).toLocal();
    final setup = [
      ('Resume .docx', u['has_resume_docx'] == true),
      ('Email verified', u['email_confirmed'] != false),
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
            ActionChip(
              avatar: const Icon(Icons.toll_outlined, size: 16),
              label: Text(credits == null ? 'Credits' : '$credits credits'),
              onPressed: onCredits,
            ),
            const SizedBox(width: 6),
            Text('${(u['storage_mb'] as num?) ?? 0} MB', style: theme.textTheme.bodySmall),
            if (u['email'] != Api.currentEmail)
              PopupMenuButton<String>(
                onSelected: (v) => onStatus(u, v),
                itemBuilder: (_) => const [PopupMenuItem(value: 'rejected', child: Text('Block'))],
              ),
          ]),
          if (u['first_name'] != null)
            Text(_name(u), style: theme.textTheme.bodyMedium),
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
