import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/common.dart';

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key, this.initialStatus});
  final String? initialStatus;

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

enum _Filter { all, ready, inProgress, applied, error }

class _JobsScreenState extends State<JobsScreen> {
  late _Filter _filter = switch (widget.initialStatus) {
    'ready' => _Filter.ready,
    'applied' => _Filter.applied,
    'error' => _Filter.error,
    _ => _Filter.all,
  };
  String _query = '';
  final _collapsed = <String>{};
  late final Stream<List<Job>> _jobs = Api.jobsStream();
  late final Stream<List<Batch>> _batches = Api.batchesStream();

  static const _labels = {
    _Filter.all: 'All',
    _Filter.ready: 'Ready',
    _Filter.inProgress: 'In progress',
    _Filter.applied: 'Applied',
    _Filter.error: 'Error',
  };

  bool _matchFilter(Job j, _Filter f) => switch (f) {
        _Filter.all => true,
        _Filter.ready => j.status == 'ready',
        _Filter.inProgress => const {'new', 'scored', 'tailored'}.contains(j.status),
        _Filter.applied => j.isApplied,
        _Filter.error => j.status == 'error',
      };

  bool _match(Job j) {
    if (!_matchFilter(j, _filter)) return false;
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return j.jobId.toLowerCase().contains(q) ||
        j.title.toLowerCase().contains(q) ||
        j.company.toLowerCase().contains(q) ||
        j.location.toLowerCase().contains(q);
  }

  static int _byRank(Job a, Job b) {
    final ra = a.batchRank ?? 1 << 20, rb = b.batchRank ?? 1 << 20;
    if (ra != rb) return ra.compareTo(rb);
    return (b.relevance ?? 0).compareTo(a.relevance ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Jobs')),
      body: StreamBuilder<List<Batch>>(
        stream: _batches,
        builder: (context, batchSnap) => StreamBuilder<List<Job>>(
          stream: _jobs,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(snap.error!);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final all = snap.data!;
            final batches = [...(batchSnap.data ?? <Batch>[])]..sort((a, b) => b.number.compareTo(a.number));
            final visible = all.where(_match).toList();

            // Sections: newest batch first, then jobs waiting for a batch, then jobs from before batches existed.
            final sections = <({String key, Widget header, List<Job> jobs})>[];
            for (final b in batches) {
              final inBatch = all.where((j) => j.batchId == b.id).toList();
              final shown = visible.where((j) => j.batchId == b.id).toList()..sort(_byRank);
              if (shown.isEmpty && (_filter != _Filter.all || _query.isNotEmpty)) continue;
              sections.add((key: b.id, header: _BatchHeader(batch: b, jobs: inBatch), jobs: shown));
            }
            final waiting = visible.where((j) => j.batchId == null && j.status == 'new').toList()..sort(_byRank);
            if (waiting.isNotEmpty) {
              sections.add((
                key: 'waiting',
                header: _SimpleHeader(
                  icon: Icons.hourglass_empty,
                  title: 'Waiting for a batch',
                  subtitle: '${waiting.length} relevant jobs – they join the next batch once the current one is done',
                ),
                jobs: waiting,
              ));
            }
            final earlier = visible.where((j) => j.batchId == null && j.status != 'new').toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
            if (earlier.isNotEmpty) {
              sections.add((
                key: 'earlier',
                header: _SimpleHeader(icon: Icons.history, title: 'Earlier jobs', subtitle: '${earlier.length} jobs from before batches'),
                jobs: earlier,
              ));
            }

            return PageBody(
              child: CustomScrollView(slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search job id, title, company, location',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _query = v.trim()),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      for (final f in _Filter.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            label: Text('${_labels[f]} (${all.where((j) => _matchFilter(j, f)).length})'),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                          ),
                        ),
                    ]),
                  ),
                ),
                if (sections.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('No jobs here yet – the agents build a new batch every hour.')),
                  ),
                for (final section in sections) ...[
                  SliverToBoxAdapter(
                    child: InkWell(
                      onTap: () => setState(() => _collapsed.contains(section.key)
                          ? _collapsed.remove(section.key)
                          : _collapsed.add(section.key)),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Row(children: [
                          Expanded(child: section.header),
                          Icon(_collapsed.contains(section.key) ? Icons.expand_more : Icons.expand_less),
                        ]),
                      ),
                    ),
                  ),
                  if (!_collapsed.contains(section.key))
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      sliver: SliverLayoutBuilder(builder: (context, c) {
                        final cols = (c.crossAxisExtent / 360).floor().clamp(1, 3);
                        return SliverGrid(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: cols,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            mainAxisExtent: 226,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (_, i) => JobCard(job: section.jobs[i]),
                            childCount: section.jobs.length,
                          ),
                        );
                      }),
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _BatchHeader extends StatelessWidget {
  const _BatchHeader({required this.batch, required this.jobs});
  final Batch batch;
  final List<Job> jobs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = jobs.where((j) => j.isReady).length;
    final total = jobs.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('Batch #${batch.number}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: (batch.done ? Colors.green : theme.colorScheme.primary).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(batch.stageLabel,
              style: TextStyle(fontSize: 11, color: batch.done ? Colors.green : theme.colorScheme.primary)),
        ),
      ]),
      const SizedBox(height: 2),
      Text('${DateFormat.MMMd().add_jm().format(batch.createdAt)} · $ready of $total ready · sorted by ATS score',
          style: theme.textTheme.bodySmall),
      const SizedBox(height: 6),
      LinearProgressIndicator(value: total == 0 ? 0 : ready / total, minHeight: 4, borderRadius: BorderRadius.circular(4)),
    ]);
  }
}

class _SimpleHeader extends StatelessWidget {
  const _SimpleHeader({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ]);
}

/// Confirm, then delete a job (files + database). Returns true when deleted.
Future<bool> confirmDeleteJob(BuildContext context, Job job) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this job?'),
      content: Text('${job.title} @ ${job.company}\n\nIts tailored resume, cover letter and interview prep are deleted '
          'too, and the agents won\'t bring this posting back.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await Api.deleteJob(job.jobId);
    if (context.mounted) toast(context, 'Deleted ${job.jobId}');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, 'Could not delete: $e');
    return false;
  }
}

class JobCard extends StatelessWidget {
  const JobCard({super.key, required this.job});
  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go('/jobs/${job.jobId}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (job.batchRank != null) ...[
                CircleAvatar(
                  radius: 13,
                  backgroundColor: theme.colorScheme.primary,
                  child: Text('${job.batchRank}',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: theme.colorScheme.onPrimary)),
                ),
                const SizedBox(width: 6),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(job.jobId,
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace', color: theme.colorScheme.onPrimaryContainer)),
              ),
              const Spacer(),
              StatusChip(job.status),
              const SizedBox(width: 8),
            ]),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(job.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 2),
            Text('${job.company} · ${job.location}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.payments_outlined, size: 14),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(job.salaryText,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                      ),
                    ]),
                    const SizedBox(height: 2),
                    Text('${job.source} · ${ago(job.createdAt)}', style: theme.textTheme.labelSmall),
                  ]),
                ),
                ScoreBadge(label: 'ATS', score: job.tailoredAts ?? job.atsScore),
                const SizedBox(width: 6),
                ScoreBadge(label: 'Match', score: job.relevance),
              ]),
            ),
            const Divider(height: 12),
            Row(children: [
              FilterChip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(job.isApplied ? Icons.check_circle : Icons.radio_button_unchecked, size: 16),
                showCheckmark: false,
                label: Text(job.isApplied ? 'Applied' : 'Not applied'),
                selected: job.isApplied,
                onSelected: (v) async {
                  try {
                    await Api.setApplied(job, v);
                  } catch (e) {
                    if (context.mounted) toast(context, 'Could not update: $e');
                  }
                },
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Delete job',
                icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                onPressed: () => confirmDeleteJob(context, job),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
