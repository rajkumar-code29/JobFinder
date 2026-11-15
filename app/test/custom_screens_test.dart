import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/models.dart';
import 'package:jobfinder/screens/custom.dart';
import 'package:jobfinder/screens/resume_builder.dart';
import 'package:jobfinder/widgets/shell.dart';

void main() {
  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(375 * 3, 812 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  testWidgets('resume builder home lists the ways to start and the drafts', (tester) async {
    await phone(tester);
    await tester.pumpWidget(MaterialApp(
        home: ResumeBuilderScreen(
            drafts: Stream.value([
      {'id': 'a', 'kind': 'cv', 'title': 'Retail assistant CV', 'updated_at': '2026-11-14T10:00:00Z'},
      {'id': 'b', 'kind': 'letter', 'title': 'Cover letter at Acme', 'updated_at': '2026-11-14T11:00:00Z'},
    ]))));
    await tester.pumpAndSettle();
    expect(find.text('Resume builder'), findsOneWidget);
    for (final t in ['Build with AI', 'My own words', 'Start from my resume', 'Start a cover letter']) {
      expect(find.text(t), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.text('Retail assistant CV'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Cover letter at Acme'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tabs fit on a phone, and custom jobs and the builder highlight Create', (tester) async {
    await phone(tester);
    for (final (location, index) in [
      ('/custom/JF-20261114-ABCDE', 3),
      ('/resume-builder/cv/x', 3),
      ('/guide', 4),
      ('/credits', 4),
      ('/matches/JF-1', 2),
      ('/jobs/p/12', 1),
      ('/', 0),
    ]) {
      await tester.pumpWidget(MaterialApp(home: AppShell(location: location, child: const SizedBox())));
      for (final label in ['Home', 'Jobs', 'Matches', 'Create', 'Settings']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, index, reason: location);
    }
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(375, 812), Size(1280, 900)]) {
    testWidgets('custom page lays out at ${size.width.toInt()} wide', (tester) async {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: CustomJobsScreen(jobs: Stream.value(_sample.map(Job.new).toList()))));
      await tester.pumpAndSettle();
      expect(find.text('Custom Jobs'), findsOneWidget);
      expect(find.text('Batch number'), findsOneWidget);
      expect(find.text('3'), findsOneWidget); // next batch prefilled
      expect(find.textContaining('3 custom jobs'), findsOneWidget);
      expect(find.textContaining('1 need attention'), findsOneWidget);
      expect(find.text('Tailored resume and cover letter'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Batch 1'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Batch 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('custom form asks for the title and the description', (tester) async {
    await tester.pumpWidget(MaterialApp(home: CustomJobsScreen(jobs: Stream.value(const []))));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('How it works'), findsOneWidget);
    await tester.ensureVisible(find.text('Add job'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add job'));
    await tester.pumpAndSettle();
    expect(find.text('Add the job title'), findsOneWidget);
    expect(find.text('Paste the full job description'), findsOneWidget);
  });

  test('custom jobs link to the Custom page', () {
    final custom = Job({'job_id': 'JF-1', 'source': 'custom', 'custom_batch': 3});
    final found = Job({'job_id': 'JF-2', 'source': 'adzuna'});
    expect(custom.isCustom, isTrue);
    expect(custom.customBatch, 3);
    expect(custom.basePath, '/custom');
    expect(found.basePath, '/matches');
  });
}

Map<String, dynamic> _job(String id, int batch, String status, {int? ats, int? odds, String company = 'NA'}) => {
      'id': id,
      'job_id': id,
      'source': 'custom',
      'custom_batch': batch,
      'status': status,
      'title': 'Senior Platform Engineer, Developer Experience',
      'company': company,
      'tailored_ats_score': ats,
      'shortlist_probability': odds,
      'attempts': status == 'error' ? 3 : 0,
      'created_at': DateTime(2026, 11, 14, 9, batch).toUtc().toIso8601String(),
    };

final _sample = [
  _job('JF-20261114-AAAAA', 1, 'ready', ats: 96, odds: 72, company: 'Acme'),
  _job('JF-20261114-BBBBB', 1, 'error'),
  _job('JF-20261114-CCCCC', 2, 'new'),
];

