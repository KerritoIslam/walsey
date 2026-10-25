import 'dart:io' show Platform;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_port.dart';
import 'gatt_profile.dart';

/// Adapter from `bluetooth_low_energy` 6.2.1 to the plugin-free [BleCentral]
/// port. This is the only file that knows about the plugin, `permission_handler`
/// and Android runtime permissions.
///
/// Read-only: it never calls writeCharacteristic, setCharacteristicNotifyState,
/// readCharacteristic or writeDescriptor.
final class PluginBleCentral implements BleCentral {
  PluginBleCentral({
    CentralManager? central,
    void Function(String line)? log,
  })  : _central = central ?? CentralManager(),
        _log = log;

  final CentralManager _central;
  final void Function(String line)? _log;

  /// Platform objects keyed by the stable id exposed in scan results.
  final Map<String, Peripheral> _peripherals = {};

  @override
  BleAdapterState get adapterState => _mapAdapterState(_central.state);

  @override
  Stream<BleAdapterState> get adapterStateChanges =>
      _central.stateChanged.map((event) => _mapAdapterState(event.state));

  @override
  Stream<ScannedPeripheral> get discovered =>
      _central.discovered.map(_toScannedPeripheral);

  @override
  Stream<BleConnectionEvent> get connectionChanges =>
      _central.connectionStateChanged.map(
        (event) => BleConnectionEvent(
          peripheralId: event.peripheral.uuid.toString(),
          connected: event.state == ConnectionState.connected,
        ),
      );

  @override
  Future<void> ensureAuthorized() async {
    // authorize() is documented as Android-only; other platforms return
    // through the OS-level permission model.
    if (!Platform.isAndroid) return;

    final sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    final usesNearbyDevices = sdkInt >= 31;
    final permissions = usesNearbyDevices
        ? <Permission>[
            Permission.bluetoothScan,
            Permission.bluetoothConnect,
          ]
        : <Permission>[Permission.locationWhenInUse];

    _say('Android SDK $sdkInt: requesting '
        '${usesNearbyDevices ? 'Nearby devices' : 'location for BLE scan'} '
        'runtime permissions');

    final before = {for (final p in permissions) p: await p.status};
    _logStatuses('before request', before);

    final needsRequest = before.entries
        .where((entry) => !entry.value.isGranted)
        .map((entry) => entry.key)
        .toList();
    if (needsRequest.isNotEmpty) {
      _say('requesting Android BLE runtime permissions: '
          '${needsRequest.map(_permissionName).join(', ')}');
      final requested = await needsRequest.request();
      _logStatuses('after request', requested);
    }

    final current = {for (final p in permissions) p: await p.status};
    _logStatuses('current', current);

    final permanentlyDenied = current.entries
        .where((entry) => entry.value.isPermanentlyDenied)
        .map((entry) => _permissionName(entry.key))
        .toList();
    if (permanentlyDenied.isNotEmpty) {
      await _central.showAppSettings();
      throw BleAuthorizationException(
        'PERMISSION PERMANENTLY DENIED: ${permanentlyDenied.join(', ')}; '
        'enable them in app settings',
      );
    }

    final denied = current.entries
        .where((entry) => !entry.value.isGranted)
        .map((entry) => _permissionName(entry.key))
        .toList();
    if (denied.isNotEmpty) {
      throw BleAuthorizationException(
        'PERMISSION DENIED: ${denied.join(', ')}; scan will not start',
      );
    }

    _say('calling bluetooth_low_energy authorize() after runtime permission '
        'preflight');
    final authorized = await _central.authorize();
    _say('authorize() -> $authorized');
    if (!authorized) {
      throw BleAuthorizationException(
        'PERMISSION ISSUE: plugin authorization failed despite runtime '
        'permissions reporting granted; check app permissions and Bluetooth',
      );
    }
  }

  @override
  Future<void> startDiscovery() => _central.startDiscovery();

  @override
  Future<void> stopDiscovery() => _central.stopDiscovery();

  @override
  Future<void> connect(String peripheralId) =>
      _central.connect(_requirePeripheral(peripheralId));

  @override
  Future<void> disconnect(String peripheralId) =>
      _central.disconnect(_requirePeripheral(peripheralId));

  @override
  Future<List<GattServiceSnapshot>> discoverGatt(String peripheralId) async {
    final services =
        await _central.discoverGATT(_requirePeripheral(peripheralId));
    return [
      for (final service in services)
        GattServiceSnapshot(
          uuid: service.uuid.toString(),
          characteristics: [
            for (final characteristic in service.characteristics)
              GattCharacteristicSnapshot(
                uuid: characteristic.uuid.toString(),
                properties: [
                  for (final property in characteristic.properties)
                    _mapProperty(property),
                ],
              ),
          ],
        ),
    ];
  }

  Peripheral _requirePeripheral(String peripheralId) {
    final peripheral = _peripherals[peripheralId];
    if (peripheral == null) {
      throw BleException(
        'unknown peripheral "$peripheralId"; scan before connecting',
      );
    }
    return peripheral;
  }

  ScannedPeripheral _toScannedPeripheral(DiscoveredEventArgs event) {
    final peripheral = event.peripheral;
    final id = peripheral.uuid.toString();
    _peripherals[id] = peripheral;

    final advertisement = event.advertisement;
    return ScannedPeripheral(
      id: id,
      name: _safeName(advertisement),
      rssi: event.rssi,
      advertisedServiceUuids: advertisement.serviceUUIDs
          .map((uuid) => uuid.toString())
          .toList(growable: false),
    );
  }

  /// `Advertisement.name` is documented as unavailable on some platforms.
  String? _safeName(Advertisement advertisement) {
    try {
      return advertisement.name;
    } on UnsupportedError {
      return null;
    }
  }

  void _say(String line) => _log?.call(line);

  void _logStatuses(
    String phase,
    Map<Permission, PermissionStatus> statuses,
  ) {
    for (final entry in statuses.entries) {
      _say('PERMISSION STATUS ($phase): ${_permissionName(entry.key)} -> '
          '${entry.value.name}');
    }
  }

  String _permissionName(Permission permission) => switch (permission) {
        Permission.bluetoothScan => 'BLUETOOTH_SCAN',
        Permission.bluetoothConnect => 'BLUETOOTH_CONNECT',
        Permission.locationWhenInUse => 'ACCESS_FINE_LOCATION',
        _ => permission.toString(),
      };
}

BleAdapterState _mapAdapterState(BluetoothLowEnergyState state) =>
    switch (state) {
      BluetoothLowEnergyState.unknown => BleAdapterState.unknown,
      BluetoothLowEnergyState.unsupported => BleAdapterState.unsupported,
      BluetoothLowEnergyState.unauthorized => BleAdapterState.unauthorized,
      BluetoothLowEnergyState.poweredOff => BleAdapterState.poweredOff,
      BluetoothLowEnergyState.poweredOn => BleAdapterState.poweredOn,
    };

GattProperty _mapProperty(GATTCharacteristicProperty property) =>
    switch (property) {
      GATTCharacteristicProperty.read => GattProperty.read,
      GATTCharacteristicProperty.write => GattProperty.write,
      GATTCharacteristicProperty.writeWithoutResponse =>
        GattProperty.writeWithoutResponse,
      GATTCharacteristicProperty.notify => GattProperty.notify,
      GATTCharacteristicProperty.indicate => GattProperty.indicate,
    };
