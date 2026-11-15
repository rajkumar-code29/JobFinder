import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../widgets/common.dart';
import '../widgets/credits.dart';

/// Admin tools for @rajkumar.codes accounts. The database checks is_admin() on every one of these.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tools = [
      (Icons.group_outlined, 'Users and credits', 'Search people, add or remove credits, block accounts', '/admin/users'),
      (Icons.post_add, 'Add a job', 'Put a job on the board for everyone, or straight into one person\'s matches', '/admin/add-job'),
      (Icons.tune, 'AI models', 'Which model each agent uses, scorecards and comparisons', '/models'),
      (Icons.key_outlined, 'Shared keys', 'The AI and job-search keys everyone runs on (in Settings)', '/settings'),
    ];
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/settings')),
        title: const Text('Admin'),
      ),
      body: !Api.isAdmin
          ? const Center(child: Text('Admins only'))
          : ListView(padding: const EdgeInsets.all(16), children: [
              PageBody(
                maxWidth: 860,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final (icon, title, text, route) in tools)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Card(
                        child: ListTile(
                          leading: Icon(icon),
                          title: Text(title),
                          subtitle: Text(text),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.push(route),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  const _Referrals(),
                ]),
              ),
            ]),
    );
  }
}

class _Referrals extends StatefulWidget {
  const _Referrals();

  @override
  State<_Referrals> createState() => _ReferralsState();
}

class _ReferralsState extends State<_Referrals> {
  late Future<List<Map<String, dynamic>>> _future = Api.adminReferrals();

  static const _reasons = {
    'email_used': 'email already had credits',
    'disposable_email': 'throwaway email',
    'self': 'own code',
    'invalid_code': 'unknown code',
    'referrer_limit': 'code at its limit',
    'referrer_daily_limit': 'code at its daily limit',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Referrals', style: theme.textTheme.titleMedium)),
            IconButton(onPressed: () => setState(() => _future = Api.adminReferrals()), icon: const Icon(Icons.refresh)),
          ]),
          Text('30 credits each for the new user and the referrer, once per email address, at most 5 a day and 20 in '
              'total per code. Declined ones show why: lots from one code is worth a look.',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) return Text(errorText(snap.error!), style: TextStyle(color: theme.colorScheme.error));
              if (!snap.hasData) return const LinearProgressIndicator();
              final rows = snap.data!;
              if (rows.isEmpty) return const Text('No referrals yet.');
              final declined = rows.where((r) => r['status'] == 'declined').length;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${rows.length - declined} rewarded · $declined declined', style: theme.textTheme.labelLarge),
                for (final r in rows.take(100))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(r['status'] == 'rewarded' ? Icons.check_circle : Icons.block,
                        color: r['status'] == 'rewarded' ? Colors.green : theme.colorScheme.error),
                    title: Text('${r['referee_email']}'),
                    subtitle: Text([
                      'code ${r['code']} from ${r['referrer_email']}',
                      if (r['reason'] != null) _reasons[r['reason']] ?? '${r['reason']}',
                      DateFormat.yMMMd().add_jm().format(DateTime.parse('${r['created_at']}').toLocal()),
                    ].join(' · ')),
                  ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

/// Add a job by hand: to the shared board, or into one user's matches.
class AdminAddJobScreen extends StatefulWidget {
  const AdminAddJobScreen({super.key});

  @override
  State<AdminAddJobScreen> createState() => _AdminAddJobScreenState();
}

class _AdminAddJobScreenState extends State<AdminAddJobScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _company = TextEditingController();
  final _location = TextEditingController();
  final _url = TextEditingController();
  final _salary = TextEditingController();
  final _description = TextEditingController();
  String _remote = '';
  String _type = '';
  bool _forOne = false;
  Map<String, dynamic>? _user;
  bool _busy = false;

  Future<void> _pickUser() async {
    final picked = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const UserPicker());
    if (picked != null) setState(() => _user = picked);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_forOne && _user == null) {
      toast(context, 'Pick the user first');
      return;
    }
    setState(() => _busy = true);
    try {
      String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
      final result = await Api.adminAddJob(
        title: _title.text.trim(),
        company: _company.text.trim(),
        description: _description.text.trim(),
        location: opt(_location),
        url: opt(_url),
        remote: _remote.isEmpty ? null : _remote,
        type: _type.isEmpty ? null : _type,
        salary: opt(_salary),
        userId: _forOne ? _user!['user_id'] as String : null,
      );
      if (!mounted) return;
      toast(context, result == 'board' ? 'Added to the Jobs board' : 'Added to ${_user!['email']}\'s matches as $result');
      for (final c in [_title, _company, _location, _url, _salary, _description]) {
        c.clear();
      }
    } catch (e) {
      if (mounted) toast(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    InputDecoration d(String label, {String? hint}) => InputDecoration(labelText: label, hintText: hint);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/admin')),
        title: const Text('Add a job'),
      ),
      body: !Api.isAdmin
          ? const Center(child: Text('Admins only'))
          : ListView(padding: const EdgeInsets.all(16), children: [
              PageBody(
                maxWidth: 760,
                child: Form(
                  key: _form,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Jobs board, for everyone'), icon: Icon(Icons.public)),
                        ButtonSegment(value: true, label: Text('One person'), icon: Icon(Icons.person_outline)),
                      ],
                      selected: {_forOne},
                      onSelectionChanged: (v) => setState(() => _forOne = v.first),
                    ),
                    const SizedBox(height: 10),
                    if (_forOne)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.person_search),
                          title: Text(_user == null ? 'Pick a user' : '${_user!['email']}'),
                          subtitle: Text(_user == null
                              ? 'It goes into their matches and gets scored on their next run'
                              : [_user!['first_name'], _user!['last_name']].whereType<String>().join(' ')),
                          trailing: TextButton(onPressed: _pickUser, child: Text(_user == null ? 'Search' : 'Change')),
                        ),
                      )
                    else
                      Text('It shows on the Jobs board for every user, and stays for 30 days.', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _title,
                      decoration: d('Job title'),
                      validator: (v) => (v ?? '').trim().length < 2 ? 'Add the job title' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(controller: _company, decoration: d('Company')),
                    const SizedBox(height: 12),
                    TextFormField(controller: _location, decoration: d('Location', hint: 'London, UK')),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _remote,
                          isExpanded: true,
                          decoration: d('Workplace'),
                          items: const [
                            DropdownMenuItem(value: '', child: Text('Not stated')),
                            DropdownMenuItem(value: 'Remote', child: Text('Remote')),
                            DropdownMenuItem(value: 'Hybrid', child: Text('Hybrid')),
                            DropdownMenuItem(value: 'On-site', child: Text('On-site')),
                          ],
                          onChanged: (v) => setState(() => _remote = v ?? ''),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _type,
                          isExpanded: true,
                          decoration: d('Job type'),
                          items: const [
                            DropdownMenuItem(value: '', child: Text('Not stated')),
                            DropdownMenuItem(value: 'Full-time', child: Text('Full-time')),
                            DropdownMenuItem(value: 'Part-time', child: Text('Part-time')),
                            DropdownMenuItem(value: 'Contract', child: Text('Contract')),
                            DropdownMenuItem(value: 'Internship', child: Text('Internship')),
                          ],
                          onChanged: (v) => setState(() => _type = v ?? ''),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    TextFormField(controller: _salary, decoration: d('Salary (optional)', hint: '£28,000 – £32,000')),
                    const SizedBox(height: 12),
                    TextFormField(controller: _url, keyboardType: TextInputType.url, decoration: d('Link to apply (optional)')),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _description,
                      minLines: 6,
                      maxLines: 18,
                      decoration: d('Job description').copyWith(alignLabelWithHint: true),
                      validator: (v) => (v ?? '').trim().length < 50 ? 'Paste the full job description' : null,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.add),
                      label: Text(_forOne ? 'Add to their matches' : 'Add to the Jobs board'),
                    ),
                  ]),
                ),
              ),
            ]),
    );
  }
}

/// Search accounts by name or email; returns the chosen row.
class UserPicker extends StatefulWidget {
  const UserPicker({super.key});

  @override
  State<UserPicker> createState() => _UserPickerState();
}

class _UserPickerState extends State<UserPicker> {
  late Future<List<Map<String, dynamic>>> _future = Api.adminSearchUsers('');
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Find a user'),
        content: SizedBox(
          width: 480,
          height: 420,
          child: Column(children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name or email'),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350),
                    () => setState(() => _future = Api.adminSearchUsers(v.trim())));
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.hasError) return Text(errorText(snap.error!));
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  if (snap.data!.isEmpty) return const Center(child: Text('Nobody matches'));
                  return ListView(children: [
                    for (final u in snap.data!)
                      ListTile(
                        title: Text('${u['email']}'),
                        subtitle: Text('${[u['first_name'], u['last_name']].whereType<String>().join(' ')} · ${u['credits']} credits'),
                        onTap: () => Navigator.pop(context, u),
                      ),
                  ]);
                },
              ),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
      );
}

/// Give or take credits, with a note that shows in the user's history.
Future<bool> adjustCredits(BuildContext context, {required String userId, required String email, required int current}) async {
  final amount = TextEditingController(text: '10');
  final note = TextEditingController();
  var add = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('Credits for $email'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('They have $current now.'),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Add'), icon: Icon(Icons.add)),
                ButtonSegment(value: false, label: Text('Remove'), icon: Icon(Icons.remove)),
              ],
              selected: {add},
              onSelectionChanged: (v) => setState(() => add = v.first),
            ),
            const SizedBox(height: 12),
            TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'How many')),
            const SizedBox(height: 12),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Note they will see (optional)', hintText: 'Thanks for testing')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  final n = int.tryParse(amount.text.trim()) ?? 0;
  if (n <= 0) {
    if (context.mounted) toast(context, 'Enter a number above 0');
    return false;
  }
  try {
    final balance = await Api.adminAddCredits(userId, add ? n : -n, note.text.trim());
    if (context.mounted) toast(context, '$email now has $balance credits');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, errorText(e));
    return false;
  }
}
