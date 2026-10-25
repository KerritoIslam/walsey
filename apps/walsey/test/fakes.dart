import 'dart:async';
import 'dart:typed_data';

import 'package:walsey_led_ble/walsey_led_ble.dart';

/// Minimal central for app tests: no hardware, no plugin.
final class FakeCentral implements BleCentral {
  FakeCentral({this.gatt = const <GattServiceSnapshot>[]});

  final List<GattServiceSnapshot> gatt;
  final List<({String peripheralId, String value, bool withResponse})> writes =
      [];
  final List<({String uuid, bool enabled})> notifyStates = [];
  Object? writeError;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int startDiscoveryCalls = 0;

  final StreamController<BleAdapterState> _adapterStates =
      StreamController<BleAdapterState>.broadcast();
  final StreamController<ScannedPeripheral> _discovered =
      StreamController<ScannedPeripheral>.broadcast();
  final StreamController<BleConnectionEvent> _connections =
      StreamController<BleConnectionEvent>.broadcast();
  final StreamController<BleNotification> _notifications =
      StreamController<BleNotification>.broadcast();

  @override
  BleAdapterState get adapterState => BleAdapterState.poweredOn;

  @override
  Stream<BleAdapterState> get adapterStateChanges => _adapterStates.stream;

  @override
  Stream<ScannedPeripheral> get discovered => _discovered.stream;

  @override
  Stream<BleConnectionEvent> get connectionChanges => _connections.stream;

  @override
  Stream<BleNotification> get notifications => _notifications.stream;

  void emitDevice(ScannedPeripheral device) => _discovered.add(device);

  void emitConnection(BleConnectionEvent event) => _connections.add(event);

  void emitNotification(BleNotification notification) =>
      _notifications.add(notification);

  @override
  Future<void> ensureAuthorized() async {}

  @override
  Future<void> startDiscovery() async {
    startDiscoveryCalls++;
  }

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> connect(String peripheralId) async {
    connectCalls++;
  }

  @override
  Future<void> disconnect(String peripheralId) async {
    disconnectCalls++;
  }

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
      value: value
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(' '),
      withResponse: withResponse,
    ));
  }

  @override
  Future<void> setNotify(
    String peripheralId,
    String characteristicUuid, {
    required bool enabled,
  }) async {
    notifyStates.add((uuid: characteristicUuid, enabled: enabled));
  }
}

const GattServiceSnapshot leddmxGatt = GattServiceSnapshot(
  uuid: ffe0ServiceUuid,
  characteristics: [
    GattCharacteristicSnapshot(
      uuid: ffe1CharacteristicUuid,
      properties: [
        GattProperty.read,
        GattProperty.write,
        GattProperty.writeWithoutResponse,
        GattProperty.notify,
      ],
    ),
    GattCharacteristicSnapshot(
      uuid: ffe2CharacteristicUuid,
      properties: [GattProperty.notify],
    ),
  ],
);

const GattServiceSnapshot gattWithoutFfe1 = GattServiceSnapshot(
  uuid: ffe0ServiceUuid,
  characteristics: [],
);

const ScannedPeripheral supportedDevice = ScannedPeripheral(
  id: 'peripheral-1',
  name: 'LEDDMX-03-6B4A',
  rssi: -50,
  advertisedServiceUuids: [ffe0ServiceUuid],
);

const ScannedPeripheral unsupportedDevice = ScannedPeripheral(
  id: 'peripheral-2',
  name: 'LED DMX',
  rssi: -60,
  advertisedServiceUuids: [ffe0ServiceUuid],
);
