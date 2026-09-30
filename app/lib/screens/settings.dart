import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api.dart';
import '../widgets/common.dart';

const countryNames = {
  'us': 'United States', 'gb': 'United Kingdom', 'in': 'India', 'ca': 'Canada', 'au': 'Australia',
  'de': 'Germany', 'fr': 'France', 'nl': 'Netherlands', 'ie': 'Ireland', 'sg': 'Singapore',
  'ae': 'UAE', 'nz': 'New Zealand', 'es': 'Spain', 'it': 'Italy', 'ch': 'Switzerland', 'at': 'Austria',
  'be': 'Belgium', 'pl': 'Poland', 'se': 'Sweden', 'dk': 'Denmark', 'no': 'Norway', 'fi': 'Finland',
  'pt': 'Portugal', 'br': 'Brazil', 'mx': 'Mexico', 'za': 'South Africa', 'jp': 'Japan',
  'sa': 'Saudi Arabia', 'qa': 'Qatar', 'my': 'Malaysia', 'hk': 'Hong Kong',
};

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
                  const _ApiKeys(),
                  _Section(
                    title: 'Countries',
                    subtitle: 'Where the scouts look',
                    child: Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final c in _list('countries'))
                        InputChip(
                          label: Text(countryNames[c] ?? c.toUpperCase()),
                          onDeleted: () => _set('countries', _list('countries')..remove(c)),
                        ),
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: const Text('Add country'),
                        onPressed: () async {
                          final picked = await showDialog<String>(
                            context: context,
                            builder: (ctx) => SimpleDialog(title: const Text('Add country'), children: [
                              for (final e in countryNames.entries.where((e) => !_list('countries').contains(e.key)))
                                SimpleDialogOption(onPressed: () => Navigator.pop(ctx, e.key), child: Text(e.value)),
                            ]),
                          );
                          if (picked != null) _set('countries', [..._list('countries'), picked]);
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
                    subtitle: 'Greenhouse, Lever, Ashby and Workable links use their public APIs. '
                        'Any other link (LinkedIn, Indeed, Naukri, a careers page) is searched via Google.',
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

  static String kind(String url) {
    final u = url.toLowerCase();
    if (u.contains('greenhouse.io')) return 'Greenhouse API';
    if (u.contains('lever.co')) return 'Lever API';
    if (u.contains('ashbyhq.com')) return 'Ashby API';
    if (u.contains('workable.com')) return 'Workable API';
    return 'Google search';
  }

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
            subtitle: Text(kind('${b['url']}')),
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
            hintText: 'https://boards.greenhouse.io/company',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: _add),
          ),
        ),
      ]);
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

/// Upload / replace the parent resume and cover letter, and show what the Profile agent learned.
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
  'adzuna': ('Adzuna', 'developer.adzuna.com', Icons.travel_explore),
  'rapidapi': ('RapidAPI · JSearch', 'rapidapi.com (JSearch free plan)', Icons.hub_outlined),
};

/// The user's own API keys. Tried top to bottom; when one hits its limit the agents switch to the next.
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
                  '${shared ? 'After your own keys, the shared keys are used as a last fallback.' : 'Only your own keys are used — add at least one Gemini key.'}'
                  '  Limit: ${account?['llm_calls_per_run'] ?? '—'} Gemini calls per hourly run.',
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
                    child: Text(shared ? 'No own keys – using shared keys' : 'No keys', style: theme.textTheme.bodySmall),
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
  const _AddKeyDialog({required this.existing});
  final List<Map<String, dynamic>> existing;

  @override
  State<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends State<_AddKeyDialog> {
  String _provider = 'gemini';
  final _label = TextEditingController();
  final _appId = TextEditingController();
  final _key = TextEditingController();
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_key.text.trim().isEmpty || (_provider == 'adzuna' && _appId.text.trim().isEmpty)) {
      setState(() => _error = _provider == 'adzuna' ? 'Adzuna needs both the app id and the app key' : 'Paste the key');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    // New keys go to the end of the fallback order for that provider.
    final last = widget.existing
        .where((k) => k['provider'] == _provider)
        .fold<int>(-1, (m, k) => ((k['priority'] as int?) ?? 0) > m ? (k['priority'] as int? ?? 0) : m);
    try {
      await Api.addApiKey(
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
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add API key'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider', border: OutlineInputBorder()),
              items: [
                for (final e in providerInfo.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
              ],
              onChanged: (v) => setState(() => _provider = v ?? 'gemini'),
            ),
            const SizedBox(height: 4),
            Text('Get one at ${providerInfo[_provider]!.$2}', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label (optional)', hintText: 'e.g. Personal', border: OutlineInputBorder()),
            ),
            if (_provider == 'adzuna') ...[
              const SizedBox(height: 12),
              TextField(controller: _appId, decoration: const InputDecoration(labelText: 'Adzuna app id', border: OutlineInputBorder())),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: _provider == 'adzuna' ? 'Adzuna app key' : 'API key',
                border: const OutlineInputBorder(),
              ),
            ),
            if (_provider == 'gemini') ...[
              const SizedBox(height: 8),
              Text(
                'Free Gemini limits are per Google Cloud project, so extra keys from the same project don\'t add quota.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: _saving ? null : _save, child: const Text('Save key')),
        ],
      );
}
