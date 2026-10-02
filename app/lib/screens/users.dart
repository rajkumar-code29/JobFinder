import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../config.dart';
import '../widgets/access_gate.dart';
import '../widgets/common.dart';

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

  @override
  void initState() {
    super.initState();
    // new registrations and approvals show up without a manual refresh
    if (Api.isAdmin) {
      _sub = Api.accountsStream().skip(1).listen((_) {
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

  Future<void> _setStatus(Map<String, dynamic> u, String status) async {
    if (status == 'rejected') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(accessStatus(u) == 'approved' ? 'Remove access?' : 'Reject this registration?'),
          content: Text('${_name(u)} (${u['email']}) won\'t be able to use Pounce and their agents stop. '
              'You can approve them again later.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(accessStatus(u) == 'approved' ? 'Remove access' : 'Reject'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await Api.adminSetStatus(u['user_id'] as String, status);
      if (mounted) toast(context, status == 'approved' ? 'Approved ${u['email']}' : 'Access removed for ${u['email']}');
      _reload();
    } catch (e) {
      if (mounted) toast(context, 'Could not update: $e');
    }
  }

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
                  if (snap.hasError) return ErrorView('${snap.error}\n\nRun supabase/migrations/008_registration_and_approval.sql.');
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final users = snap.data!;
                  final pending = users.where((u) => accessStatus(u) == 'pending').toList()
                    ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
                  final approved = users.where((u) => accessStatus(u) == 'approved').toList();
                  final rejected = users.where((u) => accessStatus(u) == 'rejected').toList();
                  final storage = users.fold<double>(0, (a, u) => a + ((u['storage_mb'] as num?)?.toDouble() ?? 0));
                  final theme = Theme.of(context);
                  return PageBody(
                    maxWidth: 900,
                    child: ListView(padding: const EdgeInsets.all(16), children: [
                      Text('${approved.length} users · ${storage.toStringAsFixed(0)} MB of files in total (Supabase free tier: 1 GB). '
                          'People register from the sign-in page and wait here until you approve them.',
                          style: theme.textTheme.bodySmall),
                      const SizedBox(height: 12),
                      if (pending.isNotEmpty) ...[
                        Text('Waiting for approval (${pending.length})', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        for (final u in pending) _PendingCard(user: u, onStatus: _setStatus),
                        const SizedBox(height: 12),
                        Text('Users', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                      ],
                      for (final u in approved) _UserCard(user: u, onUpdate: _update, onStatus: _setStatus),
                      if (rejected.isNotEmpty)
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: ExpansionTile(
                            leading: const Icon(Icons.block),
                            title: Text('Not approved (${rejected.length})'),
                            children: [
                              for (final u in rejected)
                                ListTile(
                                  title: Text(_name(u)),
                                  subtitle: Text('${u['email']}'),
                                  trailing: TextButton(onPressed: () => _setStatus(u, 'approved'), child: const Text('Approve')),
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

String _mobile(Map<String, dynamic> u) => switch ((u['wants_mobile_app'], u['mobile_platform'])) {
      (true, 'ios') => 'Wants the iPhone app',
      (true, 'android') => 'Wants the Android app',
      (false, _) => 'No mobile app',
      _ => 'Mobile app: not asked',
    };

typedef _StatusAction = Future<void> Function(Map<String, dynamic>, String);

class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.user, required this.onStatus});
  final Map<String, dynamic> user;
  final _StatusAction onStatus;

  @override
  Widget build(BuildContext context) {
    final u = user;
    final theme = Theme.of(context);
    final phone = u['phone'] as String?;
    final adminDomain = '${u['email']}'.toLowerCase().endsWith('@${AppConfig.adminEmailDomain}');
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.person_add_alt_1),
            const SizedBox(width: 8),
            Expanded(child: Text(_name(u), style: theme.textTheme.titleMedium)),
            Text('registered ${ago(DateTime.parse(u['created_at'] as String).toLocal())}', style: theme.textTheme.bodySmall),
          ]),
          const SizedBox(height: 4),
          Text('${u['email']}'),
          if (phone != null)
            InkWell(
              onTap: () => launchUrl(Uri(scheme: 'tel', path: phone)),
              child: Text(phone, style: TextStyle(color: theme.colorScheme.primary)),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            Chip(visualDensity: VisualDensity.compact, avatar: const Icon(Icons.phone_iphone, size: 16), label: Text(_mobile(u), style: const TextStyle(fontSize: 12))),
            if (u['email_confirmed'] == false)
              const Chip(visualDensity: VisualDensity.compact, avatar: Icon(Icons.mark_email_unread_outlined, size: 16), label: Text('Email not confirmed yet', style: TextStyle(fontSize: 12))),
            if (adminDomain)
              Chip(
                visualDensity: VisualDensity.compact,
                backgroundColor: Colors.orange.withValues(alpha: 0.2),
                avatar: const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                label: const Text('Admin domain: gets admin rights if approved', style: TextStyle(fontSize: 12)),
              ),
          ]),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            OutlinedButton(onPressed: () => onStatus(u, 'rejected'), child: const Text('Reject')),
            const SizedBox(width: 8),
            FilledButton.icon(onPressed: () => onStatus(u, 'approved'), icon: const Icon(Icons.check), label: const Text('Approve')),
          ]),
        ]),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user, required this.onUpdate, required this.onStatus});
  final Map<String, dynamic> user;
  final Future<void> Function(Map<String, dynamic>, {bool? enabled, bool? shared, int? calls}) onUpdate;
  final _StatusAction onStatus;

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
            if (u['email'] != Api.currentEmail)
              PopupMenuButton<String>(
                onSelected: (v) => onStatus(u, v),
                itemBuilder: (_) => const [PopupMenuItem(value: 'rejected', child: Text('Remove access'))],
              ),
          ]),
          if (u['first_name'] != null)
            Text('${_name(u)}${u['phone'] != null ? ' · ${u['phone']}' : ''} · ${_mobile(u)}', style: theme.textTheme.bodyMedium),
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
