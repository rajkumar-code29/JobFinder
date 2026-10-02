import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';
import '../models.dart';

/// Setup checklist on Home.
class GettingStartedCard extends StatefulWidget {
  const GettingStartedCard({super.key});

  @override
  State<GettingStartedCard> createState() => _GettingStartedCardState();
}

class _GettingStartedCardState extends State<GettingStartedCard> {
  late Future<SetupStatus> _future = Api.setupStatus();

  @override
  void initState() {
    super.initState();
    _future.then((s) {
      if (!s.privacyAccepted && mounted) WidgetsBinding.instance.addPostFrameCallback((_) => _privacy());
    }).catchError((_) {});
  }

  Future<void> _privacy() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PrivacyNoticeDialog(),
    );
    if (ok == true) {
      try {
        await Api.acceptPrivacy();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<SetupStatus>(
        future: _future,
        builder: (context, snap) {
          final s = snap.data;
          if (s == null) return const SizedBox.shrink();
          final theme = Theme.of(context);
          if (s.ready && s.hasRun && s.waitingOn == null) return const SizedBox.shrink();
          final steps = [
            (s.resumeDocx, 'Upload your resume as a Word file (.docx)', 'Settings > Parent documents. Add the PDF and your master cover letter too.', '/settings'),
            (s.aiKey, 'Add your free Gemini API key', 'Settings > API keys > Add API key. The dialog shows how to get one and can test it.', '/settings'),
            (s.locations, 'Choose where to look', 'Settings > Locations: countries, or any city/region.', '/settings'),
            (s.roles, 'Say what roles you want', 'Settings > Target roles - or leave empty and the agents use the titles from your resume.', '/settings'),
          ];
          final optional = [
            (s.extraKeys, 'Optional: Adzuna / JSearch / Groq keys', 'More job sources and faster rating.', '/settings'),
            (s.jobBoards, 'Optional: companies you like', 'Settings > Job boards: paste their careers-page link.', '/settings'),
          ];
          final done = steps.where((x) => x.$1).length;
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.rocket_launch_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(s.ready ? 'You\'re set up' : 'Getting started · $done of ${steps.length} done',
                        style: theme.textTheme.titleMedium)),
                    TextButton(onPressed: () => context.go('/help'), child: const Text('How it works')),
                  ]),
                  if (s.waitingOn != null && !s.ready) ...[
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                      child: Text('Your agents are waiting: ${s.waitingOn}', style: theme.textTheme.bodySmall),
                    ),
                  ],
                  if (s.ready && !s.hasRun)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Everything the agents need is in place. They start on the next hourly run and build '
                          'your first batch of up to 20 jobs - tailored resumes appear over the following hours.',
                          style: theme.textTheme.bodySmall),
                    ),
                  const SizedBox(height: 6),
                  for (final (ok, title, hint, route) in [...steps, if (s.ready) ...optional])
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked, color: ok ? Colors.green : theme.colorScheme.outline),
                      title: Text(title, style: TextStyle(decoration: ok ? TextDecoration.lineThrough : null)),
                      subtitle: ok ? null : Text(hint),
                      trailing: ok ? null : const Icon(Icons.chevron_right),
                      onTap: ok ? null : () async {
                        await context.push(route);
                        if (mounted) setState(() => _future = Api.setupStatus());
                      },
                    ),
                ]),
              ),
            ),
          );
        },
      );
}

class PrivacyNoticeDialog extends StatelessWidget {
  const PrivacyNoticeDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Before you start: your data'),
        content: const SingleChildScrollView(
          child: Text(
            'What Pounce stores: your resume and cover letter, your settings and API keys, the jobs it finds '
            'and what it writes for them (tailored resumes, cover letters, interview prep).\n\n'
            'Who can see it: in the app, only you. The person who runs Pounce (the admin) owns the database '
            'and can technically access everything stored in it. API keys can\'t be read back in the app.\n\n'
            'AI providers: to tailor your resume and prepare you, your resume and the job descriptions are sent to '
            'the AI provider of your key (e.g. Google Gemini, Groq). Free tiers may use this data to improve their '
            'models - see each provider\'s terms.\n\n'
            'Your control: delete any job at any time (its files go too). Jobs you never mark as Applied are '
            'deleted automatically after 30 days. Ask the admin to delete your account and everything in it.',
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('I understand'))],
      );
}
