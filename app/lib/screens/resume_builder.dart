import 'package:flutter/material.dart';

import '../widgets/common.dart';

class ResumeBuilderScreen extends StatelessWidget {
  const ResumeBuilderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Resume builder')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: PageBody(
            maxWidth: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.description_outlined, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Coming soon',
                    style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
              ),
              const SizedBox(height: 16),
              Text('Build your resume here',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                'Put together a resume from scratch or rework the one you have, section by section, and use it '
                'as the parent resume for your agents. This page is still being built.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
