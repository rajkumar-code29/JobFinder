import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../resume/cv.dart';
import '../resume/docx.dart';
import '../resume/pdf.dart';
import '../resume/preview.dart';
import '../resume/save.dart';
import '../widgets/common.dart';

/// Cover letter from the master resume or a CV built here, in UK formal letter layout.
class LetterBuilderScreen extends StatefulWidget {
  const LetterBuilderScreen({super.key, required this.draftId, this.testData});
  final String draftId;

  /// Tests pass the draft data; then nothing is loaded from or saved to the database.
  final Json? testData;

  @override
  State<LetterBuilderScreen> createState() => _LetterBuilderScreenState();
}

class _LetterBuilderScreenState extends State<LetterBuilderScreen> {
  Json? _data;
  Object? _error;
  bool _hasMaster = false;
  List<Map<String, dynamic>> _cvs = [];
  Timer? _saveTimer;
  bool _dirty = false;
  bool _busy = false;
  String _busyText = '';
  String? _usage;

  Json get d => _data!;
  Json get inputs => d['inputs'] as Json;
  Json get parts => d['parts'] as Json;
  String get source => s(d['source']);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty && _data != null) _save();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final offline = widget.testData != null;
      final row = offline ? {'data': widget.testData} : await Api.draft(widget.draftId);
      if (row == null) throw 'This draft was deleted';
      final data = obj(row['data']);
      data['inputs'] = obj(data['inputs']);
      data['parts'] = obj(data['parts']);
      final master = offline ? data['test_master'] == true : await Api.hasMasterResume();
      final cvs = offline
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await supa
              .from('resume_drafts')
              .select('id,title,data')
              .eq('kind', 'cv')
              .order('updated_at', ascending: false));
      final usable = cvs.where((c) => _cvDoc(c) != null).toList();
      if (s(data['source']).isEmpty) {
        data['source'] = master ? 'master' : (usable.isEmpty ? '' : 'cv:${usable.first['id']}');
      }
      final inp = data['inputs'] as Json;
      if (!offline && s(inp['your_name']).isEmpty) {
        try {
          final name = s(obj((await Api.profile())['structured'])['name']);
          if (name.isNotEmpty && name != 'NA') inp['your_name'] = name;
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _data = data;
          _hasMaster = master;
          _cvs = usable;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  static CvDoc? _cvDoc(Map<String, dynamic> row) {
    final data = obj(row['data']);
    final answers = normaliseAnswers(obj(data['answers']));
    final type = s(data['cv_type']).isEmpty ? targetById(s(data['target'])).defaultType : s(data['cv_type']);
    final doc = buildDoc(
        answers: answers, type: type, sections: obj(data['sections']), ai: s(data['mode']) != 'own', role: s(data['role']));
    return doc.sections.length > 1 ? doc : null;
  }

  String get _title {
    final job = s(inputs['job_title']), org = s(inputs['company']);
    if (job.isEmpty && org.isEmpty) return 'Untitled cover letter';
    return 'Cover letter${job.isEmpty ? '' : ' – $job'}${org.isEmpty ? '' : ' at $org'}';
  }

  void _changed([VoidCallback? fn]) {
    setState(() => fn?.call());
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), _save);
  }

  Future<void> _save() async {
    _saveTimer?.cancel();
    if (!_dirty || widget.testData != null) return;
    _dirty = false;
    try {
      await Api.saveDraft(widget.draftId, _title, d);
    } catch (e) {
      _dirty = true;
      if (mounted) toast(context, 'Could not save the draft: $e');
    }
  }

  Future<T?> _run<T>(String text, Future<T> Function() task) async {
    setState(() {
      _busy = true;
      _busyText = text;
    });
    try {
      return await task();
    } on BuilderException catch (e) {
      if (e.code == 'no_resume' && mounted) setState(() => _hasMaster = false);
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  Future<void> _uploadResume() async {
    final picked = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['docx', 'pdf'], dialogTitle: 'Choose your resume (.docx or .pdf)');
    if (picked.isEmpty) return;
    await _run('Uploading…', () async {
      final files = <(String, Uint8List)>[for (final f in picked) (f.name, await f.readAsBytes())];
      await Api.replaceParent('resume', files);
      if (mounted) {
        _changed(() {
          _hasMaster = true;
          d['source'] = 'master';
        });
        toast(context, 'Uploaded. It is also your master resume now.');
      }
    });
  }

  Future<void> _buildCvInstead() async {
    final id = await _run('Starting a CV…', () => Api.createDraft('cv', 'Untitled CV', {'mode': 'ai'}));
    if (id != null && mounted) context.go('/resume-builder/cv/$id');
  }

  String? get _resumeText {
    if (!source.startsWith('cv:')) return null;
    final row = _cvs.where((c) => 'cv:${c['id']}' == source).firstOrNull;
    return row == null ? null : _cvDoc(row)?.text;
  }

  Future<void> _write({List<String> only = letterParts, String note = ''}) async {
    if (s(inputs['job_title']).isEmpty || s(inputs['company']).isEmpty) {
      toast(context, 'Add the job title and the organisation first');
      return;
    }
    final redo = only.length < letterParts.length;
    final res = await _run(redo ? 'Rewriting…' : 'Writing your letter… this takes 10 to 30 seconds', () {
      final body = <String, dynamic>{
        'action': 'letter',
        'inputs': {
          ...inputs,
          if (redo) 'rest': [for (final p in letterParts) if (!only.contains(p)) s(parts[p])].join('\n\n'),
        },
        'parts': only,
        if (redo) 'current': {for (final p in only) p: s(parts[p])},
        if (redo) 'notes': {for (final p in only) p: note},
      };
      final text = _resumeText;
      if (text != null) body['resume_text'] = text;
      return Api.resumeAi(body);
    });
    if (res == null || !mounted) return;
    final got = obj(res['parts']);
    _changed(() {
      for (final p in only) {
        if (s(got[p]).isNotEmpty) parts[p] = s(got[p]);
      }
      if (res['used_today'] != null) _usage = '${res['used_today']} of ${res['daily_limit']} AI requests used today';
    });
  }

  Future<void> _regenerate(String part) async {
    final note = await showDialog<String>(context: context, builder: (_) => const _NoteDialog());
    if (note != null) await _write(only: [part], note: note);
  }

  Future<void> _edit(String part) async {
    final c = TextEditingController(text: s(parts[part]));
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(letterPartLabels[part] ?? 'Edit'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: c,
            minLines: 5,
            maxLines: 14,
            decoration: const InputDecoration(border: OutlineInputBorder(), helperText: 'Blank line between paragraphs'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Done')),
        ],
      ),
    );
    if (text != null) _changed(() => parts[part] = text);
  }

  LetterDoc get _letter => buildLetter(inputs, parts, today: DateTime.now());

  Future<void> _saveFiles({required bool word, required bool pdf}) async {
    final l = _letter;
    final stem = fileStem(l.name, 'Cover Letter');
    if (word) await saveBytes(context, '$stem.docx', letterDocx(l), docxMime);
    if (pdf && mounted) {
      try {
        final bytes = await letterPdf(l);
        if (mounted) await saveBytes(context, '$stem.pdf', bytes, pdfMime);
      } catch (e) {
        if (mounted) toast(context, 'Could not make the PDF: $e');
      }
    }
  }

  Future<void> _setMaster() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use this as your master cover letter?'),
        content: const Text('It replaces the cover letter in Settings > Parent documents. The Writer agent uses it as '
            'background when it writes letters for the jobs it finds.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace it')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final l = _letter;
    await _run('Uploading…', () async {
      await Api.replaceParent('cover_letter', [('${fileStem(l.name, 'Cover Letter')}.docx', letterDocx(l))]);
      if (mounted) toast(context, 'This is now your master cover letter');
    });
  }

  Widget _text(String key, String label, {String? hint, String? helper, int lines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: ValueKey('letter-$key'),
          initialValue: s(inputs[key]),
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 8,
          decoration: InputDecoration(
              labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3, border: const OutlineInputBorder()),
          onChanged: (v) => _changed(() => inputs[key] = v),
        ),
      );

  Widget _card(String title, List<Widget> children, {String? subtitle}) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Scaffold(appBar: AppBar(title: const Text('Cover letter')), body: ErrorView(_error!));
    if (_data == null) {
      return Scaffold(appBar: AppBar(title: const Text('Cover letter')), body: const Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    final noResume = !_hasMaster && _cvs.isEmpty;
    final hasLetter = letterParts.any((p) => s(parts[p]).isNotEmpty);
    final sources = [
      if (_hasMaster) const DropdownMenuItem(value: 'master', child: Text('My master resume')),
      for (final c in _cvs) DropdownMenuItem(value: 'cv:${c['id']}', child: Text('CV built here: ${s(c['title'])}')),
    ];
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () async {
          await _save();
          if (context.mounted) context.go('/resume-builder');
        }),
        title: Text(_title),
      ),
      body: Column(children: [
        if (_busy) ...[
          const LinearProgressIndicator(),
          Padding(padding: const EdgeInsets.all(6), child: Text(_busyText, style: theme.textTheme.bodySmall)),
        ],
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
            PageBody(
              maxWidth: 860,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  'A one-page letter in UK business format: why you are writing, why this job and organisation, '
                  'your evidence, and a confident close. Write one for each job; a reused letter is easy to spot.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 14),
                if (noResume)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    margin: const EdgeInsets.only(bottom: 14),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text('Upload your resume first', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        const Text('The letter is built from your resume, so it can only use real evidence. Upload '
                            'it (it becomes your master resume), or build a CV here first.'),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          FilledButton.icon(
                              onPressed: _busy ? null : _uploadResume,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('Upload my resume')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _buildCvInstead,
                              icon: const Icon(Icons.post_add),
                              label: const Text('Build a CV first')),
                        ]),
                      ]),
                    ),
                  )
                else
                  _card('Your resume', [
                    DropdownButtonFormField<String>(
                      initialValue: sources.any((x) => x.value == source) ? source : sources.first.value,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Build the letter from', border: OutlineInputBorder()),
                      items: sources,
                      onChanged: (v) => _changed(() => d['source'] = v),
                    ),
                  ]),
                _card('The job', [
                  _text('job_title', 'Job title', hint: 'Graduate Network Engineer'),
                  _text('company', 'Organisation', hint: 'ACME International'),
                  _text('source', 'Where you found it (optional)', hint: 'LinkedIn, the company website, a careers fair'),
                  _text('job_ad', 'Job advert (optional)',
                      lines: 4, helper: 'Leave it empty for a speculative letter asking about opportunities.'),
                  _text('why', 'Why you want this job and organisation',
                      lines: 3,
                      hint: 'A project of theirs you liked, their values, what the role would teach you',
                      helper: 'Your own reasons make the letter sound like you. The AI won\'t invent facts about '
                          'the organisation.'),
                ]),
                _card('Who it is going to', subtitle: 'A named person is best. With a name the letter ends "Yours '
                    'sincerely"; without one it opens "Dear Hiring Manager" and ends "Yours faithfully".', [
                  _text('recipient_name', 'Their name (optional)', hint: 'Ms Smith'),
                  _text('recipient_title', 'Their job title (optional)', hint: 'Head of Human Resources'),
                  _text('company_address', 'Organisation address (optional)', lines: 2, hint: '10 Glasgow Street, Glasgow, G1 1AA'),
                ]),
                _card('You', [
                  _text('your_name', 'Your name'),
                  _text('your_address', 'Your address (optional)',
                      lines: 2, hint: '1 Glasgow Road, Glasgow, G1 1GG', helper: 'Goes in the top right corner.'),
                ]),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  FilledButton.icon(
                    onPressed: _busy || noResume ? null : () => _write(),
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(hasLetter ? 'Rewrite the whole letter' : 'Write my cover letter'),
                  ),
                  if (_usage != null) Text(_usage!, style: theme.textTheme.bodySmall),
                ]),
                if (hasLetter) ...[
                  const SizedBox(height: 18),
                  Text('Your letter', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text('Regenerate or edit any part. Keep it to one page.', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 12),
                  LetterPaper(
                    letter: _letter,
                    parts: {for (final p in letterParts) p: s(parts[p])},
                    actions: _partActions,
                  ),
                  const SizedBox(height: 18),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(
                        onPressed: _busy ? null : () => _saveFiles(word: true, pdf: false),
                        icon: const Icon(Icons.description_outlined),
                        label: const Text('Word (.docx)')),
                    FilledButton.tonalIcon(
                        onPressed: _busy ? null : () => _saveFiles(word: false, pdf: true),
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('PDF')),
                    OutlinedButton.icon(
                        onPressed: _busy ? null : () => _saveFiles(word: true, pdf: true),
                        icon: const Icon(Icons.download),
                        label: const Text('Both')),
                    TextButton.icon(
                        onPressed: _busy ? null : _setMaster,
                        icon: const Icon(Icons.star_outline),
                        label: const Text('Set as my master cover letter')),
                  ]),
                ],
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _partActions(String part) {
    final style = TextButton.styleFrom(foregroundColor: const Color(0xFF3F51B5), visualDensity: VisualDensity.compact);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: const Color(0xFFF1F3F9), borderRadius: BorderRadius.circular(8)),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(letterPartLabels[part] ?? part, style: const TextStyle(fontSize: 12, color: Color(0xFF555555))),
        ),
        TextButton.icon(
            style: style,
            onPressed: _busy ? null : () => _regenerate(part),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Regenerate')),
        TextButton.icon(
            style: style,
            onPressed: _busy ? null : () => _edit(part),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit')),
      ]),
    );
  }
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog();

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  static const _quick = ['Shorter', 'Warmer', 'More confident', 'More specific', 'Simpler words'];
  final _picked = <String>{};
  final _note = TextEditingController();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Regenerate this part'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final q in _quick)
                FilterChip(
                  label: Text(q),
                  selected: _picked.contains(q),
                  onSelected: (v) => setState(() => v ? _picked.add(q) : _picked.remove(q)),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Anything specific (optional)', border: OutlineInputBorder()),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, [..._picked, _note.text.trim()].where((x) => x.isNotEmpty).join('. ')),
            child: const Text('Regenerate'),
          ),
        ],
      );
}
