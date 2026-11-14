// On-screen version of the CV and letter, in the same font as the files, plus the section editor.
import 'package:flutter/material.dart';

import 'cv.dart';

const _ink = Color(0xFF1A1A1A);
const _paperText = TextStyle(fontFamily: 'CvSans', fontSize: 13, height: 1.4, color: _ink);

class _Paper extends StatelessWidget {
  const _Paper({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 32),
        child: DefaultTextStyle(
          style: _paperText,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      );
}

Widget _bullet(String text) => Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(width: 14, child: Text('•')),
        Expanded(child: Text(text)),
      ]),
    );

class CvSectionView extends StatelessWidget {
  const CvSectionView(this.section, {super.key});
  final CvSection section;

  @override
  Widget build(BuildContext context) {
    final sec = section;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        margin: const EdgeInsets.only(top: 12, bottom: 6),
        padding: const EdgeInsets.only(bottom: 2),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF404040), width: 0.8))),
        child: Text(sec.heading, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
      ),
      for (final p in sec.paragraphs) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(p)),
      for (final g in sec.groups) ...[
        if (g.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text.rich(TextSpan(children: [
              if (g.label.isNotEmpty) TextSpan(text: '${g.label}: ', style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: g.text),
            ])),
          )
        else if (g.label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text(g.label, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        for (final x in g.bullets) _bullet(x),
      ],
      for (final e in sec.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Wrap(alignment: WrapAlignment.spaceBetween, spacing: 12, children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: e.title.isNotEmpty ? e.title : e.org, style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: () {
                final rest = [if (e.title.isNotEmpty) e.org, e.location].where((x) => x.isNotEmpty).join(', ');
                return rest.isEmpty ? '' : ', $rest';
              }()),
            ])),
            if (e.dates.isNotEmpty) Text(e.dates),
          ]),
        ),
        for (final l in e.lines) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(l)),
        for (final x in e.bullets) _bullet(x),
      ],
      for (final x in sec.bullets) _bullet(x),
    ]);
  }
}

/// The CV on a sheet of paper. [actions] adds buttons under each section.
class CvPaper extends StatelessWidget {
  const CvPaper({super.key, required this.doc, this.actions});
  final CvDoc doc;
  final Widget Function(CvSection section)? actions;

  @override
  Widget build(BuildContext context) => _Paper(children: [
        Text(doc.name.isEmpty ? 'Your name' : doc.name,
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(doc.contact.join('  |  '), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        for (final sec in doc.sections) ...[
          CvSectionView(sec),
          if (actions != null) actions!(sec),
        ],
      ]);
}

/// The letter on a sheet of paper. [actions] adds buttons under each generated part.
class LetterPaper extends StatelessWidget {
  const LetterPaper({super.key, required this.letter, required this.parts, this.actions});
  final LetterDoc letter;
  final Map<String, String> parts;
  final Widget Function(String part)? actions;

  @override
  Widget build(BuildContext context) => _Paper(children: [
        for (final line in letter.yourAddress) Text(line, textAlign: TextAlign.right),
        if (letter.yourAddress.isNotEmpty) const SizedBox(height: 14),
        Text(letter.date),
        const SizedBox(height: 14),
        for (final line in letter.recipient) Text(line),
        const SizedBox(height: 14),
        Text(letter.greeting),
        const SizedBox(height: 10),
        for (final p in letterParts) ...[
          for (final para in (parts[p] ?? '').split(RegExp(r'\n\s*\n')).where((x) => x.trim().isNotEmpty))
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(para.trim())),
          if (actions != null && (parts[p] ?? '').isNotEmpty) actions!(p),
        ],
        const SizedBox(height: 4),
        Text(letter.signOff),
        const SizedBox(height: 28),
        Text(letter.name.isEmpty ? 'Your name' : letter.name),
      ]);
}

// editing

List<String> _splitLines(String v) => v.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

/// Edits one CV section. Returns the edited copy, or null if cancelled.
Future<CvSection?> editSection(BuildContext context, CvSection section) => showDialog<CvSection>(
      context: context,
      builder: (_) => _SectionEditor(section: section.copy()),
    );

class _SectionEditor extends StatefulWidget {
  const _SectionEditor({required this.section});
  final CvSection section;

  @override
  State<_SectionEditor> createState() => _SectionEditorState();
}

class _SectionEditorState extends State<_SectionEditor> {
  late final sec = widget.section;
  late final _heading = TextEditingController(text: sec.heading);
  late final _paragraphs = TextEditingController(text: sec.paragraphs.join('\n\n'));
  late final _bullets = TextEditingController(text: sec.bullets.join('\n'));

  static const _entryKeys = {'education', 'experience_relevant', 'experience_other', 'volunteering', 'projects'};
  static const _groupKeys = {'skills', 'tech_skills'};
  static const _paragraphKeys = {'profile', 'references'};

  bool get _showEntries => _entryKeys.contains(sec.key) || sec.entries.isNotEmpty;
  bool get _showGroups => _groupKeys.contains(sec.key) || sec.groups.isNotEmpty;
  bool get _showParagraphs => _paragraphKeys.contains(sec.key) || sec.paragraphs.isNotEmpty;
  bool get _showBullets => !(_showEntries || _showGroups || _showParagraphs) || sec.bullets.isNotEmpty;

  void _done() {
    sec
      ..heading = _heading.text.trim().isEmpty ? sec.heading : _heading.text.trim()
      ..paragraphs = _paragraphs.text.split(RegExp(r'\n\s*\n')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList()
      ..bullets = _splitLines(_bullets.text)
      ..entries = sec.entries.where((e) => e.title.isNotEmpty || e.org.isNotEmpty || e.bullets.isNotEmpty).toList()
      ..groups = sec.groups.where((g) => g.label.isNotEmpty || g.text.isNotEmpty || g.bullets.isNotEmpty).toList();
    Navigator.pop(context, sec);
  }

  Widget _field(String label, String value, ValueChanged<String> onChanged, {int lines = 1, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          initialValue: value,
          minLines: lines,
          maxLines: lines == 1 ? 1 : lines + 6,
          decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder(), isDense: true),
          onChanged: onChanged,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Edit section'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: _heading,
              decoration: const InputDecoration(labelText: 'Heading', border: OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 12),
            if (_showParagraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _paragraphs,
                  minLines: 4,
                  maxLines: 12,
                  decoration: const InputDecoration(
                      labelText: 'Text (blank line between paragraphs)', border: OutlineInputBorder()),
                ),
              ),
            if (_showEntries) ...[
              for (final (i, e) in sec.entries.indexed)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                    child: Column(children: [
                      Row(children: [
                        Text('Entry ${i + 1}', style: theme.textTheme.labelLarge),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Remove entry',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(() => sec.entries.removeAt(i)),
                        ),
                      ]),
                      _field('Title', e.title, (v) => e.title = v.trim()),
                      _field('Organisation', e.org, (v) => e.org = v.trim()),
                      _field('Location', e.location, (v) => e.location = v.trim()),
                      _field('Dates', e.dates, (v) => e.dates = v.trim(), hint: 'Sept 2023 – Present'),
                      _field('Extra lines', e.lines.join('\n'), (v) => e.lines = _splitLines(v), lines: 2,
                          hint: 'Relevant modules: ...'),
                      _field('Bullet points (one per line)', e.bullets.join('\n'), (v) => e.bullets = _splitLines(v),
                          lines: 3),
                    ]),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => sec.entries.add(CvEntry())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add entry'),
                ),
              ),
            ],
            if (_showGroups) ...[
              for (final (i, g) in sec.groups.indexed)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                    child: Column(children: [
                      Row(children: [
                        Text('Group ${i + 1}', style: theme.textTheme.labelLarge),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Remove group',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(() => sec.groups.removeAt(i)),
                        ),
                      ]),
                      _field('Label', g.label, (v) => g.label = v.trim(), hint: 'Teamwork, or Technical'),
                      _field('One line (for lists)', g.text, (v) => g.text = v.trim(), hint: 'Python, SQL, Excel'),
                      _field('Evidence (one per line)', g.bullets.join('\n'), (v) => g.bullets = _splitLines(v),
                          lines: 2),
                    ]),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => sec.groups.add(CvGroup())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add group'),
                ),
              ),
            ],
            if (_showBullets)
              TextField(
                controller: _bullets,
                minLines: 3,
                maxLines: 12,
                decoration: const InputDecoration(labelText: 'Bullet points (one per line)', border: OutlineInputBorder()),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _done, child: const Text('Done')),
      ],
    );
  }
}
