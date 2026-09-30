import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../config.dart';
import '../models.dart';
import '../widgets/common.dart';

const agentInfo = {
  'profile': (Icons.person_search, 'Profile agent', 'Knows your parent resume & cover letter'),
  'scout': (Icons.travel_explore, 'Scout agent', 'Scans job boards for resume-relevant postings'),
  'salary': (Icons.payments_outlined, 'Salary agent', 'Finds pay in the JD or estimates it (Glassdoor etc.)'),
  'scorer': (Icons.analytics_outlined, 'Scorer agent', 'ATS + shortlist scoring and suggestions'),
  'tailor': (Icons.auto_fix_high, 'Tailor agent', 'Builds the job-specific resume'),
  'coach': (Icons.school_outlined, 'Coach agent', 'Interview questions, MCQ & coding'),
  'writer': (Icons.edit_note, 'Writer agent', 'Tailored cover letter'),
};

class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  late final Stream<List<AgentRun>> _stream = Api.agentRunsStream(limit: 200);
  late Future<List<Map<String, dynamic>>> _runs = Api.pipelineRuns();
  bool _errorsOnly = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _errorsOnly = GoRouterState.of(context).uri.queryParameters['errors'] == '1';
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Agents'),
          actions: [
            if (Api.isAdmin) ...[
              if (AppConfig.githubRepo.isNotEmpty)
                IconButton(
                  tooltip: 'Open the workflow on GitHub',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => launchUrl(
                    Uri.parse('https://github.com/${AppConfig.githubRepo}/actions/workflows/agents.yml'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              const _RunNowButton(),
            ],
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Activity'), Tab(text: 'Runs')]),
        ),
        body: TabBarView(children: [
          StreamBuilder<List<AgentRun>>(
            stream: _stream,
            builder: (context, snap) {
              if (snap.hasError) return ErrorView(snap.error!);
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final runs = snap.data!.where((r) => !_errorsOnly || r.status == 'error').toList();
              return PageBody(
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  _AgentSummary(runs: snap.data!),
                  const SizedBox(height: 12),
                  Row(children: [
                    Text('Task log', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    FilterChip(
                      label: const Text('Errors only'),
                      selected: _errorsOnly,
                      onSelected: (v) => setState(() => _errorsOnly = v),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  if (runs.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Nothing here yet'))),
                  for (final r in runs) AgentRunTile(run: r),
                ]),
              );
            },
          ),
          RefreshIndicator(
            onRefresh: () async => setState(() => _runs = Api.pipelineRuns()),
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _runs,
              builder: (context, snap) {
                if (snap.hasError) return ErrorView(snap.error!);
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                return PageBody(
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    for (final r in snap.data!) _PipelineRunCard(run: r),
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _AgentSummary extends StatelessWidget {
  const _AgentSummary({required this.runs});
  final List<AgentRun> runs;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final e in agentInfo.entries)
        Builder(builder: (context) {
          final mine = runs.where((r) => r.agent == e.key);
          final busy = mine.any((r) => r.status == 'running');
          final errs = mine.where((r) => r.status == 'error').length;
          return SizedBox(
            width: 250,
            child: Card(
              child: ListTile(
                leading: Icon(e.value.$1, color: busy ? Colors.deepPurple : null),
                title: Text(e.value.$2),
                subtitle: Text(busy ? 'Working…' : '${mine.length} recent tasks${errs > 0 ? ' · $errs errors' : ''}'),
                trailing: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : null,
              ),
            ),
          );
        }),
    ]);
  }
}

class AgentRunTile extends StatelessWidget {
  const AgentRunTile({super.key, required this.run});
  final AgentRun run;

  @override
  Widget build(BuildContext context) {
    final info = agentInfo[run.agent];
    final (icon, color) = switch (run.status) {
      'running' => (Icons.autorenew, Colors.deepPurple),
      'error' => (Icons.error, Colors.red),
      _ => (Icons.check_circle, Colors.green),
    };
    final d = run.duration;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Stack(clipBehavior: Clip.none, children: [
          Icon(info?.$1 ?? Icons.smart_toy_outlined),
          Positioned(right: -6, bottom: -6, child: Icon(icon, size: 14, color: color)),
        ]),
        title: Text('${info?.$2 ?? run.agent}${run.jobId != null ? ' · ${run.jobId}' : ''}'),
        subtitle: Text(run.message ?? '', maxLines: 3, overflow: TextOverflow.ellipsis),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(ago(run.startedAt), style: Theme.of(context).textTheme.labelSmall),
          if (d != null) Text('${d.inSeconds}s', style: Theme.of(context).textTheme.labelSmall),
        ]),
        onTap: run.jobId == null ? null : () => context.go('/jobs/${run.jobId}'),
      ),
    );
  }
}

class _PipelineRunCard extends StatelessWidget {
  const _PipelineRunCard({required this.run});
  final Map<String, dynamic> run;

  @override
  Widget build(BuildContext context) {
    final started = DateTime.parse(run['started_at'] as String).toLocal();
    final status = run['status'] as String;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(
          status == 'running' ? Icons.autorenew : status == 'error' ? Icons.error : Icons.check_circle,
          color: status == 'running' ? Colors.deepPurple : status == 'error' ? Colors.red : Colors.green,
        ),
        title: Text('${DateFormat.MMMd().add_jm().format(started)} · ${run['trigger']}'),
        subtitle: Text('Scanned ${run['jobs_scanned']} · matched ${run['jobs_matched']} · '
            'processed ${run['jobs_processed']} · errors ${run['errors']}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText('${run['log'] ?? 'No log'}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ),
    );
  }
}


/// Admin only: start the agents workflow now (the database holds the GitHub token and re-checks the email domain).
class _RunNowButton extends StatefulWidget {
  const _RunNowButton();

  @override
  State<_RunNowButton> createState() => _RunNowButtonState();
}

class _RunNowButtonState extends State<_RunNowButton> {
  bool _busy = false;

  Future<void> _run() async {
    final allSources = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        var all = true;
        return StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
            title: const Text('Run the agents now?'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Starts a full run on GitHub for every user: scan, rate, then process queued jobs. '
                  'It shows up under Runs within a minute or two.'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: all,
                onChanged: (v) => set(() => all = v ?? true),
                title: const Text('Scan all sources'),
                subtitle: const Text('Off = respect the usual schedule (Remotive every 6h, Google search every 4h)'),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, all), child: const Text('Run now')),
            ],
          ),
        );
      },
    );
    if (allSources == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final id = await Api.requestAgentsRun(allSources: allSources);
      int? code;
      String? message;
      for (var i = 0; i < 10 && code == null; i++) {
        await Future.delayed(const Duration(seconds: 1));
        (code, message) = await Api.agentsRunRequestStatus(id);
      }
      if (!mounted) return;
      toast(
        context,
        code == 204
            ? 'Run started – it appears under Runs in a minute or two'
            : code == null
                ? 'Run requested – GitHub hasn\'t answered yet; check Runs shortly'
                : 'GitHub refused the run ($code): ${message ?? ''}',
      );
    } catch (e) {
      if (mounted) toast(context, '$e'.replaceFirst(RegExp(r'^.*?message: '), ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: _busy ? null : _run,
        icon: _busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.play_arrow),
        label: const Text('Run now'),
      );
}
