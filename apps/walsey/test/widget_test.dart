import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/connection/led_connection_service.dart';
import 'package:walsey/ui/home_page.dart';

import 'fakes.dart';

void main() {
  testWidgets('shell shows connection actions and the diagnostic log',
      (WidgetTester tester) async {
    // The service subscribes to BLE streams; create/dispose it in the real
    // async zone so flutter_test does not wait on fake-async stream futures.
    late LedConnectionService service;
    await tester.runAsync(() async {
      service = LedConnectionService(central: FakeCentral());
    });

    await tester.pumpWidget(
      MaterialApp(home: WalseyHomePage(service: service)),
    );

    expect(find.text('Walsey'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Controls'), findsOneWidget);
    expect(find.text('Hardware test'), findsOneWidget);
    expect(find.text('Start scan'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.textContaining('Walsey app initialized'), findsOneWidget);
    expect(
      find.textContaining('no frames are sent until you press a command'),
      findsOneWidget,
    );

    // Unmount before disposing the service so listeners are gone first.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.dispose);
  });
}
