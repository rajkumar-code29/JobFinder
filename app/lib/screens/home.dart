import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/common.dart';
import '../widgets/onboarding.dart';
import 'agents.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Stats? _stats;
  Object? _error;
  late final StreamSubscription _sub;
  List<AgentRun> _runs = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
    // Any agent activity changes the counters: refresh stats (debounced) whenever the live feed ticks.
    _sub = Api.agentRunsStream(limit: 30).listen((runs) {
      setState(() => _runs = runs);
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 800), _load);
    }, onError: (e) => setState(() => _error = e));
  }

  Future<void> _load() async {
    try {
      final s = await Api.stats();
      if (mounted) {
        setState(() {
          _stats = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final running = _runs.where((r) => r.status == 'running').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard'), actions: [
        IconButton(onPressed: () => context.go('/help'), icon: const Icon(Icons.help_outline), tooltip: 'How it works'),
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
      ]),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          PageBody(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const GettingStartedCard(),
              const AgentControlCard(),
              const _CurrentBatchCard(),
              if (_error != null && s == null) ErrorView(_error!, onRetry: _load),
              if (s == null && _error == null) const LinearProgressIndicator(),
              if (s != null) ...[
                _StatGrid(stats: s),
                const SizedBox(height: 8),
                Text(
                  s.lastRunAt == null ? 'Agents have not run yet' : 'Last scan ${ago(s.lastRunAt!)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 24),
              Row(children: [
                Text('Working now', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                if (running.isNotEmpty)
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ]),
              const SizedBox(height: 8),
              if (running.isEmpty)
                const Card(child: ListTile(leading: Icon(Icons.bedtime_outlined), title: Text('All agents idle'))),
              for (final r in running) AgentRunTile(run: r),
              const SizedBox(height: 24),
              Row(children: [
                Text('Recent activity', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(onPressed: () => context.go('/agents'), child: const Text('See all')),
              ]),
              for (final r in _runs.where((r) => r.status != 'running').take(8)) AgentRunTile(run: r),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});
  final Stats stats;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      (Icons.manage_search, 'Jobs scanned', '${stats.totalScanned}', null, Colors.blue),
      (Icons.filter_alt_outlined, 'Matched to resume', '${stats.totalMatched}', '/jobs', Colors.indigo),
      (Icons.task_alt, 'Ready to apply', '${stats.ready}', '/jobs?status=ready', Colors.teal),
      (Icons.send_outlined, 'Applied', '${stats.applied}', '/jobs?status=applied', Colors.green),
      (Icons.error_outline, 'Errors (24h / all)', '${stats.errors24h} / ${stats.totalErrors}', '/agents?errors=1', Colors.red),
      (Icons.smart_toy_outlined, 'Agents working', '${stats.agentsRunning}', '/agents', Colors.deepPurple),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 900 ? 6 : c.maxWidth > 560 ? 3 : 2;
      return GridView.count(
        crossAxisCount: cols,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.35,
        children: [
          for (final (icon, label, value, route, color) in tiles)
            Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: route == null ? null : () => context.go(route),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(icon, color: color),
                    const Spacer(),
                    FittedBox(
                      child: Text(value,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    Text(label, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
              ),
            ),
        ],
      );
    });
  }
}


/// Kill switch. Everyone sees when the agents are paused; only admins (@rajkumar.codes) can pause or resume.
class AgentControlCard extends StatelessWidget {
  const AgentControlCard({super.key});

  Future<void> _set(BuildContext context, bool paused) async {
    if (paused) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Pause all agents?'),
          content: const Text('The running agents stop at their next step (usually within a minute) and scheduled '
              'runs are skipped until you resume. Nothing is lost – work continues where it stopped.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pause agents')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await Api.setAgentsPaused(paused);
      if (context.mounted) toast(context, paused ? 'Agents paused' : 'Agents resumed – they continue on the next run');
    } catch (e) {
      if (context.mounted) toast(context, 'Could not change: $e');
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<AgentControl?>(
        stream: Api.controlStream(),
        builder: (context, snap) {
          final control = snap.data;
          if (snap.hasError || control == null) return const SizedBox.shrink(); // migration 005 not applied yet
          final admin = Api.isAdmin;
          if (!control.paused && !admin) return const SizedBox.shrink();
          final theme = Theme.of(context);
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              color: control.paused ? Colors.orange.withValues(alpha: 0.15) : null,
              child: ListTile(
                leading: Icon(control.paused ? Icons.pause_circle : Icons.play_circle,
                    color: control.paused ? Colors.orange : Colors.green, size: 32),
                title: Text(control.paused ? 'Agents are paused' : 'Agents are running'),
                subtitle: Text(control.paused
                    ? 'Paused${control.changedBy != null ? ' by ${control.changedBy}' : ''}'
                        '${control.changedAt != null ? ' · ${ago(control.changedAt!)}' : ''}. No runs until resumed.'
                    : 'Admin: pause stops every agent at its next step and skips scheduled runs.'),
                trailing: admin
                    ? (control.paused
                        ? FilledButton.icon(
                            onPressed: () => _set(context, false),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Resume'),
                          )
                        : OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                            onPressed: () => _set(context, true),
                            icon: const Icon(Icons.pause),
                            label: const Text('Pause all'),
                          ))
                    : null,
              ),
            ),
          );
        },
      );
}

class _CurrentBatchCard extends StatelessWidget {
  const _CurrentBatchCard();

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Batch>>(
        stream: Api.batchesStream(),
        builder: (context, snap) {
          final batches = [...(snap.data ?? <Batch>[])]..sort((a, b) => b.number.compareTo(a.number));
          if (batches.isEmpty) return const SizedBox.shrink();
          final b = batches.first;
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              child: ListTile(
                leading: CircleAvatar(child: Text('#${b.number}', style: const TextStyle(fontSize: 12))),
                title: Text(b.done ? 'Batch #${b.number} finished' : 'Batch #${b.number}: ${b.stageLabel.toLowerCase()}'),
                subtitle: Text('${b.jobCount} jobs · started ${ago(b.createdAt)}'
                    '${b.done ? ' · the next batch starts on the next run' : ''}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/jobs'),
              ),
            ),
          );
        },
      );
}
