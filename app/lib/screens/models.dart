import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../widgets/common.dart';

/// Agents, what they need from a model, and the built-in routing (mirrors DEFAULT_ROUTING in agents/jobfinder/llm.py).
const agentModelInfo = {
  'scout': ('Scout', 'Rates relevance in bulk – speed and volume matter', ['gemini:flash-lite']),
  'salary': ('Salary', 'Needs live web search → Gemini only', ['gemini:flash-lite', 'gemini:flash']),
  'search': ('Job search', 'Google-grounded job discovery → Gemini only', ['gemini:flash-lite', 'gemini:flash']),
  'scorer': ('Scorer', 'ATS score before and after tailoring – keep one model for consistency', ['gemini:flash-lite']),
  'tailor': ('Tailor', 'Highest quality, long input, strict edit rules', ['gemini:flash', 'gemini:flash-lite']),
  'coach': ('Coach', 'Very long output (MCQ, technical, coding)', ['gemini:flash', 'gemini:flash-lite']),
  'writer': ('Writer', 'Natural writing, short output', ['gemini:flash', 'gemini:flash-lite']),
  'profile': ('Profile', 'Reads your resume once per upload', ['gemini:flash', 'gemini:flash-lite']),
};

/// Suggestions in the editor; any "provider:model id" can be typed too.
const suggestedModels = {
  'gemini:flash': 'Gemini Flash – all versions, newest first (20/day each)',
  'gemini:flash-lite': 'Gemini Flash-Lite – all versions, newest first (500/day each)',
  'groq:openai/gpt-oss-120b': 'Groq · gpt-oss-120b (1k/day, prompts up to ~7.5k tokens)',
  'groq:openai/gpt-oss-20b': 'Groq · gpt-oss-20b (1k/day, prompts up to ~7.5k tokens)',
  'groq:qwen/qwen3.8-27b': 'Groq · Qwen 3.8 27B (1k/day, prompts up to ~7.5k tokens)',
};

String modelLabel(String spec) => switch (spec) {
      'gemini:flash' => 'Gemini Flash (all)',
      'gemini:flash-lite' => 'Gemini Flash-Lite (all)',
      _ => spec.replaceFirst('gemini:', 'Gemini · ').replaceFirst('groq:', 'Groq · ').replaceFirst('openrouter:', 'OpenRouter · '),
    };

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Api.isAdmin) {
      return Scaffold(appBar: AppBar(title: const Text('Models')), body: const Center(child: Text('Admins only')));
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI models'),
          bottom: const TabBar(tabs: [Tab(text: 'Routing'), Tab(text: 'Scorecard'), Tab(text: 'Compare')]),
        ),
        body: const TabBarView(children: [_RoutingTab(), _ScorecardTab(), _CompareTab()]),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ routing
class _RoutingTab extends StatefulWidget {
  const _RoutingTab();

  @override
  State<_RoutingTab> createState() => _RoutingTabState();
}

class _RoutingTabState extends State<_RoutingTab> {
  late Future<Map<String, List<String>>> _future = Api.modelRouting();

  Future<void> _edit(String agent, List<String> current, bool custom) async {
    final result = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _ChainEditor(agent: agent, chain: current, custom: custom),
    );
    if (result == null) return;
    try {
      result.reset ? await Api.resetRouting(agent) : await Api.saveRouting(agent, result.chain);
      setState(() => _future = Api.modelRouting());
      if (mounted) toast(context, 'Saved – used from the next run');
    } catch (e) {
      if (mounted) toast(context, 'Could not save: $e');
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, List<String>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView('${snap.error}\n\nRun supabase/migrations/006_models.sql.');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final routing = snap.data!;
          return PageBody(
            maxWidth: 860,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text('Each agent tries its models top to bottom. When one hits a limit, is overloaded or can\'t take a '
                  'prompt that big, the next one is used. Providers without an API key are skipped.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              for (final e in agentModelInfo.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: ListTile(
                      title: Row(children: [
                        Text(e.value.$1),
                        const SizedBox(width: 8),
                        if (routing.containsKey(e.key))
                          const Chip(label: Text('custom', style: TextStyle(fontSize: 10)), visualDensity: VisualDensity.compact),
                      ]),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.value.$2, style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 4, children: [
                          for (final (i, spec) in (routing[e.key] ?? e.value.$3).indexed)
                            Chip(
                              visualDensity: VisualDensity.compact,
                              avatar: CircleAvatar(radius: 9, child: Text('${i + 1}', style: const TextStyle(fontSize: 10))),
                              label: Text(modelLabel(spec), style: const TextStyle(fontSize: 12)),
                            ),
                        ]),
                      ]),
                      trailing: IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(e.key, routing[e.key] ?? e.value.$3, routing.containsKey(e.key)),
                      ),
                    ),
                  ),
                ),
            ]),
          );
        },
      );
}

class _EditResult {
  _EditResult(this.chain, {this.reset = false});
  final List<String> chain;
  final bool reset;
}

class _ChainEditor extends StatefulWidget {
  const _ChainEditor({required this.agent, required this.chain, required this.custom});
  final String agent;
  final List<String> chain;
  final bool custom;

  @override
  State<_ChainEditor> createState() => _ChainEditorState();
}

class _ChainEditorState extends State<_ChainEditor> {
  late final List<String> _chain = [...widget.chain];
  final _custom = TextEditingController();
  bool get _searchOnly => widget.agent == 'salary' || widget.agent == 'search';

  void _add(String spec) {
    spec = spec.trim();
    if (!RegExp(r'^(gemini|groq|openrouter):\S+$').hasMatch(spec)) {
      toast(context, 'Use provider:model, e.g. groq:openai/gpt-oss-120b');
      return;
    }
    if (_searchOnly && !spec.startsWith('gemini:')) {
      toast(context, 'Web search is Gemini-only');
      return;
    }
    if (!_chain.contains(spec)) setState(() => _chain.add(spec));
    _custom.clear();
  }

  @override
  Widget build(BuildContext context) {
    final info = agentModelInfo[widget.agent]!;
    final options = suggestedModels.keys.where((m) => !_chain.contains(m) && (!_searchOnly || m.startsWith('gemini:')));
    return AlertDialog(
      title: Text('${info.$1}: model order'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(info.$2, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          SizedBox(
            height: 220,
            child: ReorderableListView(
              buildDefaultDragHandles: false,
              onReorderItem: (from, to) => setState(() => _chain.insert(to, _chain.removeAt(from))),
              children: [
                for (final (i, spec) in _chain.indexed)
                  ListTile(
                    key: ValueKey(spec),
                    dense: true,
                    leading: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_indicator)),
                    title: Text('${i + 1}. ${modelLabel(spec)}'),
                    subtitle: Text(spec, style: const TextStyle(fontSize: 11)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _chain.length > 1 ? () => setState(() => _chain.removeAt(i)) : null,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in options)
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: Text(modelLabel(m), style: const TextStyle(fontSize: 12)),
                tooltip: suggestedModels[m],
                onPressed: () => _add(m),
              ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _custom,
            onSubmitted: _add,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: 'Other model, e.g. openrouter:meta-llama/llama-3.3-70b-instruct:free',
              suffixIcon: IconButton(icon: const Icon(Icons.add), onPressed: () => _add(_custom.text)),
            ),
          ),
        ]),
      ),
      actions: [
        if (widget.custom)
          TextButton(onPressed: () => Navigator.pop(context, _EditResult(const [], reset: true)), child: const Text('Reset to default')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _EditResult(_chain)), child: const Text('Save')),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ scorecard
class _ScorecardTab extends StatefulWidget {
  const _ScorecardTab();

  @override
  State<_ScorecardTab> createState() => _ScorecardTabState();
}

class _ScorecardTabState extends State<_ScorecardTab> {
  int _days = 14;
  late Future<List<Map<String, dynamic>>> _future = Api.scorecard(days: _days);

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView('${snap.error}');
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final rows = snap.data!;
          int n(Map r, String k) => (r[k] as num?)?.toInt() ?? 0;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Text('Last', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 8),
              SegmentedButton<int>(
                segments: const [ButtonSegment(value: 1, label: Text('1d')), ButtonSegment(value: 7, label: Text('7d')), ButtonSegment(value: 14, label: Text('14d')), ButtonSegment(value: 30, label: Text('30d'))],
                selected: {_days},
                onSelectionChanged: (s) => setState(() {
                  _days = s.first;
                  _future = Api.scorecard(days: _days);
                }),
              ),
            ]),
            const SizedBox(height: 8),
            Text('Success = answered / (answered + every kind of refusal or failure). 👍/👎 come from Jobs → job → '
                '"Rate the AI\'s work".', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (rows.isEmpty) const Text('No AI calls recorded yet – the scorecard fills in as the agents run.'),
            if (rows.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 18,
                  columns: const [
                    DataColumn(label: Text('Agent')),
                    DataColumn(label: Text('Model')),
                    DataColumn(label: Text('OK'), numeric: true),
                    DataColumn(label: Text('Success'), numeric: true),
                    DataColumn(label: Text('Avg s'), numeric: true),
                    DataColumn(label: Text('Limits'), numeric: true),
                    DataColumn(label: Text('Overloaded'), numeric: true),
                    DataColumn(label: Text('Bad JSON'), numeric: true),
                    DataColumn(label: Text('Too big'), numeric: true),
                    DataColumn(label: Text('Errors'), numeric: true),
                    DataColumn(label: Text('👍'), numeric: true),
                    DataColumn(label: Text('👎'), numeric: true),
                  ],
                  rows: [
                    for (final r in rows)
                      DataRow(cells: [
                        DataCell(Text(agentModelInfo[r['agent']]?.$1 ?? '${r['agent']}')),
                        DataCell(Text(modelLabel('${r['model']}'))),
                        DataCell(Text('${n(r, 'ok')}')),
                        DataCell(Builder(builder: (_) {
                          final fails = n(r, 'rate_limited') + n(r, 'overloaded') + n(r, 'invalid_json') + n(r, 'too_large') + n(r, 'errors');
                          final total = n(r, 'ok') + fails;
                          final pct = total == 0 ? null : (n(r, 'ok') * 100 / total).round();
                          return Text(pct == null ? '—' : '$pct%', style: TextStyle(color: scoreColor(context, pct)));
                        })),
                        DataCell(Text(r['avg_seconds'] == null ? '—' : '${r['avg_seconds']}')),
                        DataCell(Text('${n(r, 'rate_limited')}')),
                        DataCell(Text('${n(r, 'overloaded')}')),
                        DataCell(Text('${n(r, 'invalid_json')}')),
                        DataCell(Text('${n(r, 'too_large')}')),
                        DataCell(Text('${n(r, 'errors')}')),
                        DataCell(Text('${n(r, 'thumbs_up')}')),
                        DataCell(Text('${n(r, 'thumbs_down')}')),
                      ]),
                  ],
                ),
              ),
          ]);
        },
      );
}

// ------------------------------------------------------------------------------------------------ compare
class _CompareTab extends StatelessWidget {
  const _CompareTab();

  Future<void> _new(BuildContext context) async {
    final req = await showDialog<(String, List<String>, int)>(context: context, builder: (_) => const _NewComparison());
    if (req == null) return;
    try {
      await Api.requestComparison(req.$1, req.$2, req.$3);
      if (context.mounted) toast(context, 'Comparison started – results appear here in a few minutes');
    } catch (e) {
      if (context.mounted) toast(context, '$e'.replaceFirst(RegExp(r'^.*?message: '), ''));
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Map<String, dynamic>>>(
        stream: Api.comparisonsStream(),
        builder: (context, snap) {
          final items = [...(snap.data ?? <Map<String, dynamic>>[])]..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
          return PageBody(
            maxWidth: 860,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text('Runs the same jobs from your latest batch through each candidate model for one agent – nothing '
                  'in your jobs changes. Metrics are measured automatically; for writing you pick the best blind.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(onPressed: () => _new(context), icon: const Icon(Icons.compare_arrows), label: const Text('New comparison')),
              ),
              const SizedBox(height: 12),
              if (snap.hasError) Text('${snap.error}'),
              for (final c in items)
                Card(
                  child: ListTile(
                    leading: Icon(switch (c['status']) {
                      'done' => Icons.check_circle,
                      'error' => Icons.error,
                      _ => Icons.hourglass_top,
                    }, color: switch (c['status']) { 'done' => Colors.green, 'error' => Colors.red, _ => Colors.orange }),
                    title: Text('#${c['id']} · ${agentModelInfo[c['agent']]?.$1 ?? c['agent']} · ${c['job_count']} jobs'),
                    subtitle: Text('${(c['models'] as List).map((m) => modelLabel('$m')).join('  vs  ')}\n'
                        '${c['status']}${c['message'] != null ? ' – ${c['message']}' : ''}'),
                    isThreeLine: true,
                    onTap: () => context.go('/models/compare/${c['id']}'),
                  ),
                ),
            ]),
          );
        },
      );
}

class _NewComparison extends StatefulWidget {
  const _NewComparison();

  @override
  State<_NewComparison> createState() => _NewComparisonState();
}

class _NewComparisonState extends State<_NewComparison> {
  String _agent = 'writer';
  final _models = <String>{'gemini:flash', 'groq:openai/gpt-oss-120b'};
  int _jobs = 3;
  final _custom = TextEditingController();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New comparison'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<String>(
                initialValue: _agent,
                decoration: const InputDecoration(labelText: 'Agent', border: OutlineInputBorder()),
                items: [
                  for (final a in ['scout', 'scorer', 'tailor', 'coach', 'writer'])
                    DropdownMenuItem(value: a, child: Text(agentModelInfo[a]!.$1)),
                ],
                onChanged: (v) => setState(() => _agent = v ?? 'writer'),
              ),
              const SizedBox(height: 12),
              Text('Models (2–4)', style: Theme.of(context).textTheme.labelLarge),
              for (final m in {...suggestedModels.keys, ..._models})
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _models.contains(m),
                  title: Text(modelLabel(m)),
                  subtitle: suggestedModels[m] == null ? null : Text(suggestedModels[m]!, style: const TextStyle(fontSize: 11)),
                  onChanged: (v) => setState(() => v == true ? _models.add(m) : _models.remove(m)),
                ),
              TextField(
                controller: _custom,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: 'Add another: provider:model',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      if (RegExp(r'^(gemini|groq|openrouter):\S+$').hasMatch(_custom.text.trim())) {
                        setState(() => _models.add(_custom.text.trim()));
                        _custom.clear();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                const Text('Jobs'),
                Expanded(
                  child: Slider(value: _jobs.toDouble(), min: 1, max: 5, divisions: 4, label: '$_jobs',
                      onChanged: (v) => setState(() => _jobs = v.round())),
                ),
                Text('$_jobs'),
              ]),
              Text('Uses about ${_jobs * _models.length * (_agent == 'tailor' ? 2 : 1)} AI calls. Groq\'s free tier only '
                  'accepts prompts up to ~7.5k tokens, so it may be skipped for Tailor, Scorer and Coach.',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _models.length < 2 || _models.length > 4
                ? null
                : () => Navigator.pop(context, (_agent, _models.toList(), _jobs)),
            child: const Text('Start'),
          ),
        ],
      );
}

/// Results of one comparison: automatic metrics per model, then a blind A/B/C review per job.
class ComparisonScreen extends StatefulWidget {
  const ComparisonScreen({super.key, required this.id});
  final int id;

  @override
  State<ComparisonScreen> createState() => _ComparisonScreenState();
}

class _ComparisonScreenState extends State<ComparisonScreen> {
  late final Stream<List<Map<String, dynamic>>> _results = Api.comparisonResultsStream(widget.id);
  Map<String, String> _votes = {};

  @override
  void initState() {
    super.initState();
    Api.myComparisonVotes(widget.id).then((v) => mounted ? setState(() => _votes = v) : null);
  }

  Future<void> _vote(String jobId, String model) async {
    try {
      await Api.voteComparison(widget.id, jobId, model);
      setState(() => _votes = {..._votes, jobId: model});
    } catch (e) {
      if (mounted) toast(context, 'Could not save vote: $e');
    }
  }

  static const _metricLabels = {
    'score': 'Relevance', 'difference': 'vs production', 'ats': 'ATS', 'shortlist': 'Shortlist %',
    'gain': 'ATS gain', 'ats_after': 'ATS after', 'edits': 'Edits', 'added_skills': 'Skills added',
    'mcq': 'MCQ', 'technical': 'Technical', 'coding': 'Coding', 'words': 'Words', 'seconds': 'Seconds',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/models')),
          title: Text('Comparison #${widget.id}'),
        ),
        body: StreamBuilder<List<Map<String, dynamic>>>(
          stream: _results,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(snap.error!);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final results = snap.data!;
            if (results.isEmpty) return const Center(child: Text('Waiting for the first results…'));
            final models = results.map((r) => r['model'] as String).toSet().toList();
            final byJob = <String, List<Map<String, dynamic>>>{};
            for (final r in results) {
              byJob.putIfAbsent(r['job_id'] as String, () => []).add(r);
            }
            final wins = {for (final m in models) m: _votes.values.where((w) => w == m).length};

            // Averages of numeric metrics per model
            final summary = <String, Map<String, double>>{};
            for (final m in models) {
              final ok = results.where((r) => r['model'] == m && (r['metrics'] as Map)['ok'] == true).toList();
              final sums = <String, List<double>>{};
              for (final r in ok) {
                (r['metrics'] as Map).forEach((k, v) {
                  if (v is num && _metricLabels.containsKey(k)) sums.putIfAbsent(k as String, () => []).add(v.toDouble());
                });
              }
              summary[m] = {
                'ok': ok.length.toDouble(),
                'total': results.where((r) => r['model'] == m).length.toDouble(),
                for (final e in sums.entries) e.key: e.value.reduce((a, b) => a + b) / e.value.length,
              };
            }
            final metricKeys = _metricLabels.keys.where((k) => summary.values.any((s) => s.containsKey(k))).toList();

            return PageBody(
              maxWidth: 980,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Text('Averages', style: Theme.of(context).textTheme.titleMedium),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(columnSpacing: 18, columns: [
                    const DataColumn(label: Text('Model')),
                    const DataColumn(label: Text('Worked'), numeric: true),
                    for (final k in metricKeys) DataColumn(label: Text(_metricLabels[k]!), numeric: true),
                    const DataColumn(label: Text('Your picks'), numeric: true),
                  ], rows: [
                    for (final m in models)
                      DataRow(cells: [
                        DataCell(Text(modelLabel(m))),
                        DataCell(Text('${summary[m]!['ok']!.toInt()}/${summary[m]!['total']!.toInt()}')),
                        for (final k in metricKeys)
                          DataCell(Text(summary[m]![k] == null ? '—' : summary[m]![k]!.toStringAsFixed(1))),
                        DataCell(Text('${wins[m]}')),
                      ]),
                  ]),
                ),
                const SizedBox(height: 20),
                Text('Blind review – pick the best output per job', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Model names are hidden until you vote.', style: Theme.of(context).textTheme.bodySmall),
                for (final entry in byJob.entries) _BlindJob(
                  comparisonId: widget.id,
                  jobId: entry.key,
                  results: entry.value,
                  vote: _votes[entry.key],
                  onVote: (m) => _vote(entry.key, m),
                ),
              ]),
            );
          },
        ),
      );
}

class _BlindJob extends StatelessWidget {
  const _BlindJob({required this.comparisonId, required this.jobId, required this.results, required this.vote, required this.onVote});
  final int comparisonId;
  final String jobId;
  final List<Map<String, dynamic>> results;
  final String? vote;
  final ValueChanged<String> onVote;

  String _display(Map<String, dynamic> r) {
    final out = r['output'] as String?;
    if (out == null) return 'Failed: ${(r['metrics'] as Map)['error']}';
    if (out.trimLeft().startsWith('{')) {
      try {  // interview pack: show a readable digest
        final p = jsonDecode(out) as Map<String, dynamic>;
        final mcq = (p['mcq'] as List? ?? []).take(3).map((q) => '• ${q['question']}').join('\n');
        final tech = (p['technical'] as List? ?? []).take(2).map((q) => '• ${q['question']}').join('\n');
        final code = (p['coding'] as List? ?? []).take(1).map((q) => '• ${q['title']}: ${q['prompt']}').join('\n');
        return 'MCQ (first 3 of ${(p['mcq'] as List? ?? []).length}):\n$mcq\n\nTechnical:\n$tech\n\nCoding:\n$code';
      } catch (_) {}
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    // Stable shuffle per job so option letters don't reveal the model order.
    final shuffled = [...results]..shuffle(Random(jobId.hashCode ^ comparisonId));
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: Text(jobId, style: const TextStyle(fontFamily: 'monospace')),
        subtitle: Text(vote == null ? 'Not reviewed yet' : 'You picked ${modelLabel(vote!)}'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          for (final (i, r) in shuffled.indexed)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                border: Border.all(color: vote == r['model'] ? Colors.green : theme.colorScheme.outlineVariant, width: vote == r['model'] ? 2 : 1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('Option ${String.fromCharCode(65 + i)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (vote != null) ...[const SizedBox(width: 8), Text(modelLabel(r['model'] as String), style: theme.textTheme.bodySmall)],
                  const Spacer(),
                  if (r['output'] != null)
                    TextButton.icon(onPressed: () => onVote(r['model'] as String), icon: const Icon(Icons.thumb_up_alt_outlined, size: 16), label: const Text('Best')),
                ]),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: SingleChildScrollView(child: SelectableText(_display(r), style: const TextStyle(fontSize: 13))),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}
