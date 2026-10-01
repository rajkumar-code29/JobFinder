import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/common.dart';

List<String> _strs(Object? v) =>
    v is String ? (v.trim().isEmpty ? [] : [v]) : v is List ? [for (final x in v) '$x'] : [];

List<Map<String, dynamic>> _items(Object? v) =>
    v is List ? [for (final x in v) if (x is Map) Map<String, dynamic>.from(x)] : [];

/// Same as clean_pack() in coach.py, for older packs.
Map<String, dynamic> normalizePack(Map<String, dynamic> pack) {
  final ov = pack['overview'] is Map ? Map<String, dynamic>.from(pack['overview'] as Map) : <String, dynamic>{};
  final mcq = <Map<String, dynamic>>[];
  for (final q in _items(pack['mcq'])) {
    final options = _strs(q['options']);
    final answer = q['answer_index'] is num ? (q['answer_index'] as num).toInt() : int.tryParse('${q['answer_index']}');
    if (q['question'] == null || options.length < 2 || answer == null || answer < 0 || answer >= options.length) continue;
    final why = _strs(q['why_wrong']);
    mcq.add({...q, 'options': options, 'answer_index': answer, 'why_wrong': [...why, ...List.filled(options.length, '')].take(options.length).toList()});
  }
  return {
    'overview': {
      'role_summary': ov['role_summary'] ?? (pack['overview'] is String ? pack['overview'] : null),
      'company_notes': ov['company_notes'],
      'interview_process_guess': _strs(ov['interview_process_guess']),
    },
    'mcq': mcq,
    'technical': [
      for (final q in _items(pack['technical']))
        if (q['question'] != null)
          {...q, 'what_they_look_for': _strs(q['what_they_look_for']), 'follow_ups': _strs(q['follow_ups'])},
    ],
    'coding': [
      for (final q in _items(pack['coding']))
        if (q['prompt'] != null)
          {...q, 'examples': _items(q['examples']), 'constraints': _strs(q['constraints']), 'hints': _strs(q['hints'])},
    ],
    'behavioral': [for (final q in _items(pack['behavioral'])) if (q['question'] != null) q],
    'questions_to_ask': _strs(pack['questions_to_ask']),
  };
}

class InterviewScreen extends StatefulWidget {
  const InterviewScreen({super.key, required this.jobId});
  final String jobId;

  @override
  State<InterviewScreen> createState() => _InterviewScreenState();
}

class _InterviewScreenState extends State<InterviewScreen> {
  late Future<(Job, Map<String, dynamic>)> _future = _load();

  Future<(Job, Map<String, dynamic>)> _load() async {
    final row = await supa.from('jobs').select().eq('job_id', widget.jobId).single();
    final job = Job(row);
    final path = job.files['interview'];
    if (path == null) throw 'The interview pack for this job has not been generated yet.';
    return (job, normalizePack(await Api.readJson(path)));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(Job, Map<String, dynamic>)>(
      future: _future,
      builder: (context, snap) {
        final back = BackButton(
            onPressed: () => context.canPop() ? context.pop() : context.go('/jobs/${widget.jobId}'));
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(leading: back, title: const Text('Interview prep')),
            body: ErrorView(snap.error!, onRetry: () => setState(() => _future = _load())),
          );
        }
        if (!snap.hasData) {
          return Scaffold(appBar: AppBar(leading: back), body: const Center(child: CircularProgressIndicator()));
        }
        final (job, pack) = snap.data!;
        List<Map<String, dynamic>> list(String k) =>
            ((pack[k] as List?) ?? []).whereType<Map<String, dynamic>>().toList();
        final tabs = [
          ('Overview', _Overview(job: job, pack: pack)),
          ('MCQ (${list('mcq').length})', _McqQuiz(questions: list('mcq'))),
          ('Technical', _Technical(items: list('technical'))),
          ('Coding', _Coding(items: list('coding'))),
          ('Behavioral', _Behavioral(items: list('behavioral'), toAsk: ((pack['questions_to_ask'] as List?) ?? []).cast<Object?>())),
        ];
        return DefaultTabController(
          length: tabs.length,
          child: Scaffold(
            appBar: AppBar(
              leading: back,
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text('${job.company} · ${job.jobId}', style: Theme.of(context).textTheme.bodySmall),
              ]),
              bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) Tab(text: t.$1)]),
            ),
            body: TabBarView(children: [for (final t in tabs) PageBody(maxWidth: 860, child: t.$2)]),
          ),
        );
      },
    );
  }
}

// overview
class _Overview extends StatelessWidget {
  const _Overview({required this.job, required this.pack});
  final Job job;
  final Map<String, dynamic> pack;

  @override
  Widget build(BuildContext context) {
    final o = (pack['overview'] as Map?) ?? {};
    final process = ((o['interview_process_guess'] as List?) ?? []).map((e) => '$e').toList();
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (o['role_summary'] != null) ...[
        Text('The role', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('${o['role_summary']}'),
        const SizedBox(height: 20),
      ],
      if (process.isNotEmpty) ...[
        Text('Likely interview process', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        for (final (i, step) in process.indexed)
          ListTile(dense: true, leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))), title: Text(step)),
        const SizedBox(height: 20),
      ],
      if (o['company_notes'] != null) ...[
        Text('About ${job.company}', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('${o['company_notes']}'),
      ],
    ]);
  }
}

// MCQ quiz
class _McqQuiz extends StatefulWidget {
  const _McqQuiz({required this.questions});
  final List<Map<String, dynamic>> questions;

  @override
  State<_McqQuiz> createState() => _McqQuizState();
}

class _McqQuizState extends State<_McqQuiz> with AutomaticKeepAliveClientMixin {
  int _index = 0;
  final Map<int, int> _answers = {};

  @override
  bool get wantKeepAlive => true;

  int get _correct => _answers.entries.where((e) => widget.questions[e.key]['answer_index'] == e.value).length;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final qs = widget.questions;
    if (qs.isEmpty) return const Center(child: Text('No multiple-choice questions in this pack.'));
    final theme = Theme.of(context);

    if (_index >= qs.length) {
      final pct = (_correct * 100 / qs.length).round();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ScoreBadge(label: 'Score', score: pct, big: true),
            const SizedBox(height: 12),
            Text('$_correct of ${qs.length} correct', style: theme.textTheme.titleLarge),
            const SizedBox(height: 20),
            Wrap(spacing: 12, children: [
              OutlinedButton(onPressed: () => setState(() => _index = 0), child: const Text('Review answers')),
              FilledButton(
                onPressed: () => setState(() {
                  _answers.clear();
                  _index = 0;
                }),
                child: const Text('Retake quiz'),
              ),
            ]),
          ]),
        ),
      );
    }

    final q = qs[_index];
    final options = ((q['options'] as List?) ?? []).map((e) => '$e').toList();
    final correct = q['answer_index'] as int? ?? 0;
    final whyWrong = ((q['why_wrong'] as List?) ?? []).map((e) => '$e').toList();
    final chosen = _answers[_index];
    final answered = chosen != null;

    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Text('Question ${_index + 1} of ${qs.length}', style: theme.textTheme.labelLarge),
        const Spacer(),
        if (q['topic'] != null) Chip(label: Text('${q['topic']}')),
        const SizedBox(width: 6),
        if (q['difficulty'] != null) Chip(label: Text('${q['difficulty']}')),
      ]),
      const SizedBox(height: 4),
      LinearProgressIndicator(value: (_index + (answered ? 1 : 0)) / qs.length),
      const SizedBox(height: 16),
      Text('${q['question']}', style: theme.textTheme.titleMedium),
      const SizedBox(height: 16),
      for (final (i, opt) in options.indexed)
        _OptionTile(
          letter: String.fromCharCode(65 + i),
          text: opt,
          state: !answered
              ? _OptState.idle
              : i == correct
                  ? _OptState.correct
                  : i == chosen
                      ? _OptState.wrong
                      : _OptState.dim,
          reason: answered && i != correct && i < whyWrong.length && whyWrong[i].isNotEmpty && (i == chosen) ? whyWrong[i] : null,
          onTap: answered ? null : () => setState(() => _answers[_index] = i),
        ),
      if (answered) ...[
        const SizedBox(height: 8),
        Card(
          color: (chosen == correct ? Colors.green : Colors.red).withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(chosen == correct ? Icons.check_circle : Icons.cancel,
                    color: chosen == correct ? Colors.green : Colors.red),
                const SizedBox(width: 8),
                Text(chosen == correct ? 'Correct!' : 'Not quite - the answer is ${String.fromCharCode(65 + correct)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 8),
              Text('${q['explanation'] ?? ''}'),
            ]),
          ),
        ),
      ],
      const SizedBox(height: 16),
      Row(children: [
        if (_index > 0) OutlinedButton(onPressed: () => setState(() => _index--), child: const Text('Previous')),
        const Spacer(),
        Text('$_correct correct so far', style: theme.textTheme.bodySmall),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: answered ? () => setState(() => _index++) : null,
          child: Text(_index == qs.length - 1 ? 'See results' : 'Next'),
        ),
      ]),
    ]);
  }
}

enum _OptState { idle, correct, wrong, dim }

class _OptionTile extends StatelessWidget {
  const _OptionTile({required this.letter, required this.text, required this.state, this.reason, this.onTap});
  final String letter;
  final String text;
  final _OptState state;
  final String? reason;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (border, bg, icon) = switch (state) {
      _OptState.correct => (Colors.green, Colors.green.withValues(alpha: 0.10), Icons.check_circle),
      _OptState.wrong => (Colors.red, Colors.red.withValues(alpha: 0.10), Icons.cancel),
      _OptState.dim => (scheme.outlineVariant, Colors.transparent, null),
      _OptState.idle => (scheme.outlineVariant, Colors.transparent, null),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: border, width: 1.4)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                CircleAvatar(radius: 13, child: Text(letter, style: const TextStyle(fontSize: 12))),
                const SizedBox(width: 12),
                Expanded(child: Text(text, style: TextStyle(color: state == _OptState.dim ? scheme.outline : null))),
                if (icon != null) Icon(icon, color: border),
              ]),
              if (reason != null) ...[
                const SizedBox(height: 8),
                Text(reason!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

// technical
class _Technical extends StatelessWidget {
  const _Technical({required this.items});
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Center(child: Text('No technical questions in this pack.'));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final q = items[i];
        final looks = ((q['what_they_look_for'] as List?) ?? []).map((e) => '$e');
        final follow = ((q['follow_ups'] as List?) ?? []).map((e) => '$e');
        return Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            leading: CircleAvatar(child: Text('${i + 1}')),
            title: Text('${q['question']}'),
            subtitle: q['topic'] == null ? null : Text('${q['topic']}'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Try answering out loud first, then compare.', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              if (looks.isNotEmpty) ...[
                const Text('What the interviewer looks for', style: TextStyle(fontWeight: FontWeight.w600)),
                for (final l in looks) Text('• $l'),
                const SizedBox(height: 10),
              ],
              const Text('Model answer', style: TextStyle(fontWeight: FontWeight.w600)),
              SelectableText('${q['model_answer'] ?? ''}'),
              if (follow.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('Likely follow-ups', style: TextStyle(fontWeight: FontWeight.w600)),
                for (final f in follow) Text('• $f'),
              ],
            ],
          ),
        );
      },
    );
  }
}

// coding
class _Coding extends StatelessWidget {
  const _Coding({required this.items});
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const Center(child: Text('No coding questions in this pack.'));
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _CodingCard(q: items[i], n: i + 1),
    );
  }
}

class _CodingCard extends StatefulWidget {
  const _CodingCard({required this.q, required this.n});
  final Map<String, dynamic> q;
  final int n;

  @override
  State<_CodingCard> createState() => _CodingCardState();
}

class _CodingCardState extends State<_CodingCard> {
  int _hints = 0;
  bool _solution = false;

  @override
  Widget build(BuildContext context) {
    final q = widget.q;
    final theme = Theme.of(context);
    final hints = ((q['hints'] as List?) ?? []).map((e) => '$e').toList();
    final examples = ((q['examples'] as List?) ?? []).whereType<Map>().toList();
    final constraints = ((q['constraints'] as List?) ?? []).map((e) => '$e').toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${widget.n}. ${q['title']}', style: theme.textTheme.titleMedium)),
            if (q['difficulty'] != null) Chip(label: Text('${q['difficulty']}')),
          ]),
          const SizedBox(height: 8),
          SelectableText('${q['prompt']}'),
          for (final ex in examples) _Code('Input:  ${ex['input']}\nOutput: ${ex['output']}'),
          if (constraints.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final c in constraints) Text('• $c', style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          for (final h in hints.take(_hints))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.lightbulb_outline, size: 18, color: Colors.amber),
                const SizedBox(width: 6),
                Expanded(child: Text(h)),
              ]),
            ),
          Wrap(spacing: 8, children: [
            if (_hints < hints.length)
              OutlinedButton.icon(
                onPressed: () => setState(() => _hints++),
                icon: const Icon(Icons.lightbulb_outline),
                label: Text('Hint ${_hints + 1}/${hints.length}'),
              ),
            FilledButton.tonalIcon(
              onPressed: () => setState(() => _solution = !_solution),
              icon: Icon(_solution ? Icons.visibility_off : Icons.visibility),
              label: Text(_solution ? 'Hide solution' : 'Show solution'),
            ),
          ]),
          if (_solution) ...[
            const SizedBox(height: 12),
            Text('Solution (${q['language'] ?? 'code'})', style: const TextStyle(fontWeight: FontWeight.w600)),
            _Code('${q['solution']}', copy: true),
            if (q['complexity'] != null) Text('Complexity: ${q['complexity']}', style: theme.textTheme.bodySmall),
            if (q['explanation'] != null) ...[const SizedBox(height: 6), Text('${q['explanation']}')],
          ],
        ]),
      ),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code(this.code, {this.copy = false});
  final String code;
  final bool copy;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Stack(children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          ),
          if (copy)
            Positioned(
              right: 0,
              top: 0,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  toast(context, 'Copied');
                },
              ),
            ),
        ]),
      );
}

// behavioral
class _Behavioral extends StatelessWidget {
  const _Behavioral({required this.items, required this.toAsk});
  final List<Map<String, dynamic>> items;
  final List<Object?> toAsk;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        for (final (i, q) in items.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text('${q['question']}'),
                subtitle: q['why_asked'] == null ? null : Text('${q['why_asked']}'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('STAR outline from your experience', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText('${q['star_outline'] ?? ''}'),
                ],
              ),
            ),
          ),
        if (toAsk.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Questions to ask them', style: Theme.of(context).textTheme.titleMedium),
          for (final q in toAsk) ListTile(dense: true, leading: const Icon(Icons.help_outline), title: Text('$q')),
        ],
      ]);
}
