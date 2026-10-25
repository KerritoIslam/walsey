import 'dart:async';
import 'dart:typed_data';

import 'gatt_profile.dart';

/// Platform Bluetooth adapter state, mirrored without plugin types.
enum BleAdapterState {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}

/// One scan result, deduplicated by the consumer using [id].
final class ScannedPeripheral {
  const ScannedPeripheral({
    required this.id,
    required this.name,
    required this.rssi,
    required this.advertisedServiceUuids,
  });

  /// Platform identifier (UUID/address), stable for the life of a scan.
  final String id;
  final String? name;
  final int rssi;
  final List<String> advertisedServiceUuids;
}

/// Link state change reported by the platform.
final class BleConnectionEvent {
  const BleConnectionEvent({
    required this.peripheralId,
    required this.connected,
  });

  final String peripheralId;
  final bool connected;
}

/// One characteristic notification.
final class BleNotification {
  const BleNotification({
    required this.peripheralId,
    required this.characteristicUuid,
    required this.value,
  });

  final String peripheralId;
  final String characteristicUuid;
  final Uint8List value;
}

class BleException implements Exception {
  BleException(this.message);

  final String message;

  @override
  String toString() => 'BleException: $message';
}

final class BleAuthorizationException extends BleException {
  BleAuthorizationException(super.message);
}

/// Port over the BLE central role.
///
/// Stage 2 adds `writeCharacteristic` and notifications (both supported by the
/// target unit's FFE1). The protocol encoders stay in `walsey_led_core`; this
/// port only moves bytes.
abstract interface class BleCentral {
  BleAdapterState get adapterState;

  Stream<BleAdapterState> get adapterStateChanges;

  /// Deduplicated by the consumer; repeated advertisements for the same
  /// peripheral are normal.
  Stream<ScannedPeripheral> get discovered;

  Stream<BleConnectionEvent> get connectionChanges;

  /// Values received from the controller (any characteristic).
  Stream<BleNotification> get notifications;

  /// Requests Android runtime permissions and plugin authorization. No-op on
  /// other platforms.
  Future<void> ensureAuthorized();

  Future<void> startDiscovery();

  Future<void> stopDiscovery();

  /// [peripheralId] must come from [discovered]; the adapter caches the
  /// platform object.
  Future<void> connect(String peripheralId);

  Future<void> disconnect(String peripheralId);

  Future<List<GattServiceSnapshot>> discoverGatt(String peripheralId);

  /// Writes a complete value to a characteristic discovered by
  /// [discoverGatt]. Throws [BleException] when the characteristic is unknown.
  Future<void> writeCharacteristic(
    String peripheralId,
    String characteristicUuid,
    Uint8List value, {
    required bool withResponse,
  });

  /// Enables or disables notifications (CCCD) on a discovered characteristic.
  Future<void> setNotify(
    String peripheralId,
    String characteristicUuid, {
    required bool enabled,
  });
}
