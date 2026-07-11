import 'package:flutter_test/flutter_test.dart';

import 'package:my_first_app/main.dart';

void main() {
  testWidgets('Demo home page renders all DevTools cases', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('DevTools demo cases'), findsOneWidget);
    expect(find.text('Performance case'), findsOneWidget);
    expect(find.text('CPU usage case'), findsOneWidget);
    expect(find.text('Memory leak case'), findsOneWidget);
  });
}
