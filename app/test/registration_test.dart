import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/registration.dart';
import 'package:jobfinder/screens/register.dart';
import 'package:jobfinder/widgets/access_gate.dart';

void main() {
  test('names: letters only, any alphabet', () {
    for (final ok in ['Raj', 'José', 'Zoë', 'राज', 'Ng']) {
      expect(validateName(ok, 'first name'), isNull, reason: ok);
    }
    for (final bad in ['', '  ', 'R2D2', 'Mary Ann', "O'Brien", 'Anne-Marie', 'Raj!', 'Raj.']) {
      expect(validateName(bad, 'first name'), isNotNull, reason: bad);
    }
    expect(validateName('A' * 51, 'last name'), isNotNull);
  });

  test('email', () {
    for (final ok in ['a@b.co', 'raj.gk+jobs@example.com']) {
      expect(validateEmail(ok), isNull, reason: ok);
    }
    for (final bad in ['', 'raj', 'raj@', 'raj@example', 'raj @example.com', 'raj@example.c', 'a@@b.com']) {
      expect(validateEmail(bad), isNotNull, reason: bad);
    }
  });

  test('metadata carries just the name', () {
    const r = Registration(firstName: 'A', lastName: 'B', email: 'a@b.co', password: 'x');
    expect(r.metadata, {'first_name': 'A', 'last_name': 'B'});
  });

  test('access status: only blocked accounts are kept out', () {
    expect(accessStatus(null), 'approved');
    expect(accessStatus({'user_id': 'x'}), 'approved');
    expect(accessStatus({'status': 'approved'}), 'approved');
    expect(accessStatus({'status': 'rejected'}), 'rejected');
  });

  Future<List<Registration>> pump(WidgetTester tester) async {
    final sent = <Registration>[];
    await tester.binding.setSurfaceSize(const Size(500, 1400));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: RegisterForm(onSubmit: (r) async {
        sent.add(r);
        return null;
      }))),
    ));
    return sent;
  }

  testWidgets('form blocks bad input', (tester) async {
    final sent = await pump(tester);
    await tester.enterText(find.byKey(const Key('first_name')), 'R2D2');
    await tester.enterText(find.byKey(const Key('email')), 'not-an-email');
    await tester.enterText(find.byKey(const Key('password')), 'short');
    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();
    expect(find.text('Letters only: no spaces, numbers or symbols'), findsOneWidget);
    expect(find.text('Enter a valid email, e.g. name@example.com'), findsOneWidget);
    expect(find.text('Use at least 8 characters'), findsOneWidget);
    expect(find.byKey(const Key('phone')), findsNothing);
    expect(sent, isEmpty);
  });

  testWidgets('valid form submits trimmed values', (tester) async {
    final sent = await pump(tester);
    await tester.enterText(find.byKey(const Key('first_name')), ' Raj ');
    await tester.enterText(find.byKey(const Key('last_name')), 'Kumar');
    await tester.enterText(find.byKey(const Key('email')), 'raj@example.com');
    await tester.enterText(find.byKey(const Key('password')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirm')), 'secret123');
    await tester.tap(find.byKey(const Key('register')));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    final r = sent.single;
    expect([r.firstName, r.lastName, r.email, r.password], ['Raj', 'Kumar', 'raj@example.com', 'secret123']);
  });
}
