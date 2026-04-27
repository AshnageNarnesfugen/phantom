import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:phantom_messenger/main.dart';

void main() {
  testWidgets('PhantomApp renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const PhantomApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
