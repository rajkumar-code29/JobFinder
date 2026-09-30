import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../countries.dart';
import '../models.dart';
import '../widgets/common.dart';
import 'jobs.dart' show confirmDeleteJob;

class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({super.key, required this.jobId});
  final String jobId;

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  late final Stream<Job?> _stream = Api.jobStream(widget.jobId);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Job?>(
      stream: _stream,
      builder: (context, snap) {
        final job = snap.data;
        return Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/jobs')),
            title: Text(widget.jobId, style: const TextStyle(fontFamily: 'monospace')),
            actions: [
              if (job != null && !isNa(job.url))
                IconButton(
                  tooltip: 'Open original posting',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => launchUrl(Uri.parse(job.url), mode: LaunchMode.externalApplication),
                ),
              if (job != null)
                IconButton(
                  tooltip: 'Delete job',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (await confirmDeleteJob(context, job) && context.mounted) context.go('/jobs');
                  },
                ),
            ],
          ),
          body: snap.hasError
              ? ErrorView(snap.error!)
              : job == null
                  ? Center(child: snap.hasData ? const Text('Job not found') : const CircularProgressIndicator())
                  : _Body(job: job),
          bottomNavigationBar: job == null ? null : _ActionBar(job: job),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.job});
  final Job job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      PageBody(
        maxWidth: 900,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            StatusChip(job.status),
            if (job.batchRank != null) ...[
              const SizedBox(width: 8),
              Text('Rank #${job.batchRank} in its batch', style: theme.textTheme.bodySmall),
            ],
            const Spacer(),
            Text('Found ${ago(job.createdAt)}', style: theme.textTheme.bodySmall),
          ]),
          const SizedBox(height: 8),
          Text(job.title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(job.company, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(height: 16),
          Wrap(spacing: 10, runSpacing: 10, children: [
            ScoreBadge(label: 'Resume match', score: job.relevance, big: true),
            ScoreBadge(label: 'ATS (parent)', score: job.atsScore, big: true),
            ScoreBadge(label: 'ATS (tailored)', score: job.tailoredAts, big: true),
            ScoreBadge(label: 'Shortlist odds', score: job.shortlist, big: true),
          ]),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                _Info(Icons.place_outlined, 'Location', '${job.location}${isNa(job.country) ? '' : ' (${locationLabel(job.country)})'}'),
                _Info(Icons.payments_outlined, 'Salary', job.salaryText,
                    sub: isNa(job.salarySource) ? null : job.salarySource.startsWith('estimate') ? 'Estimated (${job.salarySource.split(':').last})' : 'From job posting'),
                _Info(Icons.home_work_outlined, 'Remote', job.remote),
                _Info(Icons.badge_outlined, 'Type', job.employmentType),
                _Info(Icons.event_outlined, 'Posted', job.postedAt),
                _Info(Icons.hub_outlined, 'Source', job.source),
                if (!isNa(job.relevanceReason)) _Info(Icons.psychology_outlined, 'Why it matches', job.relevanceReason),
                if (job.appliedAt != null)
                  _Info(Icons.send, 'Applied', '${ago(job.appliedAt!)} with ${job.appliedWith ?? 'resume'}'),
              ]),
            ),
          ),
          if (job.error != null && job.status != 'ready' && job.status != 'applied') ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: const Text('Agent error'),
                subtitle: Text(job.error!),
              ),
            ),
          ],
          if (job.addedSkills.isNotEmpty) ...[
            const SizedBox(height: 12),
            AddedSkillsCard(skills: job.addedSkills),
          ],
          if (job.files['report_md'] != null) ...[
            const SizedBox(height: 12),
            _ReportCard(path: job.files['report_md']!),
          ],
          if (job.files.isNotEmpty) ...[
            const SizedBox(height: 12),
            _FilesCard(job: job),
          ],
          const SizedBox(height: 12),
          _JdCard(text: job.description),
          const SizedBox(height: 24),
        ]),
      ),
    ]);
  }
}

class _Info extends StatelessWidget {
  const _Info(this.icon, this.label, this.value, {this.sub});
  final IconData icon;
  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        leading: Icon(icon, size: 20),
        title: Text(label, style: Theme.of(context).textTheme.labelMedium),
        subtitle: Text(sub == null ? value : '$value\n$sub', style: Theme.of(context).textTheme.bodyMedium),
      );
}

class AddedSkillsCard extends StatelessWidget {
  const AddedSkillsCard({super.key, required this.skills});
  final List<AddedSkill> skills;

  @override
  Widget build(BuildContext context) => Card(
        color: Colors.amber.withValues(alpha: 0.14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amber),
              SizedBox(width: 8),
              Expanded(child: Text('Adjacent skills added — review before applying', style: TextStyle(fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 8),
            for (final s in skills)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${s.skill}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: s.why),
                ])),
              ),
            const SizedBox(height: 8),
            Text('Be ready to talk about these in an interview, or remove them from the resume.',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
}

class _ReportCard extends StatefulWidget {
  const _ReportCard({required this.path});
  final String path;

  @override
  State<_ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends State<_ReportCard> {
  late Future<String> _future = Api.readText(widget.path);

  @override
  void didUpdateWidget(covariant _ReportCard old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _future = Api.readText(widget.path);
  }

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: const Icon(Icons.insights_outlined),
          title: const Text('Suggestions report'),
          subtitle: const Text('ATS analysis, gaps and what was changed'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            FutureBuilder<String>(
              future: _future,
              builder: (context, snap) => snap.hasError
                  ? Text('Could not load report: ${snap.error}')
                  : !snap.hasData
                      ? const LinearProgressIndicator()
                      : MarkdownBody(data: snap.data!, selectable: true),
            ),
          ],
        ),
      );
}

class _FilesCard extends StatelessWidget {
  const _FilesCard({required this.job});
  final Job job;

  static const _labels = {
    'resume_docx': ('Tailored resume (.docx)', Icons.description_outlined),
    'resume_pdf': ('Tailored resume (.pdf)', Icons.picture_as_pdf_outlined),
    'cover_letter_docx': ('Cover letter (.docx)', Icons.mail_outline),
    'cover_letter_pdf': ('Cover letter (.pdf)', Icons.mark_email_read_outlined),
    'report_md': ('Suggestions report (.md)', Icons.insights_outlined),
    'interview': ('Interview pack (.json)', Icons.quiz_outlined),
    'job': ('Job details (.json)', Icons.data_object),
  };

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Job folder'),
          subtitle: Text('jobs/${job.jobId}/', style: const TextStyle(fontFamily: 'monospace')),
          children: [
            for (final e in _labels.entries)
              if (job.files[e.key] != null)
                ListTile(
                  dense: true,
                  leading: Icon(e.value.$2),
                  title: Text(e.value.$1),
                  subtitle: Text(job.files[e.key]!.split('/').last),
                  trailing: const Icon(Icons.download_outlined),
                  onTap: () => Api.openFile(job.files[e.key]!, download: !job.files[e.key]!.endsWith('.pdf')),
                ),
          ],
        ),
      );
}

class _JdCard extends StatefulWidget {
  const _JdCard({required this.text});
  final String text;

  @override
  State<_JdCard> createState() => _JdCardState();
}

class _JdCardState extends State<_JdCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final long = widget.text.length > 1200;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Job description', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(_expanded || !long ? widget.text : '${widget.text.substring(0, 1200)}…'),
          if (long)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? 'Show less' : 'Show full description'),
            ),
        ]),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.job});
  final Job job;

  @override
  Widget build(BuildContext context) {
    final hasInterview = job.files['interview'] != null;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
        child: PageBody(
          maxWidth: 900,
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: hasInterview ? () => context.go('/jobs/${job.jobId}/interview') : null,
                icon: const Icon(Icons.school_outlined),
                label: Text(hasInterview ? 'Prepare for interview' : 'Interview prep pending'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => ApplySheet(job: job),
                ),
                icon: Icon(job.status == 'applied' ? Icons.check : Icons.send),
                label: Text(job.status == 'applied' ? 'Applied' : 'Apply'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Pick which resume to send (tailored from this job's folder, or the parent), grab the cover letter,
/// open the application page, then mark the job as applied.
class ApplySheet extends StatefulWidget {
  const ApplySheet({super.key, required this.job});
  final Job job;

  @override
  State<ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends State<ApplySheet> {
  late final Future<List<String>> _parent = Api.parentFiles('resume');
  String? _choice; // storage path; parent files are prefixed with "parent:"

  List<(String, String)> _options(List<String> parent) => [
        if (widget.job.files['resume_pdf'] != null) ('Tailored for this job · PDF', widget.job.files['resume_pdf']!),
        if (widget.job.files['resume_docx'] != null) ('Tailored for this job · Word', widget.job.files['resume_docx']!),
        for (final p in parent) ('Parent resume · ${p.split('.').last.toUpperCase()}', 'parent:$p'),
      ];

  Future<void> _download(String choice) => choice.startsWith('parent:')
      ? Api.openFile(choice.substring(7), bucket: Api.parentBucket)
      : Api.openFile(choice);

  Future<void> _openApplication() async {
    final url = widget.job.applyUrl;
    if (isNa(url)) {
      toast(context, 'No application link was captured for this job');
      return;
    }
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!mounted) return;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Did you submit the application?'),
        content: const Text('Mark this job as applied so it moves to your Applied list.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, applied')),
        ],
      ),
    );
    if (done == true) {
      final label = _choice?.split('/').last ?? 'resume';
      await Api.markApplied(widget.job.jobId, label);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: FutureBuilder<List<String>>(
          future: _parent,
          builder: (context, snap) {
            final options = _options(snap.data ?? []);
            _choice ??= options.isEmpty ? null : options.first.$2;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Text('Apply to ${job.company}', style: theme.textTheme.titleLarge),
              Text(job.title, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              if (job.addedSkills.isNotEmpty) ...[
                AddedSkillsCard(skills: job.addedSkills),
                const SizedBox(height: 12),
              ],
              Text('1. Choose your resume', style: theme.textTheme.titleSmall),
              if (!snap.hasData) const LinearProgressIndicator(),
              RadioGroup<String>(
                groupValue: _choice,
                onChanged: (v) => setState(() => _choice = v),
                child: Column(children: [
                  for (final (label, path) in options)
                    RadioListTile<String>(
                      value: path,
                      title: Text(label),
                      subtitle: Text(path.split('/').last),
                      secondary: IconButton(
                        tooltip: 'Download',
                        icon: const Icon(Icons.download_outlined),
                        onPressed: () => _download(path),
                      ),
                    ),
                ]),
              ),
              if (job.files['cover_letter_docx'] != null || job.files['cover_letter_pdf'] != null) ...[
                const SizedBox(height: 8),
                Text('2. Cover letter', style: theme.textTheme.titleSmall),
                Wrap(spacing: 8, children: [
                  if (job.files['cover_letter_pdf'] != null)
                    ActionChip(
                      avatar: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                      label: const Text('Cover Letter.pdf'),
                      onPressed: () => Api.openFile(job.files['cover_letter_pdf']!),
                    ),
                  if (job.files['cover_letter_docx'] != null)
                    ActionChip(
                      avatar: const Icon(Icons.description_outlined, size: 18),
                      label: const Text('Cover Letter.docx'),
                      onPressed: () => Api.openFile(job.files['cover_letter_docx']!),
                    ),
                ]),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _choice == null ? null : () => _download(_choice!),
                icon: const Icon(Icons.download),
                label: const Text('Download selected resume'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _openApplication,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open application page'),
              ),
              if (job.status == 'applied') ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    await Api.unmarkApplied(job.jobId);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Undo "applied"'),
                ),
              ],
            ]);
          },
        ),
      ),
    );
  }
}
