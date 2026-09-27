import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/common.dart';

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key, this.initialStatus});
  final String? initialStatus;

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  late String? _status = widget.initialStatus;
  String _query = '';
  late final Stream<List<Job>> _stream = Api.jobsStream();

  static const _filters = [null, 'ready', 'new', 'scored', 'tailored', 'applied', 'error'];

  bool _match(Job j) {
    if (_status != null && j.status != _status) return false;
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return j.jobId.toLowerCase().contains(q) ||
        j.title.toLowerCase().contains(q) ||
        j.company.toLowerCase().contains(q) ||
        j.location.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Jobs')),
      body: StreamBuilder<List<Job>>(
        stream: _stream,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(snap.error!);
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final all = snap.data!;
          final jobs = all.where(_match).toList();
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
                    for (final f in _filters)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(
                              '${f == null ? 'All' : statusLabels[f]} (${f == null ? all.length : all.where((j) => j.status == f).length})'),
                          selected: _status == f,
                          onSelected: (_) => setState(() => _status = f),
                        ),
                      ),
                  ]),
                ),
              ),
              if (jobs.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('No jobs here yet – the agents scan every hour.')),
                ),
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverLayoutBuilder(builder: (context, c) {
                  final cols = (c.crossAxisExtent / 360).floor().clamp(1, 3);
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 196,
                    ),
                    delegate: SliverChildBuilderDelegate((_, i) => JobCard(job: jobs[i]), childCount: jobs.length),
                  );
                }),
              ),
            ]),
          );
        },
      ),
    );
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
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
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
            ]),
            const SizedBox(height: 10),
            Text(job.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('${job.company} · ${job.location}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
            const Spacer(),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
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
          ]),
        ),
      ),
    );
  }
}
