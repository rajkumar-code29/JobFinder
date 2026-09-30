import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/screens/help.dart';
import 'package:jobfinder/widgets/onboarding.dart';

void main() {
  testWidgets('help page renders all sections', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    await tester.pumpAndSettle();
    for (final heading in ['Getting started', 'How a run works', 'The screens']) {
      expect(find.textContaining(heading), findsWidgets);
    }
    await tester.scrollUntilVisible(find.textContaining('Limits and common messages'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('No AI provider key available'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('privacy notice returns true when acknowledged', (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () async => result = await showDialog<bool>(context: context, builder: (_) => const PrivacyNoticeDialog()),
      child: const Text('open'),
    ))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('deleted automatically after 30 days'), findsOneWidget);
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
