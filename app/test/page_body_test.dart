import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobfinder/widgets/common.dart';

void main() {
  testWidgets('PageBody in a bottom bar only takes its content height', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: const [Text('JOB BODY')]),
        bottomNavigationBar: Container(
          key: const Key('bar'),
          padding: const EdgeInsets.all(10),
          child: PageBody(child: Row(children: [Expanded(child: FilledButton(onPressed: () {}, child: const Text('Apply')))])),
        ),
      ),
    ));
    expect(tester.getSize(find.byKey(const Key('bar'))).height, lessThan(100));
    expect(find.text('JOB BODY').hitTestable(), findsOneWidget);
  });

  testWidgets('PageBody around a scroll view still fills the page', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PageBody(child: ListView(key: const Key('list'), children: const [Text('x')]))),
    ));
    expect(tester.getSize(find.byKey(const Key('list'))).height, 600);
  });
}
