import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/models.dart';
import 'package:jobfinder/registration.dart';
import 'package:jobfinder/screens/board.dart';
import 'package:jobfinder/screens/credits.dart';
import 'package:jobfinder/screens/register.dart';
import 'package:jobfinder/widgets/credits.dart';

Map<String, dynamic> _posting(int id, String title, {int? match, String? jobId}) => {
      'id': id,
      'source': 'adzuna',
      'title': title,
      'company': 'Acme',
      'location': 'London, UK',
      'remote': id.isEven ? 'Remote' : 'NA',
      'employment_type': 'full_time',
      'salary_text': 'NA',
      'salary_min': 40000,
      'salary_max': 50000,
      'salary_currency': 'GBP',
      'first_seen': DateTime.now().subtract(Duration(hours: id)).toUtc().toIso8601String(),
      'my_match': match,
      'my_job_id': jobId,
      'total': 45,
    };

void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(375 * 2, 812 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  testWidgets('board searches with filters and loads more as you scroll', (tester) async {
    phone(tester);
    final calls = <(BoardFilters, int)>[];
    Future<List<Map<String, dynamic>>> search(BoardFilters f, int offset) async {
      calls.add((f, offset));
      final n = offset == 0 ? 30 : 15;
      return [for (var i = 0; i < n; i++) _posting(offset + i + 1, 'Data Analyst ${offset + i + 1}', match: i == 0 ? 91 : null, jobId: i == 1 ? 'JF-1' : null)];
    }

    await tester.pumpWidget(MaterialApp(home: BoardScreen(search: search)));
    await tester.pumpAndSettle();
    expect(find.text('45 jobs · from job sites and company career pages, kept for 30 days'), findsOneWidget);
    expect(find.text('Data Analyst 1'), findsOneWidget);
    expect(find.textContaining('In your matches', skipOffstage: false), findsWidgets);
    expect(find.text('91%'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'python');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(calls.last.$1.query, 'python');
    expect(calls.last.$1.sort, 'relevance');

    await tester.tap(find.text('Date posted'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Past week'));
    await tester.pumpAndSettle();
    expect(calls.last.$1.days, 7);
    expect(find.text('Clear filters'), findsOneWidget);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -6000));
    await tester.pumpAndSettle();
    expect(calls.last.$2, 30);
    expect(tester.takeException(), isNull);
  });

  testWidgets('work panel shows choices, progress and failures without charging', (tester) async {
    phone(tester);
    final job = Job({'job_id': 'JF-1', 'title': 'Analyst', 'company': 'Acme', 'source': 'adzuna', 'status': 'scored', 'files': {}});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: JobWorkPanel(job: job, requests: const [])))));
    await tester.pumpAndSettle();
    expect(find.text('Both · 2 credits'), findsOneWidget);
    expect(find.text('1 credit'), findsNWidgets(2));

    final reqs = [
      JobRequest({'id': 1, 'job_id': 'JF-1', 'kind': 'tailor', 'cost': 1, 'status': 'running', 'created_at': '2026-11-15T10:00:00Z'}),
      JobRequest({'id': 2, 'job_id': 'JF-1', 'kind': 'interview', 'cost': 1, 'status': 'failed', 'error_code': 'E_AI_BUSY', 'created_at': '2026-11-15T10:00:00Z'}),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: JobWorkPanel(key: UniqueKey(), job: job, requests: reqs)))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Working on it · 1 credit held'), findsOneWidget);
    expect(find.textContaining('E_AI_BUSY'), findsOneWidget);
    expect(find.textContaining('No credits were used'), findsOneWidget);
    expect(find.text('Both · 2 credits'), findsNothing);

    final done = Job({'job_id': 'JF-2', 'title': 'Analyst', 'company': 'Acme', 'source': 'adzuna', 'status': 'ready',
      'files': {'resume_docx': 'a', 'cover_letter_docx': 'b', 'interview': 'c'}});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: JobWorkPanel(key: UniqueKey(), job: done, requests: const [])))));
    await tester.pumpAndSettle();
    expect(find.text('Practise'), findsOneWidget);
    expect(find.text('1 credit'), findsNothing);
  });

  testWidgets('invite card offers every way to share', (tester) async {
    phone(tester);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: InviteCard(code: 'ABCD2345', rewarded: 2)))));
    expect(find.text('ABCD2345'), findsOneWidget);
    for (final label in ['WhatsApp', 'Email', 'SMS', 'Telegram', 'LinkedIn', 'X', 'Copy link', 'More']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.textContaining('2 friends have joined'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('referral codes are tidied and checked', () {
    expect(normalizeReferralCode(' abcd-2345 '), 'ABCD2345');
    expect(validateReferralCode(''), isNull);
    expect(validateReferralCode('abc'), isNotNull);
    expect(const Registration(firstName: 'A', lastName: 'B', email: 'a@b.co', password: 'x', referralCode: 'ABCD2345').metadata['referral_code'],
        'ABCD2345');
    expect(const Registration(firstName: 'A', lastName: 'B', email: 'a@b.co', password: 'x').metadata.containsKey('referral_code'), isFalse);
  });

  testWidgets('invite links fill in the code on sign-up', (tester) async {
    final sent = <Registration>[];
    await tester.binding.setSurfaceSize(const Size(500, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: RegisterForm(referral: 'abcd2345', onSubmit: (r) async {
      sent.add(r);
      return null;
    })))));
    expect(find.text('ABCD2345'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('first_name')), 'Sam');
    await tester.enterText(find.byKey(const Key('last_name')), 'Allen');
    await tester.enterText(find.byKey(const Key('email')), 'sam@example.com');
    await tester.enterText(find.byKey(const Key('password')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirm')), 'secret123');
    await tester.tap(find.byKey(const Key('register')));
    await tester.pumpAndSettle();
    expect(sent.single.referralCode, 'ABCD2345');
  });
}
