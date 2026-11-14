import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/resume/cv.dart';
import 'package:jobfinder/resume/docx.dart';
import 'package:jobfinder/resume/pdf.dart';
import 'package:jobfinder/screens/cv_builder.dart';
import 'package:jobfinder/screens/letter_builder.dart';

final answers = <String, dynamic>{
  'contact': {
    'name': 'Sam Allen',
    'email': 'sam@example.com',
    'phone': '07700 900123',
    'location': 'Glasgow',
    'availability': 'evenings and weekends',
  },
  'about': 'First-year English and History student looking for weekend retail work.',
  'education': [
    {'qualification': 'BA (Hons) English and History', 'institution': 'University of Strathclyde', 'start': 'Sept 2025', 'end': ''},
    {'qualification': 'Advanced Highers: English (A), History (A)', 'institution': 'Shawlands Academy', 'start': '2019', 'end': '2025'},
  ],
  'experience': [
    {'kind': 'other', 'title': 'Barista', 'organisation': 'Lazy Summer Café', 'start': 'Jun 2025', 'end': 'Aug 2025',
      'details': '- Served customers in a busy café\n- Handled complaints calmly'},
    {'kind': 'volunteering', 'title': 'Shop Assistant', 'organisation': 'Charity shop', 'start': 'Feb 2023', 'end': 'Jul 2023',
      'details': 'Used the till & card machine'},
  ],
  'skills': {'soft': 'Teamwork: worked shifts with a team of six\nCommunication: dealt with customer queries', 'it': 'Excel, Word'},
  'achievements': 'School Prefect 2024\nBronze Duke of Edinburgh Award',
  'interests': '',
};

void main() {
  screenTests();

  test('part-time layout puts work first and adds availability', () {
    final specs = sectionsToBuild('part_time', answers, ai: false, role: '');
    expect(specs.map((s) => s.key), [
      'profile', 'experience_relevant', 'volunteering', 'education', 'achievements', 'tech_skills', 'references'
    ]);
    expect(contactLine(answers, 'part_time').last, 'Available: evenings and weekends');
    expect(contactLine(answers, 'chronological').any((c) => c.startsWith('Available')), isFalse);
  });

  test('own words keeps the answers as typed', () {
    final doc = buildDoc(answers: answers, type: 'part_time', sections: {}, ai: false, role: '');
    final work = doc.sections.firstWhere((s) => s.key == 'experience_relevant');
    expect(work.heading, 'Work Experience');
    expect(work.entries.single.dates, 'Jun 2025 – Aug 2025');
    expect(work.entries.single.bullets, ['Served customers in a busy café', 'Handled complaints calmly']);
    final edu = doc.sections.firstWhere((s) => s.key == 'education');
    expect(edu.entries.first.dates, 'Sept 2025 – Present');
    expect(doc.sections.last.paragraphs, [referencesText]);
    final skills = ownWords(layoutFor('skills').firstWhere((s) => s.key == 'skills'), answers);
    expect(skills.groups.map((g) => g.label), ['Teamwork', 'Communication']);
  });

  test('generated sections replace own words, AI headings are kept', () {
    final doc = buildDoc(answers: answers, type: 'chronological', ai: true, role: 'Retail assistant', sections: {
      'experience_other': {
        'heading': 'Retail Experience',
        'entries': [
          {'title': 'Barista', 'org': 'Lazy Summer Café', 'dates': 'Jun 2025 – Aug 2025', 'bullets': ['Served up to 200 customers a day.']}
        ]
      },
    });
    final other = doc.sections.firstWhere((s) => s.key == 'experience_other');
    expect(other.heading, 'Retail Experience');
    expect(other.entries.single.bullets.single, 'Served up to 200 customers a day.');
    expect(doc.text, contains('RETAIL EXPERIENCE'));
  });

  test('cover letter follows the sincerely/faithfully rule', () {
    final parts = {'opening': 'I am applying.', 'motivation': 'Why.', 'skills': 'One.\n\nTwo.', 'closing': 'Thanks.'};
    final named = buildLetter({'recipient_name': 'Ms Smith', 'company': 'Acme', 'your_name': 'Sam'}, parts,
        today: DateTime(2026, 11, 14));
    expect(named.greeting, 'Dear Ms Smith,');
    expect(named.signOff, 'Yours sincerely,');
    expect(named.paragraphs.length, 5);
    expect(named.date, '14th November 2026');
    final general = buildLetter({'company': 'Acme', 'company_address': '1 Road, London'}, parts, today: DateTime(2026, 11, 2));
    expect(general.greeting, 'Dear Hiring Manager,');
    expect(general.signOff, 'Yours faithfully,');
    expect(general.recipient, ['Recruitment Team', 'Acme', '1 Road', 'London']);
    expect([ukDate(DateTime(2026, 1, 1)), ukDate(DateTime(2026, 1, 12)), ukDate(DateTime(2026, 1, 23))],
        ['1st January 2026', '12th January 2026', '23rd January 2026']);
  });

  test('docx is a valid package with the text and bullets', () {
    final doc = buildDoc(answers: answers, type: 'part_time', sections: {}, ai: false, role: '');
    final bytes = cvDocx(doc);
    final zip = ZipDecoder().decodeBytes(bytes);
    expect(zip.files.map((f) => f.name), containsAll(['[Content_Types].xml', 'word/document.xml', 'word/numbering.xml']));
    final xml = utf8.decode(zip.findFile('word/document.xml')!.content);
    expect(xml, contains('Lazy Summer Café'));
    expect(xml, contains('Used the till &amp; card machine'));
    expect(xml, contains('<w:numId w:val="1"/>'));
    expect(xml, isNot(contains('<w:tbl>'))); // no tables
    final out = Platform.environment['CV_OUT'];
    if (out != null) {
      File('$out/cv.docx').writeAsBytesSync(bytes);
      final letter = buildLetter({'company': 'Acme', 'your_name': 'Sam Allen', 'your_address': '10 The Street, Glasgow'},
          {'opening': 'I am applying.', 'motivation': 'Why.', 'skills': 'Skills.', 'closing': 'Thanks.'}, today: DateTime(2026, 11, 14));
      File('$out/letter.docx').writeAsBytesSync(letterDocx(letter));
    }
  });

  test('pdf renders unicode text and fits a part-time CV on one page', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final doc = buildDoc(answers: answers, type: 'part_time', sections: {}, ai: false, role: '');
    final (bytes, pages) = await cvPdf(doc);
    expect(utf8.decode(bytes.sublist(0, 5), allowMalformed: true), '%PDF-');
    expect(pages, 1);
    final letter = await letterPdf(buildLetter({'company': 'Acme', 'your_name': 'Zoë Ł’Neill'},
        {'opening': '“Quotes” – dashes…', 'motivation': 'x', 'skills': 'y', 'closing': 'z'}, today: DateTime(2026, 11, 14)));
    expect(letter.length, greaterThan(1000));
    final out = Platform.environment['CV_OUT'];
    if (out != null) File('$out/cv.pdf').writeAsBytesSync(bytes);
  });
}

Map<String, dynamic> _draft(String mode, int step, {Map<String, dynamic> sections = const {}}) => {
      'mode': mode,
      'target': 'part_time',
      'role': 'Retail assistant',
      'step': step,
      'answers': jsonDecode(jsonEncode(answers)),
      'sections': sections,
    };

void screenTests() {
  for (final size in const [Size(375, 812), Size(1280, 900)]) {
    for (final step in [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
      testWidgets('cv builder step ${step + 1} lays out at ${size.width.toInt()} wide', (tester) async {
        tester.view.physicalSize = size * 2;
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(home: CvBuilderScreen(draftId: 'x', testData: _draft('own', step))));
        await tester.pumpAndSettle();
        expect(find.text('${step + 1}. ${['Start', 'Contact', 'About you', 'Education', 'Experience', 'Skills', 'Projects', 'More', 'Review'][step]}'),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('review shows the paper with edit buttons, and AI drafts offer regenerate', (tester) async {
    tester.view.physicalSize = const Size(375, 812) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: CvBuilderScreen(draftId: 'x', testData: _draft('own', 8))));
    await tester.pumpAndSettle();
    expect(find.text('Sam Allen'), findsOneWidget);
    expect(find.text('Work Experience'), findsOneWidget);
    expect(find.text('Edit'), findsWidgets);
    expect(find.text('Regenerate'), findsNothing);

    final generated = {
      for (final k in ['profile', 'experience_relevant', 'volunteering', 'education', 'achievements', 'tech_skills'])
        k: {'paragraphs': ['Written for $k.']}
    };
    await tester.pumpWidget(MaterialApp(home: CvBuilderScreen(key: const ValueKey('y'), draftId: 'y', testData: _draft('ai', 8, sections: generated))));
    await tester.pumpAndSettle();
    expect(find.text('Regenerate'), findsWidgets);
    expect(find.text('Use my words'), findsWidgets);
    expect(find.text('Written for profile.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download step counts pages', (tester) async {
    tester.view.physicalSize = const Size(375, 812) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: CvBuilderScreen(draftId: 'x', testData: _draft('own', 9))));
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
    await tester.pumpAndSettle();
    expect(find.text('1 page on A4'), findsOneWidget);
    expect(find.text('Word (.docx)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover letter asks for a resume first, then shows the letter', (tester) async {
    tester.view.physicalSize = const Size(375, 812) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: LetterBuilderScreen(draftId: 'l', testData: {'inputs': {}})));
    await tester.pumpAndSettle();
    expect(find.text('Upload your resume first'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
        home: LetterBuilderScreen(key: const ValueKey('m'), draftId: 'm', testData: {
      'test_master': true,
      'inputs': {'job_title': 'Analyst', 'company': 'Acme', 'recipient_name': 'Ms Smith', 'your_name': 'Sam Allen'},
      'parts': {'opening': 'I am applying for the Analyst role.', 'motivation': 'M.', 'skills': 'S.', 'closing': 'C.'},
    })));
    await tester.pumpAndSettle();
    expect(find.text('Upload your resume first'), findsNothing);
    await tester.scrollUntilVisible(find.text('Yours sincerely,'), 400, scrollable: find.byType(Scrollable).first);
    expect(find.text('Dear Ms Smith,'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
