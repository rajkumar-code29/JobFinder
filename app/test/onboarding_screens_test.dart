import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/screens/help.dart';
import 'package:jobfinder/models.dart';
import 'package:jobfinder/screens/guide.dart';
import 'package:jobfinder/screens/privacy_info.dart';

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

  testWidgets('consent needs the box ticked and lists the AI providers', (tester) async {
    var accepted = 0;
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: PrivacyConsentScreen(onAccept: () async => accepted++, onSignOut: () {})));
    expect(find.text('Google Gemini'), findsOneWidget);
    expect(find.text('Groq'), findsOneWidget);
    final button = find.widgetWithText(FilledButton, 'Agree and continue');
    await tester.ensureVisible(button);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.ensureVisible(find.byKey(const Key('privacy_agree')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('privacy_agree')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(accepted, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guide ticks off what is done', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(
        home: GuideScreen(status: SetupStatus(resumeDocx: true, locations: true, roles: false, jobBoards: false, hasRun: false))));
    await tester.pumpAndSettle();
    expect(find.text('Upload your resume'), findsOneWidget);
    expect(find.text('2 of 4 set up'), findsOneWidget);
    expect(find.textContaining('delete your account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
