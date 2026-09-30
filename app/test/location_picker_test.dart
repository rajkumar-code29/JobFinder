import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/countries.dart';
import 'package:jobfinder/screens/settings.dart';

Future<String?> pick(WidgetTester tester, Future<void> Function() interact, {List<String> existing = const []}) async {
  String? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async => result = await showDialog<String>(
          context: context,
          builder: (_) => LocationPicker(existing: existing),
        ),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await interact();
  await tester.pumpAndSettle();
  return result;
}

void main() {
  test('normalizeLocation', () {
    expect(normalizeLocation('UK'), 'gb');
    expect(normalizeLocation('india'), 'in');
    expect(normalizeLocation('Dubai'), 'ae');
    expect(normalizeLocation(' Bavaria '), 'Bavaria');
    expect(locationLabel('kr'), 'South Korea');
    expect(locationLabel('Bavaria'), 'Bavaria');
    expect(countryNames.length, greaterThan(240));
  });

  testWidgets('searching an alias finds the country', (tester) async {
    final r = await pick(tester, () async {
      await tester.enterText(find.byType(TextField), 'uk');
      await tester.pumpAndSettle();
      expect(find.text('United Kingdom'), findsOneWidget);
      expect(find.textContaining('as a custom location'), findsNothing);
      await tester.tap(find.text('United Kingdom'));
    });
    expect(r, 'gb');
  });

  testWidgets('unknown text can be added as a custom location', (tester) async {
    final r = await pick(tester, () async {
      await tester.enterText(find.byType(TextField), 'Bavaria');
      await tester.pumpAndSettle();
      expect(find.text('Add "Bavaria" as a custom location'), findsOneWidget);
      await tester.tap(find.text('Add "Bavaria" as a custom location'));
    });
    expect(r, 'Bavaria');
  });

  testWidgets('already chosen countries are hidden', (tester) async {
    await pick(tester, () async {
      await tester.enterText(find.byType(TextField), 'india');
      await tester.pumpAndSettle();
      expect(find.text('India'), findsNothing);
      expect(find.text('British Indian Ocean Territory'), findsOneWidget);
    }, existing: ['in']);
  });
}
