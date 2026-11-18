import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/connection/led_connection_service.dart';
import 'package:walsey/control/led_control_service.dart';
import 'package:walsey/design/theme.dart';
import 'package:walsey/features/studio/led_studio_page.dart';
import 'package:walsey/state/app_settings.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

final class FakeLedTransport implements LedTransport {
  final List<Uint8List> writes = [];
  final StreamController<Uint8List> _notifications =
      StreamController<Uint8List>.broadcast();

  @override
  Future<void> write(Uint8List frame, {required bool withResponse}) async {
    writes.add(Uint8List.fromList(frame));
  }

  @override
  Stream<Uint8List> get notifications => _notifications.stream;

  @override
  Future<void> close() => _notifications.close();
}

String hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Real driver + service over an in-memory transport.
///
/// Created inside each test body on purpose: the write queue chains futures, and
/// a driver built in `setUp` belongs to a different async zone, so queued writes
/// would never complete inside the widget test's fake clock.
final class _StudioHarness {
  _StudioHarness() {
    driver = LeddmxDriver(
      transport: transport,
      minGap: Duration.zero,
      delay: (_) async {},
    );
    driver.attach(resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);
    controls = LedControlService(
      driver: driver,
      layout: LeddmxLayout.filler,
      log: (_) {},
    );
  }

  final FakeLedTransport transport = FakeLedTransport();
  late final LeddmxDriver driver;
  late final LedControlService controls;
  final AppSettingsService settings = AppSettingsService.inMemory();

  Future<void> dispose() async {
    controls.dispose();
    await driver.dispose();
    await transport.close();
    settings.dispose();
  }
}

void main() {
  Future<void> pumpStudio(
    WidgetTester tester,
    _StudioHarness harness, {
    bool withControls = true,
  }) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWalseyTheme(),
        home: Scaffold(
          body: LedStudioPage(
            state: AppConnectionState(
              phase: AppConnectionPhase.connected,
              variant: resolveVariant('LEDDMX-03-6B4A') as SupportedVariant,
            ),
            controls: withControls ? harness.controls : null,
            settings: harness.settings,
            onNavigate: (_) {},
            compact: false,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> unmount(
    WidgetTester tester,
    _StudioHarness harness,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(harness.dispose);
  }

  testWidgets('apply colour writes the selected frame and never claims LEDs',
      (WidgetTester tester) async {
    final harness = _StudioHarness();
    await pumpStudio(tester, harness);

    await tester.enterText(find.byType(TextField).at(0), '#FF0000');
    await tester.pump();

    await tester.ensureVisible(find.text('Apply colour'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply colour'));
    await tester.pumpAndSettle();

    expect(harness.transport.writes, hasLength(1));
    expect(hex(harness.transport.writes.single), '7b ff 07 ff 00 00 00 ff bf');
    expect(find.textContaining('BLE write completed'), findsOneWidget);
    expect(find.textContaining('not confirmed'), findsOneWidget);

    await unmount(tester, harness);
  });

  testWidgets('handshake is an explicit tap and disappears once sent',
      (WidgetTester tester) async {
    final harness = _StudioHarness();
    await pumpStudio(tester, harness);

    expect(find.text('Handshake not sent'), findsOneWidget);
    expect(harness.transport.writes, isEmpty);

    await tester.ensureVisible(find.text('Send handshake'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send handshake'));
    await tester.pumpAndSettle();

    expect(harness.transport.writes, hasLength(1));
    final frame = harness.transport.writes.single;
    expect(frame, hasLength(9));
    expect(frame.first, 0x2a);
    expect(frame.last, 0xaf);
    expect(find.text('Handshake not sent'), findsNothing);
    expect(
      find.textContaining('Handshake: BLE write completed'),
      findsOneWidget,
    );

    await unmount(tester, harness);
  });

  testWidgets('without a controller every send control is disabled',
      (WidgetTester tester) async {
    final harness = _StudioHarness();
    await pumpStudio(tester, harness, withControls: false);

    expect(find.text('No controller connected'), findsWidgets);
    expect(
      find.text('Connect a documented LEDDMX controller to send commands.'),
      findsOneWidget,
    );

    final applyColour = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Apply colour'),
    );
    expect(applyColour.onPressed, isNull);

    final powerOn = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Power on'),
    );
    expect(powerOn.onPressed, isNull);

    final powerOff = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Power off'),
    );
    expect(powerOff.onPressed, isNull);

    expect(harness.transport.writes, isEmpty);

    await unmount(tester, harness);
  });
}
