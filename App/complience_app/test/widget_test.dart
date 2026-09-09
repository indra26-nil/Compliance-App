import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:complience_app/home_page.dart';

void main() {
  testWidgets('HomePage shows capture and upload options',
      (WidgetTester tester) async {
    // Build our app's home page and trigger a frame.
    await tester.pumpWidget(
      const MaterialApp(home: HomePage()),
    );

    // Both main options should be visible.
    expect(find.text('Capture Photos'), findsOneWidget);
    expect(find.text('Upload Photos'), findsOneWidget);
  });
}