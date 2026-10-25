import 'package:flutter_test/flutter_test.dart';

import 'package:ble_probe/main.dart';

void main() {
  testWidgets('renders the read-only BLE probe', (WidgetTester tester) async {
    await tester.pumpWidget(const ProbeApp());

    expect(find.text('Walsey BLE probe (read-only)'), findsOneWidget);
    expect(find.text('Start scan'), findsOneWidget);
    expect(find.text('Only names starting "LED"'), findsOneWidget);
  }, skip: true);
}
