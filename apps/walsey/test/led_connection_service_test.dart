import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/connection/led_connection_service.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import 'fakes.dart';

void main() {
  late FakeCentral central;
  late LedConnectionService service;

  setUp(() {
    central = FakeCentral(gatt: const [leddmxGatt]);
    service = LedConnectionService(
      central: central,
      connectionTimeout: const Duration(seconds: 1),
      discoveryTimeout: const Duration(seconds: 1),
      disconnectTimeout: const Duration(seconds: 1),
    );
  });

  tearDown(() async {
    await service.dispose();
  });

  test('connecting validates GATT but sends no frame automatically', () async {
    await service.connect(supportedDevice);

    expect(service.current.phase, AppConnectionPhase.connected);
    expect(service.current.controlsAvailable, isTrue);
    expect(service.controls, isNotNull);
    expect(central.connectCalls, 1);
    expect(central.notifyStates.single.enabled, isTrue);
    expect(central.writes, isEmpty);
  });

  test('control API writes the filler power frame after an explicit call',
      () async {
    await service.connect(supportedDevice);

    final result = await service.controls!.setPower(on: false);

    expect(result, isA<CommandSent>());
    expect(central.writes.single.value, '7b 04 04 00 ff ff ff ff bf');
    expect(central.writes.single.withResponse, isTrue);
  });

  test('unsupported advertised name keeps the link but disables controls',
      () async {
    await service.connect(unsupportedDevice);

    expect(service.current.phase, AppConnectionPhase.connected);
    expect(service.controls, isNull);
    expect(service.current.controlsAvailable, isFalse);
    expect(service.current.controlsBlockedReason, isNotNull);
    expect(central.writes, isEmpty);
  });

  test('missing FFE1 fails validation, disconnects and sends nothing',
      () async {
    await service.dispose();
    central = FakeCentral(gatt: const [gattWithoutFfe1]);
    service = LedConnectionService(
      central: central,
      connectionTimeout: const Duration(seconds: 1),
      discoveryTimeout: const Duration(seconds: 1),
      disconnectTimeout: const Duration(seconds: 1),
    );

    await service.connect(supportedDevice);

    expect(service.current.phase, AppConnectionPhase.failed);
    expect(service.controls, isNull);
    expect(central.disconnectCalls, greaterThanOrEqualTo(1));
    expect(central.writes, isEmpty);
  });

  test('link loss drops controls and does not reconnect', () async {
    await service.connect(supportedDevice);
    central.emitConnection(
      const BleConnectionEvent(peripheralId: 'peripheral-1', connected: false),
    );
    await Future<void>.delayed(Duration.zero);

    expect(service.current.phase, AppConnectionPhase.failed);
    expect(service.controls, isNull);
    expect(central.connectCalls, 1);
  });

  test('scan is refused while connected', () async {
    await service.connect(supportedDevice);

    await service.startScan();

    expect(central.startDiscoveryCalls, 0);
    expect(service.current.phase, AppConnectionPhase.connected);
  });

  test('disconnect releases the link and clears controls', () async {
    await service.connect(supportedDevice);

    await service.disconnect();

    expect(service.current.phase, AppConnectionPhase.disconnected);
    expect(service.controls, isNull);
    expect(central.disconnectCalls, 1);
    expect(service.current.selected, isNull);
  });
}
