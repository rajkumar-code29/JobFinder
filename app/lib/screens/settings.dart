import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../boards.dart';
import '../key_guides.dart';
import '../countries.dart';
import '../widgets/common.dart';

const sourceInfo = {
  'adzuna': ('Adzuna', 'Aggregator, 19 countries (free key)'),
  'jsearch': ('JSearch', 'Google for Jobs: LinkedIn, Indeed, Glassdoor… (once a day, free tier)'),
  'remotive': ('Remotive', 'Remote jobs (every 6h)'),
  'arbeitnow': ('Arbeitnow', 'Europe / Germany feed'),
  'google_search': ('Google Search (Gemini)', 'Grounded web search for postings (every 4h)'),
};

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, dynamic>? _s;
  Object? _error;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await Api.settings();
      setState(() {
        _s = s;
        _dirty = false;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  void _set(String key, Object? value) => setState(() {
        _s![key] = value;
        _dirty = true;
      });

  List<String> _list(String key) => ((_s![key] as List?) ?? []).map((e) => '$e').toList();

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final s = Map<String, dynamic>.from(_s!)..remove('user_id')..remove('updated_at');
      await Api.saveSettings(s);
      setState(() => _dirty = false);
      if (mounted) toast(context, 'Saved. Agents use these settings from the next run.');
    } catch (e) {
      if (mounted) toast(context, 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), actions: [
        IconButton(tooltip: 'How it works', icon: const Icon(Icons.help_outline), onPressed: () => context.push('/help')),
        if (Api.isAdmin)
          IconButton(tooltip: 'Users (admin)', icon: const Icon(Icons.group_outlined), onPressed: () => context.push('/admin/users')),
        IconButton(
          tooltip: 'Change password',
          icon: const Icon(Icons.password),
          onPressed: () => context.push('/set-password'),
        ),
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: () => Supabase.instance.client.auth.signOut(),
        ),
      ]),
      floatingActionButton: _dirty
          ? FloatingActionButton.extended(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              label: const Text('Save'),
            )
          : null,
      body: s == null
          ? (_error != null ? ErrorView(_error!, onRetry: _load) : const Center(child: CircularProgressIndicator()))
          : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
              PageBody(
                maxWidth: 860,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const _ParentDocs(),
                  if (Api.isAdmin) const _SharedKeys(),
                  const _ApiKeys(),
                  _Section(
                    title: 'Locations',
                    subtitle: 'Countries, or any city/region you type (custom locations are searched via Google)',
                    child: Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final c in _list('countries'))
                        InputChip(
                          avatar: Icon(countryNames.containsKey(c) ? Icons.flag_outlined : Icons.place_outlined, size: 18),
                          label: Text(locationLabel(c)),
                          onDeleted: () => _set('countries', _list('countries')..remove(c)),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('Add location'),
                        onPressed: () async {
                          final picked = await showDialog<String>(
                            context: context,
                            builder: (_) => LocationPicker(existing: _list('countries')),
                          );
                          if (picked != null && !_list('countries').contains(picked)) {
                            _set('countries', [..._list('countries'), picked]);
                          }
                        },
                      ),
                    ]),
                  ),
                  _Section(
                    title: 'Target roles',
                    subtitle: 'Leave empty to use the titles the Profile agent derives from your resume',
                    child: _ChipsEditor(values: _list('target_roles'), hint: 'e.g. Senior Flutter Developer', onChanged: (v) => _set('target_roles', v)),
                  ),
                  _Section(
                    title: 'Extra keywords',
                    subtitle: 'A posting containing any of these always gets considered',
                    child: _ChipsEditor(values: _list('keywords'), hint: 'e.g. Firebase', onChanged: (v) => _set('keywords', v)),
                  ),
                  _Section(
                    title: 'Exclude titles containing',
                    child: _ChipsEditor(values: _list('exclude_keywords'), hint: 'e.g. intern', onChanged: (v) => _set('exclude_keywords', v)),
                  ),
                  _Section(
                    title: 'Job boards & career pages',
                    subtitle: 'Company boards on Greenhouse, Lever, Ashby, Workable, Workday or SmartRecruiters are read '
                        'directly (every open job, full descriptions). Any other link (LinkedIn, Indeed, a careers page) '
                        'is searched via Google every 4 hours; only its domain is used, not search filters in the link.',
                    child: _BoardsEditor(
                      boards: ((s['job_boards'] as List?) ?? []).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList(),
                      onChanged: (v) => _set('job_boards', v),
                    ),
                  ),
                  _Section(
                    title: 'Sources',
                    child: Column(children: [
                      for (final e in sourceInfo.entries)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(e.value.$1),
                          subtitle: Text(e.value.$2),
                          value: (s['sources'] as Map?)?[e.key] != false,
                          onChanged: (v) => _set('sources', {...(s['sources'] as Map? ?? {}), e.key: v}),
                        ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Include remote jobs'),
                        value: s['remote_ok'] == true,
                        onChanged: (v) => _set('remote_ok', v),
                      ),
                    ]),
                  ),
                  _Section(
                    title: 'Agent tuning',
                    child: Column(children: [
                      _SliderRow(
                        label: 'Minimum resume match to keep a job',
                        value: (s['min_relevance'] as num).toInt(), min: 30, max: 95,
                        onChanged: (v) => _set('min_relevance', v),
                      ),
                      _SliderRow(
                        label: 'Target ATS score for tailored resume',
                        value: (s['target_ats'] as num).toInt(), min: 70, max: 99,
                        onChanged: (v) => _set('target_ats', v),
                      ),
                      _SliderRow(
                        label: 'Jobs per batch',
                        value: ((s['batch_size'] as num?) ?? 20).toInt(), min: 5, max: 30, suffix: '',
                        onChanged: (v) => _set('batch_size', v),
                      ),
                      _SliderRow(
                        label: 'Jobs fully processed per hourly run',
                        value: (s['max_jobs_per_run'] as num).toInt(), min: 1, max: 10, suffix: '',
                        onChanged: (v) => _set('max_jobs_per_run', v),
                      ),
                      Text(
                        'Each processed job uses ~6 Gemini calls. Keep this low on the free tier; '
                        'leftover jobs are processed in later runs.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ]),
                  ),
                ]),
              ),
            ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.child});
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              child,
            ]),
          ),
        ),
      );
}

class _ChipsEditor extends StatefulWidget {
  const _ChipsEditor({required this.values, required this.onChanged, required this.hint});
  final List<String> values;
  final ValueChanged<List<String>> onChanged;
  final String hint;

  @override
  State<_ChipsEditor> createState() => _ChipsEditorState();
}

class _ChipsEditorState extends State<_ChipsEditor> {
  final _ctrl = TextEditingController();

  void _add() {
    final parts = _ctrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty && !widget.values.contains(e));
    if (parts.isEmpty) return;
    widget.onChanged([...widget.values, ...parts]);
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final v in widget.values)
            InputChip(label: Text(v), onDeleted: () => widget.onChanged([...widget.values]..remove(v))),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _ctrl,
          onSubmitted: (_) => _add(),
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.hint,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _add),
          ),
        ),
      ]);
}

class _BoardsEditor extends StatefulWidget {
  const _BoardsEditor({required this.boards, required this.onChanged});
  final List<Map<String, dynamic>> boards;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;

  @override
  State<_BoardsEditor> createState() => _BoardsEditorState();
}

class _BoardsEditorState extends State<_BoardsEditor> {
  final _ctrl = TextEditingController();

  void _add() {
    final url = _ctrl.text.trim();
    if (url.isEmpty) return;
    widget.onChanged([...widget.boards, {'url': url, 'enabled': true}]);
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        for (final (i, b) in widget.boards.indexed)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Switch(
              value: b['enabled'] != false,
              onChanged: (v) {
                final next = [...widget.boards];
                next[i] = {...b, 'enabled': v};
                widget.onChanged(next);
              },
            ),
            title: Text('${b['url']}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: _BoardKindText(kind: boardKind('${b['url']}')),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => widget.onChanged([...widget.boards]..removeAt(i)),
            ),
          ),
        TextField(
          controller: _ctrl,
          onSubmitted: (_) => _add(),
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'e.g. https://jobs.lever.co/company',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _add),
          ),
        ),
      ]);
}

class _BoardKindText extends StatelessWidget {
  const _BoardKindText({required this.kind});
  final BoardKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(kind.direct ? Icons.bolt : Icons.travel_explore, size: 14,
            color: kind.direct ? Colors.green : theme.colorScheme.outline),
        const SizedBox(width: 4),
        Text(kind.label),
      ]),
      if (kind.warning != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(kind.warning!, style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange.shade800)),
        ),
    ]);
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.label, required this.value, required this.min, required this.max, required this.onChanged, this.suffix = '%'});
  final String label;
  final int value;
  final int min;
  final int max;
  final String suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(flex: 3, child: Text(label)),
        Expanded(
          flex: 4,
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            label: '$value$suffix',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        SizedBox(width: 44, child: Text('$value$suffix', textAlign: TextAlign.end)),
      ]);
}

/// Parent resume / cover letter upload.
class _ParentDocs extends StatefulWidget {
  const _ParentDocs();

  @override
  State<_ParentDocs> createState() => _ParentDocsState();
}

class _ParentDocsState extends State<_ParentDocs> {
  late Future<(List<String>, List<String>, Map<String, dynamic>)> _future = _load();
  bool _busy = false;

  Future<(List<String>, List<String>, Map<String, dynamic>)> _load() async =>
      (await Api.parentFiles('resume'), await Api.parentFiles('cover_letter'), await Api.profile());

  Future<void> _upload(String folder) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: folder == 'resume' ? ['docx', 'pdf'] : ['docx', 'pdf', 'txt'],
      dialogTitle: folder == 'resume' ? 'Select resume (.docx and/or .pdf)' : 'Select cover letter',
    );
    if (picked.isEmpty) return;
    setState(() => _busy = true);
    try {
      final files = <(String, Uint8List)>[for (final f in picked) (f.name, await f.readAsBytes())];
      await Api.replaceParent(folder, files);
      if (mounted) toast(context, 'Uploaded. The Profile agent re-reads it on the next run.');
      setState(() => _future = _load());
    } catch (e) {
      if (mounted) toast(context, 'Upload failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Section(
        title: 'Parent documents',
        subtitle: 'Your master resume (.docx is required for tailoring; add the .pdf too) and master cover letter',
        child: FutureBuilder<(List<String>, List<String>, Map<String, dynamic>)>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}');
            if (!snap.hasData) return const LinearProgressIndicator();
            final (resume, cover, profile) = snap.data!;
            final skills = ((profile['skills'] as List?) ?? []).map((e) => '$e').toList();
            final titles = ((profile['titles'] as List?) ?? []).map((e) => '$e').toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final (label, folder, files) in [('Resume', 'resume', resume), ('Cover letter', 'cover_letter', cover)])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(folder == 'resume' ? Icons.description_outlined : Icons.mail_outline),
                  title: Text(label),
                  subtitle: Text(files.isEmpty ? 'Not uploaded' : files.map((f) => f.split('/').last).join('\n')),
                  trailing: FilledButton.tonal(
                    onPressed: _busy ? null : () => _upload(folder),
                    child: Text(files.isEmpty ? 'Upload' : 'Replace'),
                  ),
                  onTap: files.isEmpty ? null : () => Api.openFile(files.first, bucket: Api.parentBucket),
                ),
              if (_busy) const LinearProgressIndicator(),
              if (titles.isNotEmpty) ...[
                const Divider(),
                Text('Profile agent sees you as', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(titles.join(' · ')),
              ],
              if (skills.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final sk in skills.take(40)) Chip(label: Text(sk, style: const TextStyle(fontSize: 11))),
                ]),
              ],
            ]);
          },
        ),
      );
}

const providerInfo = {
  'gemini': ('Gemini', 'aistudio.google.com/apikey', Icons.auto_awesome),
  'groq': ('Groq', 'console.groq.com/keys (free tier)', Icons.bolt),
  'openrouter': ('OpenRouter', 'openrouter.ai/keys (free models: 50/day)', Icons.alt_route),
  'adzuna': ('Adzuna', 'developer.adzuna.com', Icons.travel_explore),
  'rapidapi': ('RapidAPI · JSearch', 'rapidapi.com (JSearch free plan)', Icons.hub_outlined),
};

/// The user's own keys, tried in order.
class _ApiKeys extends StatefulWidget {
  const _ApiKeys();

  @override
  State<_ApiKeys> createState() => _ApiKeysState();
}

class _ApiKeysState extends State<_ApiKeys> {
  late Future<(List<Map<String, dynamic>>, Map<String, dynamic>?)> _future = _load();

  Future<(List<Map<String, dynamic>>, Map<String, dynamic>?)> _load() async =>
      (await Api.apiKeys(), await Api.account());

  void _reload() => setState(() => _future = _load());

  Future<void> _add(List<Map<String, dynamic>> existing) async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddKeyDialog(existing: existing),
    );
    if (added == true) _reload();
  }

  Future<void> _delete(Map<String, dynamic> k) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this key?'),
        content: Text('${providerInfo[k['provider']]?.$1 ?? k['provider']} ${k['label']} ${k['hint']}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.deleteApiKey(k['id'] as String);
      _reload();
    } catch (e) {
      if (mounted) toast(context, 'Could not remove key: $e');
    }
  }

  @override
  Widget build(BuildContext context) => _Section(
        title: 'API keys',
        subtitle: 'Your own keys, tried top to bottom. When one hits its free limit the agents switch to the next one '
            'and retry the used-up key after it resets. Keys can\'t be viewed again after saving.',
        child: FutureBuilder<(List<Map<String, dynamic>>, Map<String, dynamic>?)>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Text('${snap.error}');
            if (!snap.hasData) return const LinearProgressIndicator();
            final (keys, account) = snap.data!;
            final theme = Theme.of(context);
            final shared = account?['use_shared_keys'] == true;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${shared ? 'After your own keys, the shared keys are used as a last fallback.' : 'Only your own keys are used - add at least one Gemini key.'}'
                  '  Limit: ${account?['llm_calls_per_run'] ?? '-'} Gemini calls per hourly run.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 8),
              for (final entry in providerInfo.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Icon(entry.value.$3, size: 18),
                    const SizedBox(width: 6),
                    Text(entry.value.$1, style: theme.textTheme.labelLarge),
                  ]),
                ),
                if (!keys.any((k) => k['provider'] == entry.key))
                  Padding(
                    padding: const EdgeInsets.only(left: 24, top: 4),
                    child: Text(shared ? 'No own keys - using shared keys' : 'No keys', style: theme.textTheme.bodySmall),
                  ),
                for (final (i, k) in keys.where((k) => k['provider'] == entry.key).indexed) _KeyTile(index: i + 1, data: k, onDelete: () => _delete(k)),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: () => _add(keys),
                  icon: const Icon(Icons.add),
                  label: const Text('Add API key'),
                ),
              ),
            ]);
          },
        ),
      );
}

class _KeyTile extends StatelessWidget {
  const _KeyTile({required this.index, required this.data, required this.onDelete});
  final int index;
  final Map<String, dynamic> data;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final until = data['exhausted_until'] == null ? null : DateTime.parse(data['exhausted_until'] as String).toLocal();
    final parked = until != null && until.isAfter(DateTime.now());
    final used = data['last_used_at'] == null ? null : DateTime.parse(data['last_used_at'] as String).toLocal();
    final (color, status) = parked
        ? (Colors.orange, 'Limit reached · retried after ${DateFormat.MMMd().add_jm().format(until)}')
        : data['last_error'] != null
            ? (Colors.red, '${data['last_error']}')
            : (Colors.green, used == null ? 'Not used yet' : 'Working · last used ${ago(used)}');
    final label = (data['label'] as String?)?.isNotEmpty == true ? data['label'] as String : 'Key $index';
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 24),
      dense: true,
      leading: CircleAvatar(radius: 12, child: Text('$index', style: const TextStyle(fontSize: 11))),
      title: Text('$label  ${data['hint']}${data['app_id'] != null ? '  (app ${data['app_id']})' : ''}'),
      subtitle: Text(status, style: TextStyle(color: color), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Remove', onPressed: onDelete),
    );
  }
}

class _AddKeyDialog extends StatefulWidget {
  const _AddKeyDialog({required this.existing, this.shared = false});
  final List<Map<String, dynamic>> existing;

  /// add to shared_api_keys instead of api_keys
  final bool shared;

  @override
  State<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends State<_AddKeyDialog> {
  String _provider = 'gemini';
  final _label = TextEditingController();
  final _appId = TextEditingController();
  final _key = TextEditingController();
  bool _saving = false;
  bool _testing = false;
  String? _error;
  KeyTestResult? _test;

  bool get _missing => _key.text.trim().isEmpty || (_provider == 'adzuna' && _appId.text.trim().isEmpty);

  Future<void> _runTest() async {
    if (_missing) {
      setState(() => _error = _provider == 'adzuna' ? 'Enter both the app id and the app key' : 'Paste the key first');
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
      _test = null;
    });
    final result = await testKey(_provider, _key.text, appId: _appId.text);
    if (mounted) {
      setState(() {
        _testing = false;
        _test = result;
      });
    }
  }

  Future<void> _save() async {
    if (_missing) {
      setState(() => _error = _provider == 'adzuna' ? 'Adzuna needs both the app id and the app key' : 'Paste the key');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    // append to the end of the order
    final last = widget.existing
        .where((k) => k['provider'] == _provider)
        .fold<int>(-1, (m, k) => ((k['priority'] as int?) ?? 0) > m ? (k['priority'] as int? ?? 0) : m);
    try {
      await (widget.shared ? Api.addSharedKey : Api.addApiKey)(
        provider: _provider,
        key: _key.text,
        label: _label.text,
        appId: _provider == 'adzuna' ? _appId.text : null,
        priority: last + 1,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final guide = keyGuides[_provider];
    return AlertDialog(
      title: const Text('Add API key'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider', border: OutlineInputBorder()),
              items: [
                for (final e in providerInfo.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
              ],
              onChanged: (v) => setState(() {
                _provider = v ?? 'gemini';
                _test = null;
              }),
            ),
            if (guide != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('How to get this key', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  for (final (i, step) in guide.steps.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        CircleAvatar(radius: 9, child: Text('${i + 1}', style: const TextStyle(fontSize: 10))),
                        const SizedBox(width: 8),
                        Expanded(child: Text(step, style: theme.textTheme.bodySmall)),
                      ]),
                    ),
                  if (guide.note != null) ...[
                    const SizedBox(height: 4),
                    Text(guide.note!, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                  ],
                  const SizedBox(height: 4),
                  TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    onPressed: () => launchUrl(Uri.parse(guide.url), mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(Uri.parse(guide.url).host),
                  ),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label (optional)', hintText: 'e.g. Personal', border: OutlineInputBorder()),
            ),
            if (_provider == 'adzuna') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _appId,
                onChanged: (_) => setState(() => _test = null),
                decoration: const InputDecoration(labelText: 'Adzuna app id', border: OutlineInputBorder()),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() => _test = null),
              decoration: InputDecoration(
                labelText: _provider == 'adzuna' ? 'Adzuna app key' : 'API key',
                helperText: guide?.keyHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _testing || _saving ? null : _runTest,
                icon: _testing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check, size: 18),
                label: const Text('Test key'),
              ),
            ]),
            if (_test != null) ...[
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_test!.ok ? Icons.check_circle : Icons.error_outline, size: 18, color: _test!.ok ? Colors.green : Colors.orange),
                const SizedBox(width: 6),
                Expanded(child: Text(_test!.message, style: theme.textTheme.bodySmall)),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_test?.ok == false ? 'Save anyway' : 'Save key')),
      ],
    );
  }
}


/// Country search, or add free text as a custom location.
class LocationPicker extends StatefulWidget {
  const LocationPicker({super.key, required this.existing});
  final List<String> existing;

  @override
  State<LocationPicker> createState() => LocationPickerState();
}

class LocationPickerState extends State<LocationPicker> {
  String _query = '';

  List<MapEntry<String, String>> get _matches {
    final q = _query.trim().toLowerCase();
    final all = countryNames.entries.where((e) => !widget.existing.contains(e.key));
    if (q.isEmpty) return all.toList();
    bool hit(MapEntry<String, String> e) =>
        e.value.toLowerCase().contains(q) || e.key == q || (countryAliases[e.key] ?? const []).any((a) => a.startsWith(q));
    final found = all.where(hit).toList()
      // prefix matches first
      ..sort((a, b) => (b.value.toLowerCase().startsWith(q) ? 1 : 0) - (a.value.toLowerCase().startsWith(q) ? 1 : 0));
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final typed = _query.trim();
    final matches = _matches;
    final exact = typed.isNotEmpty && countryNames.containsKey(normalizeLocation(typed));
    return AlertDialog(
      title: const Text('Add location'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 420,
        height: 440,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search a country, or type a city/region',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
            onSubmitted: (_) {
              if (matches.length == 1) {
                Navigator.pop(context, matches.first.key);
              } else if (typed.isNotEmpty) {
                Navigator.pop(context, normalizeLocation(typed));
              }
            },
          ),
          const SizedBox(height: 8),
          if (typed.isNotEmpty && !exact)
            ListTile(
              leading: const Icon(Icons.add_location_alt_outlined),
              title: Text('Add "$typed" as a custom location'),
              subtitle: const Text('Searched with Google; Adzuna and JSearch only support whole countries'),
              onTap: () => Navigator.pop(context, typed),
            ),
          Expanded(
            child: matches.isEmpty
                ? const Center(child: Text('No country matches'))
                : ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.flag_outlined),
                      title: Text(matches[i].value),
                      trailing: Text(matches[i].key.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
                      onTap: () => Navigator.pop(context, matches[i].key),
                    ),
                  ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}


/// Admin: shared key pool, including the GitHub secret keys (shown by their last 4 chars).
class _SharedKeys extends StatefulWidget {
  const _SharedKeys();

  @override
  State<_SharedKeys> createState() => _SharedKeysState();
}

class _SharedKeysState extends State<_SharedKeys> {
  late Future<List<Map<String, dynamic>>> _future = Api.sharedKeys();
  bool _busy = false;

  void _reload() => setState(() => _future = Api.sharedKeys());

  Future<void> _change(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      _reload();
    } catch (e) {
      if (mounted) toast(context, 'Could not update: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useFirst(Map<String, dynamic> k, List<Map<String, dynamic>> all) {
    final lowest = all
        .where((x) => x['provider'] == k['provider'])
        .map((x) => (x['priority'] as num).toInt())
        .fold<int>(1 << 30, (a, b) => a < b ? a : b);
    return _change(() => Api.updateSharedKey(k['id'] as String, {'priority': lowest - 1, 'enabled': true}));
  }

  @override
  Widget build(BuildContext context) => _Section(
        title: 'Shared keys (admin)',
        subtitle: 'Used for your runs and for users you allow to share them. Tried top to bottom; a key that hits '
            'its limit or is paused by the safety stop is skipped until it resets. GitHub-secret keys are shown by '
            'their last 4 characters.',
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return Text('Shared keys unavailable (${snap.error}). Run supabase/migrations/004_admin_tools.sql.');
            }
            if (!snap.hasData) return const LinearProgressIndicator();
            final keys = snap.data!;
            final theme = Theme.of(context);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_busy) const LinearProgressIndicator(),
              if (keys.isEmpty)
                Text('No shared keys yet. GitHub-secret keys appear here after the next agents run.',
                    style: theme.textTheme.bodySmall),
              for (final entry in providerInfo.entries)
                if (keys.any((k) => k['provider'] == entry.key)) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      Icon(entry.value.$3, size: 18),
                      const SizedBox(width: 6),
                      Text(entry.value.$1, style: theme.textTheme.labelLarge),
                    ]),
                  ),
                  for (final (i, k) in keys.where((k) => k['provider'] == entry.key).indexed)
                    _SharedKeyTile(
                      index: i + 1,
                      data: k,
                      onToggle: (v) => _change(() => Api.updateSharedKey(k['id'] as String, {'enabled': v})),
                      onUseFirst: i == 0 ? null : () => _useFirst(k, keys),
                      onDelete: k['source'] == 'app' ? () => _change(() => Api.deleteSharedKey(k['id'] as String)) : null,
                    ),
                ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: () async {
                    final added = await showDialog<bool>(
                      context: context,
                      builder: (_) => _AddKeyDialog(existing: keys, shared: true),
                    );
                    if (added == true) _reload();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add shared key'),
                ),
              ),
            ]);
          },
        ),
      );
}

class _SharedKeyTile extends StatelessWidget {
  const _SharedKeyTile({required this.index, required this.data, required this.onToggle, this.onUseFirst, this.onDelete});
  final int index;
  final Map<String, dynamic> data;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onUseFirst;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final enabled = data['enabled'] == true;
    final until = data['exhausted_until'] == null ? null : DateTime.parse(data['exhausted_until'] as String).toLocal();
    final paused = until != null && until.isAfter(DateTime.now());
    final used = data['last_used_at'] == null ? null : DateTime.parse(data['last_used_at'] as String).toLocal();
    final (color, status) = !enabled
        ? (Colors.grey, 'Turned off')
        : paused
            ? (Colors.orange, 'Paused until ${DateFormat.MMMd().add_jm().format(until)} · ${data['last_error'] ?? ''}')
            : data['last_error'] != null
                ? (Colors.red, '${data['last_error']}')
                : (Colors.green, used == null ? 'Not used yet' : 'Working · last used ${ago(used)}');
    final source = data['source'] == 'github' ? 'GitHub secret' : 'Added here';
    final label = (data['label'] as String?)?.isNotEmpty == true ? data['label'] as String : 'Key $index';
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 8),
      dense: true,
      leading: Switch(value: enabled, onChanged: onToggle),
      title: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('$index. $label  ${data['hint']}'),
        if (data['in_use'] == true && enabled)
          const Chip(
            label: Text('In use', style: TextStyle(fontSize: 11)),
            avatar: Icon(Icons.bolt, size: 14),
            visualDensity: VisualDensity.compact,
          ),
      ]),
      subtitle: Text('$source · $status', style: TextStyle(color: color), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'first' ? onUseFirst?.call() : onDelete?.call(),
        itemBuilder: (_) => [
          PopupMenuItem(value: 'first', enabled: onUseFirst != null, child: const Text('Use this key first')),
          PopupMenuItem(
            value: 'delete',
            enabled: onDelete != null,
            child: Text(onDelete != null ? 'Remove' : 'Remove (delete it in GitHub secrets)'),
          ),
        ],
      ),
    );
  }
}
