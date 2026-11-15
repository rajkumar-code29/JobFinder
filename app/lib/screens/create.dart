import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/common.dart';

/// The Create tab: a job you found yourself, or a CV / cover letter.
class CreateScreen extends StatelessWidget {
  const CreateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Create')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        PageBody(
          maxWidth: 980,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('What would you like to do?', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text('Add a job you found yourself, or put together a CV or cover letter.', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 18),
            LayoutBuilder(builder: (context, c) {
              final cards = [
                const _Option(
                  icon: Icons.post_add,
                  title: 'Add a custom job',
                  text: 'Paste the title and description of a job you found. Pounce scores it against your resume and '
                      'can tailor your resume, write a cover letter and prepare you for the interview.',
                  cta: 'Add a job',
                  route: '/custom',
                ),
                const _Option(
                  icon: Icons.description_outlined,
                  title: 'Build a CV or cover letter',
                  text: 'Answer a few questions and get a CV in the format UK employers expect, with AI or in your own '
                      'words, or start from your current resume. Then write a cover letter from it.',
                  cta: 'Open the builder',
                  route: '/resume-builder',
                ),
              ];
              if (c.maxWidth < 640) {
                return Column(children: [cards[0], const SizedBox(height: 12), cards[1]]);
              }
              return IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[1]),
                ]),
              );
            }),
          ]),
        ),
      ]),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.title, required this.text, required this.cta, required this.route});
  final IconData icon;
  final String title;
  final String text;
  final String cta;
  final String route;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.go(route),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(16)),
              child: Icon(icon, size: 30, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(text, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () => context.go(route),
              icon: const Icon(Icons.arrow_forward),
              label: Text(cta),
            ),
          ]),
        ),
      ),
    );
  }
}
