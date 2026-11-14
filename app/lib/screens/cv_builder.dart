import 'dart:async';
import 'dart:convert';
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

/// Step-by-step CV builder: questions, then a review where each section can be regenerated or edited, then
/// downloads. Everything is saved to a draft as you go.
class CvBuilderScreen extends StatefulWidget {
  const CvBuilderScreen({super.key, required this.draftId, this.testData});
  final String draftId;

  /// Tests pass the draft data; then nothing is loaded from or saved to the database.
  final Json? testData;

  @override
  State<CvBuilderScreen> createState() => _CvBuilderScreenState();
}

const _steps = ['Start', 'Contact', 'About you', 'Education', 'Experience', 'Skills', 'Projects', 'More', 'Review', 'Download'];
const _review = 8, _download = 9;

const _modes = {
  'ai': ('Build with AI', Icons.auto_awesome_outlined),
  'own': ('My own words', Icons.edit_note),
  'existing': ('From my resume', Icons.upload_file_outlined),
};

class _CvBuilderScreenState extends State<CvBuilderScreen> {
  Json? _data;
  Object? _error;
  Timer? _saveTimer;
  bool _dirty = false;
  bool _busy = false;
  String _busyText = '';
  bool _autoTried = false;
  int _rev = 0; // bumps when answers are replaced, so the fields pick up the new values
  String? _usage;
  bool _hasMaster = false;

  Json get d => _data!;
  String get mode => s(d['mode']).isEmpty ? 'ai' : s(d['mode']);
  bool get ai => mode != 'own';
  String get target => s(d['target']);
  String get cvType => s(d['cv_type']).isEmpty ? targetById(target).defaultType : s(d['cv_type']);
  String get role => s(d['role']);
  Json get answers => d['answers'] as Json;
  Json get sections => d['sections'] as Json;
  List<String> get own => (d['own'] as List).cast<String>();
  int get step => (d['step'] as int?) ?? 0;

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
      data['answers'] = normaliseAnswers(obj(data['answers']));
      data['sections'] = obj(data['sections']);
      data['own'] = List<String>.from((data['own'] as List?) ?? []);
      final contact = obj(obj(data['answers'])['contact']);
      if (!offline && s(contact['name']).isEmpty && s(data['mode']) != 'existing') {
        // start from what the agents already know about this person
        try {
          final structured = obj((await Api.profile())['structured']);
          final links = (structured['links'] as List?)?.map(s).toList() ?? [];
          for (final (k, v) in [
            ('name', s(structured['name'])),
            ('email', s(structured['email']).isEmpty ? (supa.auth.currentUser?.email ?? '') : s(structured['email'])),
            ('phone', s(structured['phone'])),
            ('location', s(structured['location'])),
            ('linkedin', links.firstWhere((l) => l.contains('linkedin'), orElse: () => '')),
          ]) {
            if (v.isNotEmpty && v != 'NA') contact[k] = v;
          }
        } catch (_) {}
        (data['answers'] as Json)['contact'] = contact;
      }
      bool master = false;
      try {
        if (!offline) master = await Api.hasMasterResume();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _data = data;
          _hasMaster = master;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _setType(String? type) {
    d['cv_type'] = type;
    d['type_chosen'] = true;
  }

  String get _title {
    if (target.isEmpty) return 'Untitled CV';
    return role.isEmpty ? '${targetById(target).label} CV' : '$role CV';
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

  void _go(int to) {
    if (to >= _review && target.isEmpty) {
      toast(context, 'Pick what the CV is for first');
      to = 0;
    }
    if (to == _review) _autoTried = false;
    _changed(() => d['step'] = to.clamp(0, _download));
    _save();
  }

  Future<T?> _run<T>(String text, Future<T> Function() task) async {
    setState(() {
      _busy = true;
      _busyText = text;
    });
    try {
      return await task();
    } on BuilderException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  // AI

  Future<void> _readResume({bool upload = false}) async {
    Map<String, dynamic> body = {'action': 'parse', 'role': role};
    if (upload) {
      final picked = await FilePicker.pickFiles(
          type: FileType.custom, allowedExtensions: ['docx', 'pdf'], dialogTitle: 'Choose your resume (.docx or .pdf)');
      if (picked.isEmpty) return;
      final f = picked.first;
      body = {...body, 'filename': f.name, 'file_b64': base64Encode(await f.readAsBytes())};
    }
    final res = await _run('Reading your resume…', () => Api.resumeAi(body));
    if (res == null || !mounted) return;
    final parsed = obj(res['answers']);
    _changed(() {
      d['answers'] = normaliseAnswers(parsed);
      d['sections'] = <String, dynamic>{};
      d['own'] = <String>[];
      d['read_from'] = s(res['source']);
      d['step'] = 1;
      _rev++;
      _usageFrom(res);
    });
    toast(context, 'Read ${s(res['source'])}. Check each step, then go to Review.');
  }

  void _usageFrom(Map<String, dynamic> res) {
    if (res['used_today'] != null) _usage = '${res['used_today']} of ${res['daily_limit']} AI requests used today';
  }

  Future<void> _write(List<SectionSpec> specs, {Map<String, String> notes = const {}, Json current = const {}}) async {
    if (specs.isEmpty) return;
    final res = await _run(
      current.isEmpty ? 'Writing your CV… this takes 10 to 40 seconds' : 'Rewriting…',
      () => Api.resumeAi({
        'action': 'cv',
        'target': target,
        'cv_type': cvType,
        'role': role,
        'job_ad': s(d['job_ad']),
        'answers': answers,
        'sections': [for (final spec in specs) {'key': spec.key, 'guide': spec.guide}],
        'notes': notes,
        'current': current,
      }),
    );
    if (res == null || !mounted) return;
    final got = obj(res['sections']);
    _changed(() {
      for (final spec in specs) {
        final sec = obj(got[spec.key]);
        if (!CvSection.fromJson(spec.key, spec.heading, sec).isEmpty) {
          sections[spec.key] = sec;
          own.remove(spec.key);
        }
      }
      _usageFrom(res);
    });
  }

  List<SectionSpec> get _specs => sectionsToBuild(cvType, answers, ai: ai, role: role);
  List<SectionSpec> get _missing =>
      ai ? _specs.where((sp) => sp.key != 'references' && !sections.containsKey(sp.key) && !own.contains(sp.key)).toList() : [];

  CvDoc get _doc => buildDoc(answers: answers, type: cvType, sections: sections, ai: ai, role: role);

  Future<void> _regenerate(CvSection sec) async {
    final note = await showDialog<String>(context: context, builder: (_) => const _RegenerateDialog());
    if (note == null) return;
    final spec = _specs.firstWhere((sp) => sp.key == sec.key);
    await _write([spec], notes: {sec.key: note}, current: {sec.key: sec.toJson()});
  }

  Future<void> _edit(CvSection sec) async {
    final edited = await editSection(context, sec);
    if (edited == null) return;
    _changed(() {
      sections[sec.key] = edited.toJson();
      own.remove(sec.key);
    });
  }

  // files

  Future<(Uint8List, int)?> _pdf(CvDoc doc) async {
    try {
      return await cvPdf(doc);
    } catch (e) {
      if (mounted) toast(context, 'Could not make the PDF: $e');
      return null;
    }
  }

  String? _pdfFor;
  Future<(Uint8List, int)?>? _pdfFuture;

  /// The PDF for the download step, made again only when the CV changes.
  Future<(Uint8List, int)?> _currentPdf(CvDoc doc) {
    final text = '${doc.type}\n${doc.text}';
    if (_pdfFor != text || _pdfFuture == null) {
      _pdfFor = text;
      _pdfFuture = _pdf(doc);
    }
    return _pdfFuture!;
  }

  Future<void> _saveFiles(CvDoc doc, {required bool word, required bool pdf}) async {
    final stem = fileStem(doc.name, 'CV');
    if (word) await saveBytes(context, '$stem.docx', cvDocx(doc), docxMime);
    if (!mounted) return;
    if (pdf) {
      final made = await _currentPdf(doc);
      if (made != null && mounted) await saveBytes(context, '$stem.pdf', made.$1, pdfMime);
    }
  }

  Future<void> _setMaster(CvDoc doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use this as your master resume?'),
        content: const Text('It replaces the resume in Settings > Parent documents (the Word file and a PDF). '
            'The agents tailor every new job from your master resume and re-read it on their next run.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace it')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final stem = fileStem(doc.name, 'CV');
    await _run('Uploading…', () async {
      final made = await cvPdf(doc);
      await Api.replaceParent('resume', [('$stem.docx', cvDocx(doc)), ('$stem.pdf', made.$1)]);
      if (mounted) {
        setState(() => _hasMaster = true);
        toast(context, 'This is now your master resume');
      }
    });
  }

  Future<void> _letterFromThis(CvDoc doc) async {
    await _save();
    final id = await _run('Starting a cover letter…', () => Api.createDraft('letter', 'Untitled cover letter', {
          'source': 'cv:${widget.draftId}',
          'inputs': {'your_name': doc.name, 'job_title': role},
        }));
    if (id != null && mounted) context.go('/resume-builder/letter/$id');
  }

  // UI

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(appBar: AppBar(title: const Text('Build a CV')), body: ErrorView(_error!));
    }
    if (_data == null) {
      return Scaffold(appBar: AppBar(title: const Text('Build a CV')), body: const Center(child: CircularProgressIndicator()));
    }
    if (step == _review && _missing.isNotEmpty && !_busy && !_autoTried) {
      _autoTried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _write(_missing));
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () async {
          await _save();
          if (context.mounted) context.go('/resume-builder');
        }),
        title: Text(_title),
      ),
      body: Column(children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            for (final (i, name) in _steps.indexed)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('${i + 1}. $name'),
                  selected: step == i,
                  onSelected: _busy ? null : (_) => _go(i),
                ),
              ),
          ]),
        ),
        LinearProgressIndicator(value: (step + 1) / _steps.length, minHeight: 2),
        if (_busy) ...[
          const LinearProgressIndicator(),
          Padding(padding: const EdgeInsets.all(6), child: Text(_busyText, style: theme.textTheme.bodySmall)),
        ],
        Expanded(
          child: ListView(
            key: ValueKey('step-$step-$_rev'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [PageBody(maxWidth: 860, child: _stepBody(context))],
          ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
          child: PageBody(
            maxWidth: 860,
            child: Row(children: [
              if (step > 0) OutlinedButton.icon(onPressed: _busy ? null : () => _go(step - 1), icon: const Icon(Icons.arrow_back), label: const Text('Back')),
              const Spacer(),
              if (step < _download)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _go(step + 1),
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(step == _review - 1 ? 'Review' : step == _review ? 'Download' : 'Next'),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _stepBody(BuildContext context) => switch (step) {
        0 => _start(context),
        1 => _contactStep(),
        2 => _aboutStep(),
        3 => _items('education', 'Your education', _eduFields,
            'Newest first. Include your degree, and your school or college qualifications with grades.', 'Add a qualification'),
        4 => _experienceStep(),
        5 => _skillsStep(),
        6 => _items('projects', 'Projects', _projectFields,
            'Optional. University, group or personal projects that show skills the job needs.', 'Add a project'),
        7 => _moreStep(),
        _review => _reviewStep(context),
        _ => _downloadStep(context),
      };

  // steps

  Widget _question(String title, String help) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(help, style: Theme.of(context).textTheme.bodyMedium),
        ]),
      );

  Widget _text(Json map, String key, String label, {String? hint, int lines = 1, String? helper, String path = ''}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: ValueKey('$_rev-$path.$key'),
          initialValue: s(map[key]),
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 8,
          keyboardType: lines > 1 ? TextInputType.multiline : null,
          decoration: InputDecoration(
              labelText: label, hintText: hint, helperText: helper, helperMaxLines: 3, border: const OutlineInputBorder()),
          onChanged: (v) => _changed(() => map[key] = v),
        ),
      );

  Widget _start(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _question('How do you want to build it?', 'You can switch at any time; your answers stay.'),
      SegmentedButton<String>(
        segments: [
          for (final e in _modes.entries) ButtonSegment(value: e.key, label: Text(e.value.$1), icon: Icon(e.value.$2)),
        ],
        selected: {mode},
        onSelectionChanged: (v) => _changed(() => d['mode'] = v.first),
      ),
      const SizedBox(height: 6),
      Text(
        switch (mode) {
          'own' => 'Answer the questions and your words go into the CV exactly as you type them. Only the layout is done for you.',
          'existing' => 'Pounce reads your current resume and fills in the answers. Check them, then the AI rewrites each section.',
          _ => 'Answer the questions in your own words, rough notes are fine. The AI turns them into clear, natural CV wording you can review section by section.',
        },
        style: theme.textTheme.bodySmall,
      ),
      if (mode == 'existing') ...[
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Your resume', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(s(d['read_from']).isEmpty ? 'Not read yet.' : 'Read from ${s(d['read_from'])}. Reading again replaces your answers.',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (_hasMaster)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _readResume(),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Read my master resume'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _readResume(upload: true),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload a .docx or .pdf'),
                ),
              ]),
            ]),
          ),
        ),
      ],
      const SizedBox(height: 20),
      _question('What is this CV for?', 'This decides the layout, the order of sections and how much detail goes in.'),
      for (final t in cvTargets)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: target == t.id ? theme.colorScheme.primary : theme.dividerColor, width: target == t.id ? 2 : 1),
          ),
          child: ListTile(
            leading: Icon(target == t.id ? Icons.radio_button_checked : Icons.radio_button_off,
                color: target == t.id ? theme.colorScheme.primary : null),
            title: Text(t.label),
            subtitle: Text(t.description),
            onTap: () => _changed(() {
              d['target'] = t.id;
              if (d['type_chosen'] != true) d['cv_type'] = t.defaultType;
            }),
          ),
        ),
      const SizedBox(height: 12),
      _text(d, 'role', 'Role you are applying for', hint: 'Retail assistant, Marketing intern, Graduate data analyst'),
      if (ai)
        _text(d, 'job_ad', 'Job advert (optional)',
            lines: 4,
            helper: 'Paste the advert and the AI uses its wording wherever your experience backs it up, which helps with '
                'applicant tracking systems.'),
      const SizedBox(height: 4),
      DropdownButtonFormField<String>(
        initialValue: cvType,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'CV format', border: OutlineInputBorder()),
        items: [for (final e in cvTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1))],
        onChanged: (v) => _changed(() => _setType(v)),
      ),
      const SizedBox(height: 6),
      Text(cvTypes[cvType]!.$2, style: theme.textTheme.bodySmall),
    ]);
  }

  Widget _contactStep() {
    final contact = answers['contact'] as Json;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _question('How can employers reach you?',
          'Name, phone and email are essential. Leave out your date of birth, photo and full address; a town is enough.'),
      _text(contact, 'name', 'Full name', path: 'contact'),
      _text(contact, 'email', 'Email', path: 'contact', hint: 'A professional-looking address'),
      _text(contact, 'phone', 'Phone', path: 'contact'),
      _text(contact, 'location', 'Town or city', hint: 'Glasgow, UK', path: 'contact'),
      _text(contact, 'linkedin', 'LinkedIn (optional)', path: 'contact', hint: 'linkedin.com/in/your-name'),
      _text(contact, 'website', 'Portfolio or website (optional)', path: 'contact'),
      if (target == 'part_time' || cvType == 'part_time')
        _text(contact, 'availability', 'When you can work', hint: 'Evenings and weekends, up to 15 hours a week', path: 'contact'),
    ]);
  }

  Widget _aboutStep() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _question(
          'Tell us about yourself',
          ai
              ? 'What you study or do now, what you are looking for and what makes you different. Rough notes are fine; '
                  'the AI writes the profile from this and the rest of your answers.'
              : 'This becomes your profile paragraph exactly as you write it. Keep it to about four lines, and skip '
                  'phrases like "hard-working and reliable": say what you have done instead.',
        ),
        _text(answers, 'about', ai ? 'About you' : 'Profile',
            lines: 5,
            hint: ai
                ? 'Second-year law student, want a summer internship at a commercial firm, mooting, class rep, Subway job'
                : null),
      ]);

  Widget _experienceStep() => _items(
        'experience',
        'Your experience',
        _expFields,
        'Jobs, internships, placements and volunteering, newest first. Mark which ones relate to this role. If you have '
            'never had a job, use volunteering, clubs, positions of responsibility or projects.',
        'Add experience',
        kind: true,
      );

  Widget _skillsStep() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _question('Your skills',
            'Skills mean more with evidence. Look at what the job asks for and give an example for each skill you have.'),
        _text(answers['skills'] as Json, 'soft', path: 'skills', 'Skills, with an example each',
            lines: 5,
            hint: 'One per line, skill then example:\nTeamwork: run the Saturday rota at the café\nCommunication: class rep at staff meetings',
            helper: cvType == 'skills' ? 'This is a skills-based CV, so these become its main section.' : null),
        _text(answers['skills'] as Json, 'technical', path: 'skills', 'Technical skills', hint: 'Python, SQL, AutoCAD, HPLC, Adobe Photoshop'),
        _text(answers['skills'] as Json, 'it', path: 'skills', 'IT skills', hint: 'Microsoft Excel, Word, PowerPoint, Canva'),
      ]);

  Widget _moreStep() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _question('Anything else?', 'All optional. One item per line.'),
        _text(answers, 'achievements', 'Achievements and positions of responsibility',
            lines: 2, hint: "Dean's List 2024\nSchool prefect\nBronze Duke of Edinburgh Award"),
        _text(answers, 'certifications', 'Certifications and courses', lines: 2, hint: 'Google Digital Garage (2024)'),
        _text(answers, 'languages', 'Languages', lines: 2, hint: 'English – native\nSpanish – intermediate (B1)'),
        _text(answers, 'interests', 'Interests',
            lines: 2, hint: 'Say what each one involves: captain of the university hockey team'),
        _text(answers, 'additional', 'Additional information',
            lines: 2, hint: 'Full UK driving licence\nVisa status\nFirst aid certificate'),
      ]);

  Widget _items(String key, String title, List<(String, String, String?, int)> fields, String help, String addLabel,
      {bool kind = false}) {
    final items = (answers[key] as List).cast<Json>();
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _question(title, help),
      for (final (i, item) in items.indexed)
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Text(
                    [s(item[fields.first.$1]), s(item[fields[1].$1])].where((x) => x.isNotEmpty).join(', ').ifEmpty('${i + 1}'),
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: i == 0
                      ? null
                      : () => _changed(() {
                            final above = items[i - 1];
                            items[i - 1] = items[i];
                            items[i] = above;
                            _rev++;
                          }),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                  onPressed: () => _changed(() {
                    items.removeAt(i);
                    _rev++;
                  }),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (kind)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: const ['relevant', 'other', 'volunteering'].contains(s(item['kind'])) ? s(item['kind']) : 'other',
                        decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(value: 'relevant', child: Text('Relevant to this role')),
                          DropdownMenuItem(value: 'other', child: Text('Other work')),
                          DropdownMenuItem(value: 'volunteering', child: Text('Volunteering or unpaid')),
                        ],
                        onChanged: (v) => _changed(() => item['kind'] = v),
                      ),
                    ),
                  for (final (f, label, hint, lines) in fields) _text(item, f, label, hint: hint, lines: lines, path: '$key.$i'),
                ]),
              ),
            ]),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => _changed(() {
            items.add(kind ? {'kind': 'relevant'} : <String, dynamic>{});
            _rev++;
          }),
          icon: const Icon(Icons.add),
          label: Text(addLabel),
        ),
      ),
    ]);
  }

  Widget _reviewStep(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _doc;
    final missing = _missing;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _question(
        'Review your CV',
        ai
            ? 'Each section is rewritten from your answers. Regenerate any section you want worded differently, edit it '
                'yourself, or go back to your own words. Nothing is made up: if something is missing, add it to your answers.'
            : 'This is your CV with your own words. Edit any section here, or change your answers in the earlier steps.',
      ),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 240,
          child: DropdownButtonFormField<String>(
            initialValue: cvType,
            isDense: true,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'CV format', border: OutlineInputBorder(), isDense: true),
            items: [for (final e in cvTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1))],
            onChanged: (v) => _changed(() => _setType(v)),
          ),
        ),
        if (ai && missing.isNotEmpty)
          FilledButton.icon(
            onPressed: _busy ? null : () => _write(missing),
            icon: const Icon(Icons.auto_awesome),
            label: Text(sections.isEmpty ? 'Write my CV' : 'Write ${missing.length} more section${missing.length == 1 ? '' : 's'}'),
          ),
        if (ai && sections.isNotEmpty)
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Rewrite everything?'),
                        content: const Text('Every section is written again from your answers. Your edits are replaced.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rewrite')),
                        ],
                      ),
                    );
                    if (ok == true) await _write(_specs.where((sp) => sp.key != 'references').toList());
                  },
            icon: const Icon(Icons.refresh),
            label: const Text('Rewrite everything'),
          ),
      ]),
      if (_usage != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_usage!, style: theme.textTheme.bodySmall)),
      const SizedBox(height: 14),
      if (doc.sections.length <= 1)
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Nothing to show yet'),
            subtitle: Text('Fill in a few of the earlier steps first.'),
          ),
        )
      else
        CvPaper(doc: doc, actions: _sectionActions),
    ]);
  }

  Widget _sectionActions(CvSection sec) {
    if (sec.key == 'references') return const SizedBox.shrink();
    final style = TextButton.styleFrom(foregroundColor: const Color(0xFF3F51B5), visualDensity: VisualDensity.compact);
    final edited = sections.containsKey(sec.key);
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      decoration: BoxDecoration(color: const Color(0xFFF1F3F9), borderRadius: BorderRadius.circular(8)),
      child: Wrap(children: [
        if (ai)
          TextButton.icon(
              style: style, onPressed: _busy ? null : () => _regenerate(sec), icon: const Icon(Icons.refresh, size: 18), label: const Text('Regenerate')),
        TextButton.icon(
            style: style, onPressed: _busy ? null : () => _edit(sec), icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Edit')),
        if (edited)
          TextButton.icon(
            style: style,
            onPressed: _busy
                ? null
                : () => _changed(() {
                      sections.remove(sec.key);
                      if (ai) own.add(sec.key);
                    }),
            icon: const Icon(Icons.undo, size: 18),
            label: Text(ai ? 'Use my words' : 'Undo my edits'),
          ),
      ]),
    );
  }

  Widget _downloadStep(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _doc;
    final problems = [
      if (doc.name.isEmpty) 'Add your name in step 2 (Contact).',
      if (!doc.contact.any((c) => c.contains('@'))) 'Add your email address in step 2 (Contact).',
    ];
    final unpolished = ai ? _missing.length : 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _question('Download your CV',
          'Word (.docx) is safest for online applications because tracking systems read it reliably; send a PDF when you email it.'),
      for (final p in problems)
        Card(color: theme.colorScheme.errorContainer, child: ListTile(leading: const Icon(Icons.warning_amber), title: Text(p))),
      if (unpolished > 0)
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text('$unpolished section${unpolished == 1 ? ' is' : 's are'} still in your own words'),
            subtitle: const Text('That is fine. Use "Write more sections" in Review if you want them polished.'),
          ),
        ),
      FutureBuilder<(Uint8List, int)?>(
        future: _currentPdf(doc),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
          }
          final pages = snap.data!.$2;
          final onePage = isOnePage(cvType);
          final tooLong = onePage ? pages > 1 : pages > 2;
          return Card(
            color: tooLong ? theme.colorScheme.errorContainer : null,
            child: ListTile(
              leading: Icon(tooLong ? Icons.warning_amber : Icons.check_circle_outline),
              title: Text('$pages page${pages == 1 ? '' : 's'} on A4'),
              subtitle: Text(tooLong
                  ? (onePage
                      ? 'This format should fit on one page. Shorten a few sections, or switch to a two-page format.'
                      : 'Keep a CV to two pages at most. Cut older or less relevant points.')
                  : 'Fill each page you use: one full page or two, not one and a half.'),
            ),
          );
        },
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
            onPressed: _busy ? null : () => _saveFiles(doc, word: true, pdf: false),
            icon: const Icon(Icons.description_outlined),
            label: const Text('Word (.docx)')),
        FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _saveFiles(doc, word: false, pdf: true),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('PDF')),
        OutlinedButton.icon(
            onPressed: _busy ? null : () => _saveFiles(doc, word: true, pdf: true),
            icon: const Icon(Icons.download),
            label: const Text('Both')),
      ]),
      const SizedBox(height: 20),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Use it with Pounce', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
                'Make it your master resume and the agents tailor every new job from it. You can also write a cover '
                'letter from it now.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                  onPressed: _busy ? null : () => _setMaster(doc),
                  icon: const Icon(Icons.star_outline),
                  label: const Text('Set as my master resume')),
              OutlinedButton.icon(
                  onPressed: _busy ? null : () => _letterFromThis(doc),
                  icon: const Icon(Icons.mail_outline),
                  label: const Text('Write a cover letter from this CV')),
            ]),
          ]),
        ),
      ),
    ]);
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// (key, label, hint, lines)
const _eduFields = [
  ('qualification', 'Qualification', 'BA (Hons) Marketing, or Highers / A levels', 1),
  ('institution', 'University, college or school', null, 1),
  ('location', 'Town or city', null, 1),
  ('start', 'Start', 'Sept 2022', 1),
  ('end', 'End', 'Jun 2026 (leave empty if you are still there)', 1),
  ('grade', 'Grade', '2:1, predicted 2:1, or AAB', 1),
  ('modules', 'Relevant modules or subjects', 'Digital Marketing, Consumer Behaviour', 1),
  ('details', 'Anything else worth saying', 'Dissertation title, awards, group projects, study abroad', 2),
];

const _expFields = [
  ('title', 'Job title or role', 'Barista, Marketing Intern, Class Representative', 1),
  ('organisation', 'Organisation', null, 1),
  ('location', 'Town or city', null, 1),
  ('start', 'Start', 'Jun 2024', 1),
  ('end', 'End', 'Leave empty if you still do it', 1),
  ('details', 'What did you do, and what came of it?',
      'One point per line, rough notes are fine:\nserved 100+ customers a day\ntrained two new starters\nhandled cash and card payments', 4),
];

const _projectFields = [
  ('name', 'Project name', null, 1),
  ('context', 'Where', 'Module, competition, society or personal project', 1),
  ('dates', 'When', 'Jan – Apr 2025', 1),
  ('details', 'What was it, what did you do and how did it go?', null, 3),
];

class _RegenerateDialog extends StatefulWidget {
  const _RegenerateDialog();

  @override
  State<_RegenerateDialog> createState() => _RegenerateDialogState();
}

class _RegenerateDialogState extends State<_RegenerateDialog> {
  static const _quick = ['Shorter', 'More detail', 'More formal', 'Simpler words', 'Different angle'];
  final _picked = <String>{};
  final _note = TextEditingController();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Regenerate this section'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('How should it change? Optional.'),
            const SizedBox(height: 10),
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
              decoration: const InputDecoration(
                  labelText: 'Anything specific', hintText: 'Mention the till training', border: OutlineInputBorder()),
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
