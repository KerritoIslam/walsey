import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

/// Fake central used by the transport tests. It records writes and lets tests
/// inject failures.
final class FakeCentral implements BleCentral {
  FakeCentral({this.gatt = const []});

  final List<GattServiceSnapshot> gatt;

  final List<({String peripheralId, String uuid, Uint8List value, bool withResponse})>
      writes = [];
  final List<({String uuid, bool enabled})> notifyStates = [];

  Object? writeError;
  Object? notifyError;

  @override
  BleAdapterState get adapterState => BleAdapterState.poweredOn;

  @override
  Stream<BleAdapterState> get adapterStateChanges =>
      const Stream<BleAdapterState>.empty();

  @override
  Stream<ScannedPeripheral> get discovered =>
      const Stream<ScannedPeripheral>.empty();

  @override
  Stream<BleConnectionEvent> get connectionChanges =>
      const Stream<BleConnectionEvent>.empty();

  final List<BleNotification> _notifications = [];
  final List<void Function(BleNotification)> _listeners = [];

  @override
  Stream<BleNotification> get notifications => Stream<BleNotification>.multi(
        (controller) {
          void listener(BleNotification notification) =>
              controller.add(notification);
          _listeners.add(listener);
          for (final pending in _notifications) {
            controller.add(pending);
          }
          controller.onCancel = () => _listeners.remove(listener);
        },
      );

  void emit(BleNotification notification) {
    _notifications.add(notification);
    for (final listener in List.of(_listeners)) {
      listener(notification);
    }
  }

  @override
  Future<void> ensureAuthorized() async {}

  @override
  Future<void> startDiscovery() async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> connect(String peripheralId) async {}

  @override
  Future<void> disconnect(String peripheralId) async {}

  @override
  Future<List<GattServiceSnapshot>> discoverGatt(String peripheralId) async =>
      gatt;

  @override
  Future<void> writeCharacteristic(
    String peripheralId,
    String characteristicUuid,
    Uint8List value, {
    required bool withResponse,
  }) async {
    final error = writeError;
    if (error != null) throw error;
    writes.add((
      peripheralId: peripheralId,
      uuid: characteristicUuid,
      value: Uint8List.fromList(value),
      withResponse: withResponse,
    ));
  }

  @override
  Future<void> setNotify(
    String peripheralId,
    String characteristicUuid, {
    required bool enabled,
  }) async {
    final error = notifyError;
    if (error != null) throw error;
    notifyStates.add((uuid: characteristicUuid, enabled: enabled));
  }
}

void main() {
  const ffe1 = ffe1CharacteristicUuid;

  test('writes a complete 9-byte frame through FFE1', () async {
    final central = FakeCentral();
    final transport =
        PluginLedTransport(central: central, peripheralId: 'p1');

    final frame = Uint8List.fromList(
        [0x7b, 0xff, 0x07, 0xff, 0x00, 0x00, 0x00, 0xff, 0xbf]);
    await transport.write(frame, withResponse: true);

    expect(central.writes.single.peripheralId, 'p1');
    expect(central.writes.single.uuid, ffe1);
    expect(central.writes.single.withResponse, isTrue);
    expect(central.writes.single.value, frame);
  });

  test('accepts withoutResponse writes and reports the mode', () async {
    final central = FakeCentral();
    final transport =
        PluginLedTransport(central: central, peripheralId: 'p1');

    await transport.write(
      Uint8List.fromList([0x2a, 0x05, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xaf]),
      withResponse: false,
    );

    expect(central.writes.single.withResponse, isFalse);
  });

  test('refuses a value that is not a 9-byte frame', () async {
    final central = FakeCentral();
    final transport =
        PluginLedTransport(central: central, peripheralId: 'p1');

    await expectLater(
      transport.write(Uint8List.fromList([0x7b, 0xbf]), withResponse: true),
      throwsA(isA<LedTransportException>()),
    );
    expect(central.writes, isEmpty);
  });

  test('propagates platform write failures', () async {
    final central = FakeCentral()..writeError = StateError('gatt failure');
    final transport =
        PluginLedTransport(central: central, peripheralId: 'p1');

    await expectLater(
      transport.write(
        Uint8List.fromList(
            [0x7b, 0x04, 0x04, 0x00, 0xff, 0xff, 0xff, 0xff, 0xbf]),
        withResponse: true,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('notifications are filtered to this peripheral and FFE1', () async {
    final central = FakeCentral();
    final transport =
        PluginLedTransport(central: central, peripheralId: 'p1');

    final received = <Uint8List>[];
    final subscription = transport.notifications.listen(received.add);

    central.emit(BleNotification(
      peripheralId: 'other',
      characteristicUuid: ffe1,
      value: Uint8List.fromList([1]),
    ));
    central.emit(BleNotification(
      peripheralId: 'p1',
      characteristicUuid: ffe2CharacteristicUuid,
      value: Uint8List.fromList([2]),
    ));
    central.emit(BleNotification(
      peripheralId: 'p1',
      characteristicUuid: ffe1,
      value: Uint8List.fromList([3]),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(received.map((value) => value.single), [3]);
    await subscription.cancel();
  });

  test('enableNotifications writes CCCD state without sending a frame',
      () async {
    final central = FakeCentral();
    final transport =
        PluginLedTransport(central: central, peripheralId: 'p1');

    await transport.enableNotifications();

    expect(central.notifyStates.single, (uuid: ffe1, enabled: true));
    expect(central.writes, isEmpty);
  });

  test('close disables notifications and disconnects', () async {
    final central = FakeCentral();
    final transport =
        PluginLedTransport(central: central, peripheralId: 'p1');

    await transport.close();

    expect(central.notifyStates.single, (uuid: ffe1, enabled: false));
  });
}
