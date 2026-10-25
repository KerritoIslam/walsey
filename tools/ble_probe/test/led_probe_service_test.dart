import 'dart:async';

import 'package:ble_probe/ble/ble_port.dart';
import 'package:ble_probe/ble/gatt_profile.dart';
import 'package:ble_probe/ble/led_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _targetName = 'LEDDMX-03-6B4A';
const _deviceId = 'peripheral-1';

ScannedPeripheral device({
  String id = _deviceId,
  String? name = _targetName,
  int rssi = -40,
}) =>
    ScannedPeripheral(
      id: id,
      name: name,
      rssi: rssi,
      advertisedServiceUuids: const [],
    );

List<GattServiceSnapshot> validGatt() => [
      const GattServiceSnapshot(
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
      ),
    ];

final class FakeBleCentral implements BleCentral {
  final StreamController<ScannedPeripheral> _discovered =
      StreamController<ScannedPeripheral>.broadcast(sync: true);
  final StreamController<BleAdapterState> _adapterStates =
      StreamController<BleAdapterState>.broadcast(sync: true);
  final StreamController<BleConnectionEvent> _connections =
      StreamController<BleConnectionEvent>.broadcast(sync: true);

  final List<String> calls = [];
  bool authorizeFails = false;
  Completer<void>? connectGate;
  Completer<void>? discoverGate;
  Completer<void>? startDiscoveryGate;
  List<GattServiceSnapshot> gattServices = validGatt();
  bool failDiscovery = false;

  @override
  BleAdapterState adapterState = BleAdapterState.poweredOn;

  @override
  Stream<BleAdapterState> get adapterStateChanges => _adapterStates.stream;

  @override
  Stream<ScannedPeripheral> get discovered => _discovered.stream;

  @override
  Stream<BleConnectionEvent> get connectionChanges => _connections.stream;

  @override
  Future<void> ensureAuthorized() async {
    calls.add('ensureAuthorized');
    if (authorizeFails) {
      throw BleAuthorizationException('PERMISSION DENIED');
    }
  }

  @override
  Future<void> startDiscovery() async {
    calls.add('startDiscovery');
    final gate = startDiscoveryGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stopDiscovery() async {
    calls.add('stopDiscovery');
  }

  @override
  Future<void> connect(String peripheralId) async {
    calls.add('connect:$peripheralId');
    emitConnection(peripheralId, connected: true);
    final gate = connectGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> disconnect(String peripheralId) async {
    calls.add('disconnect:$peripheralId');
    emitConnection(peripheralId, connected: false);
  }

  @override
  Future<List<GattServiceSnapshot>> discoverGatt(String peripheralId) async {
    calls.add('discoverGatt:$peripheralId');
    final gate = discoverGate;
    if (gate != null) await gate.future;
    if (failDiscovery) throw BleException('GATT discovery failed');
    return gattServices;
  }

  void emit(ScannedPeripheral result) => _discovered.add(result);

  void emitConnection(String peripheralId, {required bool connected}) =>
      _connections.add(
        BleConnectionEvent(
          peripheralId: peripheralId,
          connected: connected,
        ),
      );

  int countCalls(String prefix) =>
      calls.where((call) => call.startsWith(prefix)).length;

  Future<void> close() async {
    await _discovered.close();
    await _adapterStates.close();
    await _connections.close();
  }
}

({FakeBleCentral fake, LedProbeService service}) createProbe({
  String? preferredTargetName = _targetName,
  Duration connectionTimeout = const Duration(seconds: 2),
}) {
  final fake = FakeBleCentral();
  addTearDown(fake.close);
  final service = LedProbeService(
    central: fake,
    preferredTargetName: preferredTargetName,
    connectionTimeout: connectionTimeout,
    discoveryTimeout: const Duration(seconds: 2),
    disconnectTimeout: const Duration(seconds: 2),
    onLog: (_) {},
  );
  addTearDown(service.dispose);
  return (fake: fake, service: service);
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Connects the fake target directly (no scan) and waits for `connected`.
Future<({FakeBleCentral fake, LedProbeService service})> connectTarget() async {
  final probe = createProbe();
  await probe.service.connect(device());
  expect(probe.service.current.phase, ProbePhase.connected);
  return probe;
}

void main() {
  group('persistent connection', () {
    test('auto-connect validates FFE0/FFE1 and keeps the link open', () async {
      final (:fake, :service) = createProbe();

      await service.startScan();
      expect(service.current.phase, ProbePhase.scanning);

      fake.emit(device());
      await waitFor(() => service.current.phase == ProbePhase.connected);

      expect(service.current.report?.isUsable, isTrue);
      expect(service.current.selected?.id, _deviceId);
      expect(service.current.connectedDeviceIds, contains(_deviceId));
      expect(fake.countCalls('connect:'), 1);
      expect(fake.countCalls('discoverGatt:'), 1);
      expect(
        fake.calls.where((call) => call.startsWith('disconnect:')),
        isEmpty,
        reason: 'a successful validation must not release the link',
      );
      expect(service.current.logs,
          contains(contains('CONNECT REQUEST origin=auto (scan #1)')));
      expect(
        service.current.logs,
        contains(contains('keeping the BLE link open')),
      );
    });

    test('repeated advertisements for the target cause exactly one connect',
        () async {
      final (:fake, :service) = createProbe();

      await service.startScan();
      for (var i = 0; i < 8; i++) {
        fake.emit(device());
      }
      await waitFor(() => service.current.phase == ProbePhase.connected);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fake.countCalls('connect:'), 1);
      expect(fake.countCalls('discoverGatt:'), 1);
      expect(service.current.phase, ProbePhase.connected);
    });

    test('manual connect stays connected without scanning', () async {
      final (:fake, :service) = createProbe(preferredTargetName: null);

      await service.connect(device());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(service.current.phase, ProbePhase.connected);
      expect(fake.countCalls('startDiscovery'), 0);
      expect(fake.countCalls('disconnect:'), 0);
      expect(service.current.logs,
          contains(contains('CONNECT REQUEST origin=manual')));
    });

    test('scan is refused while connected', () async {
      final (:fake, :service) = await connectTarget();

      await service.startScan();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.current.phase, ProbePhase.connected);
      expect(fake.countCalls('startDiscovery'), 0);
      expect(service.current.logs, contains(contains('SCAN IGNORED')));
    });

    test('duplicate connect while connected is ignored', () async {
      final (:fake, :service) = await connectTarget();

      await service.connect(device());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fake.countCalls('connect:'), 1);
      expect(service.current.phase, ProbePhase.connected);
      expect(
          service.current.logs, contains(contains('CONNECT REQUEST IGNORED')));
    });

    test('duplicate connect while connecting is ignored', () async {
      final (:fake, :service) = createProbe();
      fake.connectGate = Completer<void>();

      final first = service.connect(device());
      await waitFor(() => service.current.phase == ProbePhase.connecting);
      await service.connect(device());

      expect(fake.countCalls('connect:'), 1);
      expect(
          service.current.logs, contains(contains('CONNECT REQUEST IGNORED')));

      fake.connectGate!.complete();
      await first;
      expect(service.current.phase, ProbePhase.connected);
      expect(fake.countCalls('connect:'), 1);
    });
  });

  group('disconnect', () {
    test('explicit disconnect releases the link and does not reconnect',
        () async {
      final (:fake, :service) = await connectTarget();

      await service.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(service.current.phase, ProbePhase.disconnected);
      expect(service.current.selected, isNull);
      expect(service.current.report, isNull);
      expect(service.current.connectedDeviceIds, isEmpty);
      expect(fake.countCalls('disconnect:'), 1);
      expect(fake.countCalls('connect:'), 1);
    });

    test('disconnect during connect skips service discovery and releases',
        () async {
      final (:fake, :service) = createProbe();
      fake.connectGate = Completer<void>();

      final pending = service.connect(device());
      await waitFor(() => service.current.phase == ProbePhase.connecting);

      await service.disconnect();
      fake.connectGate!.complete();
      await pending;

      expect(service.current.phase, ProbePhase.disconnected);
      expect(fake.countCalls('discoverGatt:'), 0);
      expect(fake.countCalls('disconnect:'), 1);
      expect(fake.countCalls('connect:'), 1);
    });

    test('disconnect during discovery releases without retrying', () async {
      final (:fake, :service) = createProbe();
      fake.discoverGate = Completer<void>();

      final pending = service.connect(device());
      await waitFor(() => service.current.phase == ProbePhase.discovering);

      await service.disconnect();
      fake.discoverGate!.complete();
      await pending;

      expect(service.current.phase, ProbePhase.disconnected);
      expect(fake.countCalls('disconnect:'), 1);
      expect(fake.countCalls('connect:'), 1);
    });

    test('link loss while connected fails and does not auto-reconnect',
        () async {
      final (:fake, :service) = await connectTarget();

      fake.emitConnection(_deviceId, connected: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(service.current.phase, ProbePhase.failed);
      expect(service.current.error, contains('CONNECTION LOST'));
      expect(fake.countCalls('connect:'), 1);
    });

    test('dispose while connected disconnects', () async {
      final (:fake, :service) = await connectTarget();

      await service.dispose();

      expect(fake.countCalls('disconnect:'), 1);
    });
  });

  group('failure handling', () {
    test('connect timeout fails once and does not retry', () async {
      final (:fake, :service) = createProbe(
        connectionTimeout: const Duration(milliseconds: 30),
      );
      fake.connectGate = Completer<void>();

      await service.connect(device());
      expect(service.current.phase, ProbePhase.failed);
      expect(service.current.error, contains('TIMEOUT'));
      expect(fake.countCalls('connect:'), 1);
      expect(fake.countCalls('disconnect:'), 1);

      fake.connectGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.countCalls('connect:'), 1);
    });

    test('GATT validation failure releases the link and fails', () async {
      final (:fake, :service) = createProbe();
      fake.gattServices = [
        const GattServiceSnapshot(
          uuid: ffe0ServiceUuid,
          characteristics: [],
        ),
      ];

      await service.connect(device());

      expect(service.current.phase, ProbePhase.failed);
      expect(service.current.error, contains('GATT VALIDATION FAILED'));
      expect(service.current.report?.isUsable, isFalse);
      expect(fake.countCalls('disconnect:'), 1);
    });

    test('discovery errors release the link without an automatic retry',
        () async {
      final (:fake, :service) = createProbe();
      fake.failDiscovery = true;

      await service.connect(device());

      expect(service.current.phase, ProbePhase.failed);
      expect(service.current.error, contains('CONNECTION/DISCOVERY ERROR'));
      expect(fake.countCalls('connect:'), 1);
      expect(fake.countCalls('disconnect:'), 1);
    });

    test('powered-off adapter fails before discovery starts', () async {
      final (:fake, :service) = createProbe();
      fake.adapterState = BleAdapterState.poweredOff;

      await service.startScan();

      expect(service.current.phase, ProbePhase.failed);
      expect(service.current.error, contains('BLUETOOTH STATE ISSUE'));
      expect(fake.calls, contains('ensureAuthorized'));
      expect(fake.calls, isNot(contains('startDiscovery')));
    });

    test('permission failures surface as a failed scan', () async {
      final (:fake, :service) = createProbe();
      fake.authorizeFails = true;

      await service.startScan();

      expect(service.current.phase, ProbePhase.failed);
      expect(service.current.error, contains('PERMISSION DENIED'));
      expect(fake.calls, isNot(contains('startDiscovery')));
    });
  });

  group('scan lifecycle', () {
    test('does not auto-connect to a non-preferred LEDDMX device', () async {
      final (:fake, :service) = createProbe();

      await service.startScan();
      fake.emit(device(name: 'LEDDMX-02-ABCD'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.current.phase, ProbePhase.scanning);
      expect(fake.countCalls('connect:'), 0);
    });

    test('deduplicates repeated scan results by peripheral id', () async {
      final (:fake, :service) = createProbe(preferredTargetName: null);

      await service.startScan();
      fake.emit(device(name: 'LEDBLE-00-1111', rssi: -70));
      fake.emit(device(name: 'LEDBLE-00-1111', rssi: -30));

      expect(service.current.devices, hasLength(1));
      expect(service.current.devices.single.rssi, -30);
      expect(fake.countCalls('connect:'), 0);
    });

    test('stopScan returns to disconnected', () async {
      final (:fake, :service) = createProbe(preferredTargetName: null);

      await service.startScan();
      await service.stopScan();

      expect(service.current.phase, ProbePhase.disconnected);
      expect(service.current.isScanning, isFalse);
      expect(fake.calls, contains('stopDiscovery'));
    });

    test('dispose during startDiscovery still stops discovery', () async {
      final (:fake, :service) = createProbe();
      fake.startDiscoveryGate = Completer<void>();

      final scan = service.startScan();
      await waitFor(() => fake.calls.contains('startDiscovery'));

      await service.dispose();
      fake.startDiscoveryGate!.complete();
      await scan;

      expect(fake.calls, contains('stopDiscovery'));
    });
  });
}
