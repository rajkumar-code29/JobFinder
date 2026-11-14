import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../resume/cv.dart';
import '../widgets/common.dart';

/// Resume builder home: start a CV (three ways) or a cover letter, and pick up saved drafts.
class ResumeBuilderScreen extends StatefulWidget {
  const ResumeBuilderScreen({super.key, this.drafts});

  /// Tests pass their own list.
  final Stream<List<Map<String, dynamic>>>? drafts;

  @override
  State<ResumeBuilderScreen> createState() => _ResumeBuilderScreenState();
}

class _ResumeBuilderScreenState extends State<ResumeBuilderScreen> {
  late final Stream<List<Map<String, dynamic>>> _drafts = widget.drafts ?? Api.draftsStream();
  bool _busy = false;

  Future<void> _start(String kind, Map<String, dynamic> data) async {
    setState(() => _busy = true);
    try {
      final id = await Api.createDraft(kind, kind == 'cv' ? 'Untitled CV' : 'Untitled cover letter', data);
      if (mounted) context.go('/resume-builder/${kind == 'cv' ? 'cv' : 'letter'}/$id');
    } catch (e) {
      if (mounted) toast(context, 'Could not start: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> draft) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this draft?'),
        content: Text('"${draft['title']}" will be gone for good. Files you already downloaded are not affected.'),
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
    if (ok != true) return;
    try {
      await Api.deleteDraft(draft['id'] as String);
    } catch (e) {
      if (mounted) toast(context, 'Could not delete: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Resume builder')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        PageBody(
          maxWidth: 980,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'Build a CV that follows UK careers guidance: one clean column, standard headings and evidence instead '
              'of buzzwords, so both tracking software and people can read it. Then write a cover letter from it.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            Wrap(spacing: 12, runSpacing: 12, children: [
              _StartCard(
                icon: Icons.description_outlined,
                title: 'Build a CV',
                text: 'For a part-time job, an internship, a graduate job or a professional role.',
                actions: [
                  _StartAction(Icons.auto_awesome_outlined, 'Build with AI',
                      'Answer questions, the AI writes it, you review each part', () => _start('cv', {'mode': 'ai'})),
                  _StartAction(Icons.edit_note, 'My own words',
                      'Answer questions, your words go in as typed', () => _start('cv', {'mode': 'own'})),
                  _StartAction(Icons.upload_file_outlined, 'Start from my resume',
                      'Read your current resume, then improve it', () => _start('cv', {'mode': 'existing'})),
                ],
                busy: _busy,
              ),
              _StartCard(
                icon: Icons.mail_outline,
                title: 'Write a cover letter',
                text: 'One page in UK letter format, built from your master resume or a CV you made here.',
                actions: [
                  _StartAction(Icons.edit_document, 'Start a cover letter', 'For a job advert or a speculative letter',
                      () => _start('letter', {})),
                ],
                busy: _busy,
              ),
            ]),
            const SizedBox(height: 22),
            Text('Your drafts', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: _drafts,
              builder: (context, snap) {
                if (snap.hasError) return ErrorView(snap.error!);
                if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
                final drafts = [...snap.data!]
                  ..sort((a, b) => s(b['updated_at']).compareTo(s(a['updated_at'])));
                if (drafts.isEmpty) {
                  return Text('Nothing yet. Drafts save as you go, so you can stop and come back.',
                      style: theme.textTheme.bodySmall);
                }
                return Card(
                  child: Column(children: [
                    for (final dr in drafts)
                      ListTile(
                        leading: Icon(dr['kind'] == 'cv' ? Icons.description_outlined : Icons.mail_outline),
                        title: Text(s(dr['title']).isEmpty ? 'Untitled' : s(dr['title'])),
                        subtitle: Text('${dr['kind'] == 'cv' ? 'CV' : 'Cover letter'} · edited '
                            '${DateTime.tryParse(s(dr['updated_at'])) == null ? '' : ago(DateTime.parse(s(dr['updated_at'])).toLocal())}'),
                        onTap: () => context.go('/resume-builder/${dr['kind'] == 'cv' ? 'cv' : 'letter'}/${dr['id']}'),
                        trailing: IconButton(
                          tooltip: 'Delete draft',
                          icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                          onPressed: () => _delete(dr),
                        ),
                      ),
                  ]),
                );
              },
            ),
            const SizedBox(height: 22),
            const _Tips(),
          ]),
        ),
      ]),
    );
  }
}

class _StartAction {
  const _StartAction(this.icon, this.label, this.hint, this.onTap);
  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;
}

class _StartCard extends StatelessWidget {
  const _StartCard({required this.icon, required this.title, required this.text, required this.actions, required this.busy});
  final IconData icon;
  final String title;
  final String text;
  final List<_StartAction> actions;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 476),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
            ]),
            const SizedBox(height: 4),
            Text(text, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            for (final a in actions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: !busy,
                leading: Icon(a.icon),
                title: Text(a.label),
                subtitle: Text(a.hint),
                trailing: const Icon(Icons.chevron_right),
                onTap: a.onTap,
              ),
          ]),
        ),
      ),
    );
  }
}

class _Tips extends StatelessWidget {
  const _Tips();

  static const _tips = [
    'Tailor it: use the job advert\'s own words for skills you really have.',
    'Give evidence: say where you showed a skill instead of just listing it.',
    'One or two full A4 pages, a clear font at 11pt or more, and no photo, tables or columns.',
    'Leave out your date of birth, and write "References available upon request" instead of listing referees.',
    'Send Word (.docx) to online application systems, and a PDF when you email it.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Good to know', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final t in _tips)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('•  '),
                Expanded(child: Text(t, style: theme.textTheme.bodySmall)),
              ]),
            ),
        ]),
      ),
    );
  }
}
