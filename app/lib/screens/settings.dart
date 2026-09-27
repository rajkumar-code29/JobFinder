import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
      final s = Map<String, dynamic>.from(_s!)..remove('id')..remove('updated_at');
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
                  const SizedBox(height: 16),
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
