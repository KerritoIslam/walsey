import 'dart:async';

import 'gatt_profile.dart';

/// Platform Bluetooth adapter state, mirrored without plugin types.
enum BleAdapterState {
  unknown,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn,
}

/// One scan result, deduplicated by the service using [id].
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

class BleException implements Exception {
  BleException(this.message);

  final String message;

  @override
  String toString() => 'BleException: $message';
}

final class BleAuthorizationException extends BleException {
  BleAuthorizationException(super.message);
}

/// Port over the BLE central role. Deliberately read-only: there is no write,
/// handshake or notification-subscription method here.
///
/// The service layer depends on this interface; the Flutter/BLE implementation
/// lives in `plugin_central.dart` and tests use a fake.
abstract interface class BleCentral {
  BleAdapterState get adapterState;

  Stream<BleAdapterState> get adapterStateChanges;

  /// Deduplicated by the consumer; repeated advertisements for the same
  /// peripheral are normal.
  Stream<ScannedPeripheral> get discovered;

  Stream<BleConnectionEvent> get connectionChanges;

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
}
