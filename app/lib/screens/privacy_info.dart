import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../widgets/common.dart';

/// Bump when the notice changes in a way people should agree to again (accounts.privacy_version).
const privacyVersion = 2;

/// Who processes what. Shown on the consent screen, the Privacy page and (in words) in web/privacy.html.
const aiProviders = [
  (
    'Google Gemini',
    'Gemini Flash and Flash-Lite',
    'Reads your resume and job descriptions to match and score jobs, tailor your resume, write cover letters and '
        'interview prep, and run the resume builder. This is the main AI.'
  ),
  ('Groq', 'Open models such as GPT-OSS', 'A backup when Gemini is busy, for the same tasks.'),
  ('OpenRouter', 'Open models chosen by the admin', 'A backup for the same tasks, only if the admin turns it on.'),
];

const otherServices = [
  ('Supabase', 'Database, file storage and sign-in. Your resume, settings, jobs and documents are stored here.'),
  ('GitHub Actions', 'Runs the agents that search, match and write.'),
  ('Cloudflare', 'Hosts the website.'),
  ('Job sites and company career pages', 'Searched with your target roles and locations only, never your resume.'),
];

class _Block extends StatelessWidget {
  const _Block(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          ...children,
        ]),
      );
}

/// The notice itself, used on the consent screen and the Privacy page.
class PrivacyNotice extends StatelessWidget {
  const PrivacyNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget p(String text) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Block('What Pounce stores', [
        p('Your name and email, your resume and cover letter, your job search settings, the jobs found for you, and '
            'what Pounce writes for them (tailored resumes, cover letters, interview prep and CV drafts).'),
      ]),
      _Block('AI providers that receive your data', [
        p('To do its work, Pounce sends your resume and the job descriptions to these AI providers:'),
        for (final (name, models, why) in aiProviders)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(Icons.auto_awesome_outlined, color: theme.colorScheme.primary),
              title: Text(name),
              subtitle: Text('$models. $why'),
            ),
          ),
        p('Some of these run on free tiers, which may use what is sent to improve their models. Nothing is sent to '
            'an AI provider that isn\'t listed here.'),
      ]),
      _Block('Other services', [
        for (final (name, what) in otherServices) p('• $name: $what'),
      ]),
      _Block('Who can see it', [
        p('In the app, only you. The person who runs Pounce owns the database and can technically access what is '
            'stored in it, and only looks when something needs fixing.'),
      ]),
      _Block('How long it is kept', [
        p('Jobs you never mark as Applied are deleted after 30 days, except the ones you add on the Custom page. '
            'Everything else stays until you delete it or your account.'),
      ]),
      _Block('Your choices', [
        p('Delete any job or draft at any time. Delete your whole account in Settings > Account: your files, jobs, '
            'drafts and settings are removed straight away. Questions: ${AppConfig.supportEmail}.'),
      ]),
    ]);
  }
}

/// Settings > Privacy and AI.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/settings')),
          title: const Text('Privacy and AI'),
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          PageBody(
            maxWidth: 760,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const PrivacyNotice(),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse('${AppConfig.siteUrl}/privacy.html')),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Full privacy policy'),
                ),
              ),
            ]),
          ),
        ]),
      );
}

/// Shown before first use and whenever the notice changes. Nothing is processed until this is accepted.
class PrivacyConsentScreen extends StatefulWidget {
  const PrivacyConsentScreen({super.key, required this.onAccept, required this.onSignOut, this.updated = false});
  final Future<void> Function() onAccept;
  final VoidCallback onSignOut;

  /// True when they agreed to an older version before.
  final bool updated;

  @override
  State<PrivacyConsentScreen> createState() => _PrivacyConsentScreenState();
}

class _PrivacyConsentScreenState extends State<PrivacyConsentScreen> {
  bool _agreed = false;
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onAccept();
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t save that: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          PageBody(
            maxWidth: 720,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Center(child: AppLogo(size: 64)),
              const SizedBox(height: 14),
              Text(widget.updated ? 'Our privacy notice has changed' : 'Your data and AI',
                  textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                widget.updated
                    ? 'Please read it again and agree to keep using Pounce.'
                    : 'Before Pounce reads your resume, here is exactly what it stores and which AI providers see it.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              const PrivacyNotice(),
              TextButton.icon(
                onPressed: () => launchUrl(Uri.parse('${AppConfig.siteUrl}/privacy.html')),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Read the full privacy policy'),
              ),
              const SizedBox(height: 8),
              Card(
                child: CheckboxListTile(
                  key: const Key('privacy_agree'),
                  value: _agreed,
                  onChanged: _busy ? null : (v) => setState(() => _agreed = v ?? false),
                  title: const Text('I agree to the privacy notice, including my resume and job details being sent '
                      'to the AI providers listed above.'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 14),
              FilledButton(
                onPressed: _agreed && !_busy ? _accept : null,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Agree and continue'),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: _busy ? null : widget.onSignOut, child: const Text('Not now, sign out')),
            ]),
          ),
        ]),
      ),
    );
  }
}
