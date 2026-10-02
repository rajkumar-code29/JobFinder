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

  test('phone is normalised to digits with an optional +', () {
    expect(normalizePhone('+91 98765-43210'), '+919876543210');
    expect(normalizePhone('(555) 123 4567'), '5551234567');
    expect(normalizePhone('12345'), isNull);
    expect(normalizePhone('+1 555 CALL NOW'), isNull);
    expect(normalizePhone('1234567890123456'), isNull);
    expect(validatePhone(''), isNotNull);
  });

  test('metadata only carries a platform when the app is wanted', () {
    const yes = Registration(firstName: 'A', lastName: 'B', email: 'a@b.co', phone: '+1555123456', password: 'x',
        wantsMobileApp: true, mobilePlatform: 'android');
    const no = Registration(firstName: 'A', lastName: 'B', email: 'a@b.co', phone: '+1555123456', password: 'x',
        wantsMobileApp: false, mobilePlatform: 'ios');
    expect(yes.metadata['mobile_platform'], 'android');
    expect(no.metadata.containsKey('mobile_platform'), isFalse);
  });

  test('access status: rows before migration 008 count as approved', () {
    expect(accessStatus(null), 'pending');
    expect(accessStatus({'user_id': 'x'}), 'approved');
    expect(accessStatus({'status': 'pending'}), 'pending');
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

  testWidgets('form blocks bad input and asks about the mobile app', (tester) async {
    final sent = await pump(tester);
    await tester.enterText(find.byKey(const Key('first_name')), 'R2D2');
    await tester.enterText(find.byKey(const Key('email')), 'not-an-email');
    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();
    expect(find.text('Letters only: no spaces, numbers or symbols'), findsOneWidget);
    expect(find.text('Enter a valid email, e.g. name@example.com'), findsOneWidget);
    expect(find.text('Choose yes or no'), findsOneWidget);
    expect(sent, isEmpty);

    // the platform question only appears after "Yes", and is then required
    expect(find.byKey(const Key('ios')), findsNothing);
    await tester.tap(find.byKey(const Key('app_yes')));
    await tester.pump();
    expect(find.byKey(const Key('ios')), findsOneWidget);
    expect(find.text('Choose iPhone or Android'), findsOneWidget);
  });

  testWidgets('valid form submits normalised values', (tester) async {
    final sent = await pump(tester);
    await tester.enterText(find.byKey(const Key('first_name')), ' Raj ');
    await tester.enterText(find.byKey(const Key('last_name')), 'Kumar');
    await tester.enterText(find.byKey(const Key('email')), 'raj@example.com');
    await tester.enterText(find.byKey(const Key('phone')), '+91 98765 43210');
    await tester.enterText(find.byKey(const Key('password')), 'secret123');
    await tester.enterText(find.byKey(const Key('confirm')), 'secret123');
    await tester.tap(find.byKey(const Key('app_yes')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('android')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('register')));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    final r = sent.single;
    expect([r.firstName, r.lastName, r.email, r.phone, r.wantsMobileApp, r.mobilePlatform],
        ['Raj', 'Kumar', 'raj@example.com', '+919876543210', true, 'android']);
  });
}
