import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// "Set up Pounce": shown after someone first agrees to the privacy notice, and from Home and Settings.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key, this.status});

  /// Tests pass their own status.
  final SetupStatus? status;

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideStep {
  const _GuideStep(this.icon, this.title, this.text, {this.done, this.actions = const []});
  final IconData icon;
  final String title;
  final String text;
  final bool? done; // null: nothing to tick off
  final List<(String, String)> actions; // (label, route)
}

class _GuideScreenState extends State<GuideScreen> {
  late final Future<SetupStatus?> _status = widget.status != null ? Future.value(widget.status) : _load();

  Future<SetupStatus?> _load() async {
    try {
      return await Api.setupStatus();
    } catch (_) {
      return null;
    }
  }

  List<_GuideStep> _steps(SetupStatus? s) => [
        const _GuideStep(Icons.verified_user_outlined, 'Verify your email and agree to the privacy notice',
            'Done. You can read the notice again any time in Settings > Account > Privacy and AI.',
            done: true),
        _GuideStep(
          Icons.description_outlined,
          'Upload your resume',
          'Settings > Parent documents. Upload it as a Word file (.docx): the agents read it to find jobs that fit '
              'you, and tailor a copy of it for each job. Add the PDF and a master cover letter too. No resume yet? '
              'Build one under Create, then tap "Set as my master resume".',
          done: s?.resumeDocx,
          actions: const [('Upload in Settings', '/settings'), ('Build a CV', '/resume-builder')],
        ),
        _GuideStep(
          Icons.travel_explore_outlined,
          'Tell the agents where and what',
          'Settings > Locations: countries, or any city you type. Settings > Target roles: the jobs you want. Leave '
              'roles empty and the agents use the job titles from your resume.',
          done: s == null ? null : s.locations && s.roles,
          actions: const [('Open Settings', '/settings')],
        ),
        _GuideStep(
          Icons.apartment_outlined,
          'Optional: companies you like',
          'Settings > Job boards: paste the careers page of any company. Boards on Greenhouse, Lever, Ashby, Workable, '
              'Workday and SmartRecruiters are read in full.',
          done: s?.jobBoards,
          actions: const [('Add companies', '/settings')],
        ),
        const _GuideStep(
          Icons.bolt_outlined,
          'Let the agents work',
          'Every hour they search job sites and company boards, keep the jobs that fit your resume and score each one. '
              'They appear under Jobs, best match first.',
          actions: [('Open Jobs', '/jobs')],
        ),
        const _GuideStep(
          Icons.send_outlined,
          'Apply',
          'Open a job to see how well you match, the tailored resume and cover letter, and interview prep. Tap Apply to '
              'open the application page, then mark it applied so you can keep track.',
        ),
        const _GuideStep(
          Icons.add_circle_outline,
          'Your own finds and your CV',
          'Create: paste a job you found yourself to get the same treatment, or build a CV or cover letter step by '
              'step, with AI or in your own words.',
          actions: [('Open Create', '/create')],
        ),
        const _GuideStep(
          Icons.palette_outlined,
          'Make it yours',
          'Settings > Appearance: light or dark mode, and a colour theme.',
          actions: [('Appearance', '/settings')],
        ),
        const _GuideStep(
          Icons.privacy_tip_outlined,
          'Your privacy and your account',
          'Settings > Account shows what Pounce stores and which AI providers process your resume (Google Gemini, '
              'with Groq and OpenRouter as backups). You can change your password there, or delete your account and '
              'everything in it at any time.',
          actions: [('Privacy and AI', '/privacy-info')],
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/')),
        title: const Text('Setup guide'),
      ),
      body: FutureBuilder<SetupStatus?>(
        future: _status,
        builder: (context, snap) {
          final steps = _steps(snap.data);
          final done = steps.where((x) => x.done == true).length;
          final total = steps.where((x) => x.done != null).length;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            PageBody(
              maxWidth: 760,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(gradient: brandGradient(theme.colorScheme), borderRadius: BorderRadius.circular(22)),
                  child: Row(children: [
                    const AppLogo(size: 56),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Welcome to Pounce',
                            style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
                        const SizedBox(height: 4),
                        Text('A few minutes of setup and your agents start finding jobs that fit you.',
                            style: TextStyle(color: theme.colorScheme.onPrimaryContainer)),
                        if (snap.hasData) ...[
                          const SizedBox(height: 10),
                          LinearProgressIndicator(value: total == 0 ? 0 : done / total, minHeight: 6, borderRadius: BorderRadius.circular(6)),
                          const SizedBox(height: 4),
                          Text('$done of $total set up',
                              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
                        ],
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(height: 20),
                for (final (i, step) in steps.indexed) _StepTile(number: i + 1, step: step, last: i == steps.length - 1),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.number, required this.step, required this.last});
  final int number;
  final _GuideStep step;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = step.done == true;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 40,
          child: Column(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: done ? scheme.primary : scheme.surfaceContainerHighest,
              child: done
                  ? Icon(Icons.check, size: 18, color: scheme.onPrimary)
                  : Text('$number', style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
            ),
            if (!last) Expanded(child: Container(width: 2, color: scheme.outlineVariant)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(step.icon, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(step.title, style: theme.textTheme.titleMedium)),
                  ]),
                  const SizedBox(height: 6),
                  Text(step.text),
                  if (step.actions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      for (final (label, route) in step.actions)
                        TextButton.icon(
                          onPressed: () => context.push(route),
                          icon: const Icon(Icons.arrow_forward, size: 18),
                          label: Text(label),
                        ),
                    ]),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
