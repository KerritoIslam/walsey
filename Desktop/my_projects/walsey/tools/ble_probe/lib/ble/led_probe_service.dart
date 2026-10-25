import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import 'ble_port.dart';
import 'gatt_profile.dart';

/// Probe lifecycle.
///
/// [connected] means the GATT transport was validated AND the link is still
/// open. It does NOT mean the controller accepts frames or that LED control
/// works: this stage never writes a characteristic.
enum ProbePhase {
  disconnected,
  scanning,
  connecting,
  discovering,
  connected,
  disconnecting,
  failed,
}

const Object _keep = Object();

@immutable
final class ProbeState {
  const ProbeState({
    this.phase = ProbePhase.disconnected,
    this.adapterState = BleAdapterState.unknown,
    this.devices = const <ScannedPeripheral>[],
    this.selected,
    this.report,
    this.error,
    this.connectedDeviceIds = const <String>{},
    this.logs = const <String>[],
  });

  final ProbePhase phase;
  final BleAdapterState adapterState;

  /// Sorted by RSSI, deduplicated by [ScannedPeripheral.id].
  final List<ScannedPeripheral> devices;
  final ScannedPeripheral? selected;
  final TransportGattReport? report;
  final String? error;
  final Set<String> connectedDeviceIds;
  final List<String> logs;

  bool get isScanning => phase == ProbePhase.scanning;

  bool get isConnected => phase == ProbePhase.connected;

  bool get connectionBusy =>
      phase == ProbePhase.connecting ||
      phase == ProbePhase.discovering ||
      phase == ProbePhase.disconnecting;

  bool get selectedIsConnected =>
      selected != null && connectedDeviceIds.contains(selected!.id);

  ProbeState copyWith({
    ProbePhase? phase,
    BleAdapterState? adapterState,
    List<ScannedPeripheral>? devices,
    Object? selected = _keep,
    Object? report = _keep,
    Object? error = _keep,
    Set<String>? connectedDeviceIds,
    List<String>? logs,
  }) {
    return ProbeState(
      phase: phase ?? this.phase,
      adapterState: adapterState ?? this.adapterState,
      devices: devices ?? this.devices,
      selected: identical(selected, _keep)
          ? this.selected
          : selected as ScannedPeripheral?,
      report: identical(report, _keep)
          ? this.report
          : report as TransportGattReport?,
      error: identical(error, _keep) ? this.error : error as String?,
      connectedDeviceIds: connectedDeviceIds ?? this.connectedDeviceIds,
      logs: logs ?? this.logs,
    );
  }
}

/// Read-only discovery/connection workflow around [BleCentral].
///
/// Guarantees:
/// - one connection attempt at a time (duplicate requests are ignored);
/// - one automatic connection attempt per scan, even if the peripheral
///   advertises repeatedly;
/// - the link stays open after successful FFE0/FFE1 validation until
///   [disconnect] is called, the link is lost, or [dispose] runs;
/// - no automatic reconnect, scan restart or retry loop;
/// - no characteristic writes, handshakes, notification subscriptions or LED
///   commands.
final class LedProbeService {
  LedProbeService({
    required BleCentral central,
    this.preferredTargetName,
    this.connectionTimeout = const Duration(seconds: 20),
    this.discoveryTimeout = const Duration(seconds: 20),
    this.disconnectTimeout = const Duration(seconds: 10),
    void Function(String line)? onLog,
  })  : _central = central,
        _onLog = onLog {
    _discoveredSub = _central.discovered.listen(
      _handleDiscovered,
      onError: (Object error, StackTrace stackTrace) =>
          _log('SCAN STREAM ERROR', error: error, stackTrace: stackTrace),
    );
    _adapterSub = _central.adapterStateChanges.listen(
      _handleAdapterState,
      onError: (Object error, StackTrace stackTrace) =>
          _log('ADAPTER STREAM ERROR', error: error, stackTrace: stackTrace),
    );
    _connectionSub = _central.connectionChanges.listen(
      _handleConnectionEvent,
      onError: (Object error, StackTrace stackTrace) =>
          _log('CONNECTION STREAM ERROR', error: error, stackTrace: stackTrace),
    );
    _publish(adapterState: _central.adapterState);
    _log('probe service initialized; READ-ONLY: no writes, handshakes, '
        'notification subscriptions or LED commands');
  }

  static const int _maxLogLines = 500;

  final BleCentral _central;
  final void Function(String line)? _onLog;
  final String? preferredTargetName;

  final Duration connectionTimeout;
  final Duration discoveryTimeout;
  final Duration disconnectTimeout;

  final ValueNotifier<ProbeState> _state =
      ValueNotifier<ProbeState>(const ProbeState());

  final Map<String, ScannedPeripheral> _devices = {};
  final List<String> _logLines = [];

  late final StreamSubscription<ScannedPeripheral> _discoveredSub;
  late final StreamSubscription<BleAdapterState> _adapterSub;
  late final StreamSubscription<BleConnectionEvent> _connectionSub;

  bool _disposed = false;
  bool _scanRequested = false;
  bool _discoveryActive = false;
  bool _autoInspectHandled = false;
  bool _teardownRequested = false;

  /// Increments on every user scan request; used to attribute connection
  /// attempts in logs without introducing any retry behaviour.
  int _scanGeneration = 0;

  /// UI-facing immutable state.
  ValueListenable<ProbeState> get state => _state;

  ProbeState get current => _state.value;

  /// Appends an external diagnostic line (used by the platform adapter).
  void log(String line) => _log(line);

  /// Starts one user-initiated scan. Auto-inspection of the preferred
  /// controller happens at most once for this scan generation.
  Future<void> startScan() async {
    if (_disposed) return;
    final current = _state.value;
    if (current.isConnected) {
      _log('SCAN IGNORED: already connected; disconnect before scanning again');
      return;
    }
    if (current.isScanning || current.connectionBusy) return;

    _scanGeneration++;
    _scanRequested = true;
    _autoInspectHandled = false;
    _devices.clear();
    _publish(
      phase: ProbePhase.scanning,
      devices: const <ScannedPeripheral>[],
      selected: null,
      report: null,
      error: null,
    );
    _log('SCAN REQUESTED (scan #$_scanGeneration; read-only, no frames)');

    try {
      await _central.ensureAuthorized();
      if (_disposed || !_scanRequested) return;

      final adapter = _central.adapterState;
      _publish(adapterState: adapter);
      if (adapter != BleAdapterState.poweredOn) {
        _scanRequested = false;
        _failMessage(
          'BLUETOOTH STATE ISSUE: scan requires poweredOn, got '
          '${adapter.name}; turn on Bluetooth and grant Nearby devices '
          'permission',
        );
        return;
      }

      await _central.startDiscovery();
      if (_disposed) {
        // dispose() ran while startDiscovery was in flight, so it saw
        // _discoveryActive == false and could not stop the scan itself.
        try {
          await _central.stopDiscovery();
        } catch (_) {
          // Best effort during teardown.
        }
        return;
      }
      if (!_scanRequested) {
        // Stop was pressed while authorization/start were in flight.
        await _central.stopDiscovery();
        return;
      }
      _discoveryActive = true;
      _log('SCAN STARTED');
    } catch (error, stackTrace) {
      _scanRequested = false;
      _discoveryActive = false;
      _fail('SCAN FAILED', error, stackTrace);
    }
  }

  Future<void> stopScan() async {
    _scanRequested = false;
    if (_disposed) return;

    if (_discoveryActive) {
      try {
        await _central.stopDiscovery();
        _log('SCAN STOPPED (${_devices.length} unique devices seen)');
      } catch (error, stackTrace) {
        _fail('SCAN STOP FAILED', error, stackTrace);
        return;
      } finally {
        _discoveryActive = false;
      }
    }
    if (!_disposed && _state.value.phase == ProbePhase.scanning) {
      _publish(phase: ProbePhase.disconnected);
    }
  }

  /// Connects, discovers GATT, validates FFE0/FFE1 and keeps the link open.
  ///
  /// [automatic] is only true for the once-per-scan target auto-connect; it
  /// affects logging, not retry behaviour. If another attempt is in progress
  /// or the probe is already connected, this is a no-op (logged).
  Future<void> connect(ScannedPeripheral device,
      {bool automatic = false}) async {
    if (_disposed) return;
    final current = _state.value;
    if (current.connectionBusy || current.isConnected) {
      _log('CONNECT REQUEST IGNORED: already ${current.phase.name}');
      return;
    }

    if (current.isScanning) {
      await stopScan();
    }
    if (_disposed) return;

    _teardownRequested = false;
    _publish(
      phase: ProbePhase.connecting,
      selected: device,
      report: null,
      error: null,
    );
    _log('--- CONNECT "${device.name ?? '(no name)'}" (${device.id}) ---');
    _log('CONNECT REQUEST origin='
        '${automatic ? 'auto (scan #$_scanGeneration)' : 'manual'}');
    _log('READ-ONLY: no characteristic writes, notification subscriptions, '
        'handshakes or LED commands');

    final resolution = resolveVariant(device.name);
    if (resolution
        case SupportedVariant(:final layout, :final advertisedName)) {
      _log('SELECTED TARGET: "$advertisedName" is documented LEDDMX; '
          'layout=$layout');
    } else if (resolution case UnsupportedVariant(:final reason)) {
      _log('SELECTED DEVICE is not a supported LEDDMX variant; connecting '
          'anyway (read-only); reason=$reason');
    }

    TransportGattReport? report;
    String? failure;

    try {
      _log('CONNECTION ATTEMPT: ${device.id}');
      await _central.connect(device.id).timeout(connectionTimeout);
      if (_disposed) {
        await _bestEffortDisconnect(device.id);
        return;
      }
      _publish(phase: ProbePhase.discovering);
      _log('CONNECTION RESULT: connected');

      if (_teardownRequested) {
        _log('DISCONNECT REQUESTED before service discovery; skipping it');
      } else {
        _log('SERVICE DISCOVERY STARTED');
        final services =
            await _central.discoverGatt(device.id).timeout(discoveryTimeout);
        if (_disposed) {
          await _bestEffortDisconnect(device.id);
          return;
        }
        if (_teardownRequested) {
          _log('DISCONNECT REQUESTED during service discovery; releasing '
              'the connection');
        } else {
          _logServices(services);
          report = validateTransportGatt(services);
          for (final finding in report.findings) {
            _log(finding);
          }
          if (report.isUsable) {
            _log('GATT TRANSPORT RESULT: FFE0/FFE1 validated for the '
                'documented LEDDMX transport. Link will stay open. '
                'READ-ONLY: no frames were sent, so this does NOT confirm '
                'LED control.');
          } else {
            failure = 'GATT VALIDATION FAILED: ${report.blockers.join('; ')}';
            _log(failure);
          }
        }
      }
    } on TimeoutException catch (error, stackTrace) {
      failure = 'TIMEOUT during connect/service discovery';
      _log(failure, error: error, stackTrace: stackTrace);
    } catch (error, stackTrace) {
      failure = 'CONNECTION/DISCOVERY ERROR: $error';
      _log('CONNECTION/DISCOVERY ERROR', error: error, stackTrace: stackTrace);
    }

    if (_disposed) {
      await _bestEffortDisconnect(device.id);
      return;
    }

    final keepConnected = failure == null &&
        !_teardownRequested &&
        report != null &&
        report.isUsable;

    if (keepConnected) {
      _publish(phase: ProbePhase.connected, report: report, error: null);
      _log('CONNECTED: keeping the BLE link open until Disconnect, link loss '
          'or app disposal');
      return;
    }

    _publish(phase: ProbePhase.disconnecting);
    var disconnectFailure = false;
    try {
      _log('DISCONNECTION ATTEMPT: ${device.id}');
      await _central.disconnect(device.id).timeout(disconnectTimeout);
      _log('DISCONNECTION RESULT: disconnected');
    } on TimeoutException catch (error, stackTrace) {
      disconnectFailure = true;
      failure ??= 'DISCONNECT TIMEOUT';
      _log('DISCONNECT TIMEOUT', error: error, stackTrace: stackTrace);
    } catch (error, stackTrace) {
      disconnectFailure = true;
      failure ??= 'DISCONNECT ERROR: $error';
      _log('DISCONNECT ERROR', error: error, stackTrace: stackTrace);
    }

    if (_disposed) return;

    if (!disconnectFailure && _teardownRequested) {
      _log('DISCONNECT RESULT: user requested; connection released');
      _publish(
        phase: ProbePhase.disconnected,
        selected: null,
        report: null,
        error: null,
      );
      return;
    }

    failure ??= 'CONNECTION FAILED: transport did not validate';
    _publish(phase: ProbePhase.failed, report: report, error: failure);
  }

  /// Explicitly releases the current connection.
  ///
  /// During connect/discovery this requests teardown: the in-flight operation
  /// finishes, service discovery is skipped when possible, and the link is
  /// released without any retry. With no connection it is a logged no-op.
  Future<void> disconnect() async {
    if (_disposed) return;
    final current = _state.value;
    final selected = current.selected;

    if (selected == null) {
      _log('DISCONNECT IGNORED: no selected device');
      return;
    }
    if (current.isScanning) {
      await stopScan();
      _log('DISCONNECT IGNORED: scan stopped; no device connected');
      return;
    }
    if (current.phase == ProbePhase.connecting ||
        current.phase == ProbePhase.discovering) {
      _teardownRequested = true;
      _log('DISCONNECT REQUESTED during ${current.phase.name}; the current '
          'attempt will release the link without retrying');
      return;
    }
    if (!current.isConnected) {
      _log('DISCONNECT IGNORED: not connected (${current.phase.name})');
      return;
    }

    _publish(phase: ProbePhase.disconnecting);
    String? failure;
    try {
      _log('DISCONNECTION ATTEMPT: ${selected.id}');
      await _central.disconnect(selected.id).timeout(disconnectTimeout);
      _log('DISCONNECTION RESULT: disconnected');
    } on TimeoutException catch (error, stackTrace) {
      failure = 'DISCONNECT TIMEOUT';
      _log(failure, error: error, stackTrace: stackTrace);
    } catch (error, stackTrace) {
      failure = 'DISCONNECT ERROR: $error';
      _log('DISCONNECT ERROR', error: error, stackTrace: stackTrace);
    }

    if (_disposed) return;
    if (failure != null) {
      _publish(phase: ProbePhase.failed, error: failure);
      return;
    }
    _publish(
      phase: ProbePhase.disconnected,
      selected: null,
      report: null,
      error: null,
    );
  }

  /// Cancels subscriptions, stops discovery, releases a live connection and
  /// disposes the state notifier. Output from an in-flight operation after
  /// disposal is discarded.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _scanRequested = false;

    await _discoveredSub.cancel();
    await _adapterSub.cancel();
    await _connectionSub.cancel();

    if (_discoveryActive) {
      _discoveryActive = false;
      try {
        await _central.stopDiscovery();
      } catch (_) {
        // Best effort during teardown.
      }
    }

    final selected = _state.value.selected;
    if (selected != null && _state.value.isConnected) {
      await _bestEffortDisconnect(selected.id);
    }
    _state.dispose();
  }

  void _handleDiscovered(ScannedPeripheral device) {
    if (_disposed || !_scanRequested) return;
    if (_state.value.phase != ProbePhase.scanning) return;

    final isNew = !_devices.containsKey(device.id);
    _devices[device.id] = device;

    if (isNew) {
      final names = device.advertisedServiceUuids.isEmpty
          ? '(none)'
          : device.advertisedServiceUuids.join(', ');
      _log('DISCOVERED DEVICE: ${device.id}; '
          'name=${device.name ?? '(none)'}; RSSI=${device.rssi}; '
          'advertised service UUIDs=$names');

      switch (resolveVariant(device.name)) {
        case SupportedVariant(:final layout, :final advertisedName):
          _log('TARGET LED MATCH: "$advertisedName" is documented LEDDMX; '
              'layout=$layout');
        case UnsupportedVariant(:final reason):
          _log('NOT TARGET LED: ${device.name ?? '(no name)'}; reason=$reason');
      }
    }

    _publish(devices: _sortedDevices());
    if (isNew) _maybeAutoConnect(device);
  }

  void _maybeAutoConnect(ScannedPeripheral device) {
    if (_disposed || _autoInspectHandled || !_scanRequested) return;
    if (_state.value.phase != ProbePhase.scanning) return;
    if (resolveVariant(device.name) is! SupportedVariant) return;

    final preferred = preferredTargetName?.trim().toLowerCase();
    if (preferred != null &&
        preferred.isNotEmpty &&
        (device.name?.trim().toLowerCase() ?? '') != preferred) {
      // Keep scanning for the known unit; other LEDDMX devices stay manual.
      return;
    }

    _autoInspectHandled = true;
    _log('TARGET DEVICE FOUND: "${device.name}"; stopping scan and connecting '
        'once (scan #$_scanGeneration)');
    unawaited(connect(device, automatic: true));
  }

  void _handleAdapterState(BleAdapterState adapterState) {
    if (_disposed) return;
    _log('BLUETOOTH STATE CHANGED: ${adapterState.name}');
    _publish(adapterState: adapterState);
  }

  void _handleConnectionEvent(BleConnectionEvent event) {
    if (_disposed) return;
    final current = _state.value;
    final connected = Set<String>.of(current.connectedDeviceIds);
    if (event.connected) {
      connected.add(event.peripheralId);
    } else {
      connected.remove(event.peripheralId);
    }
    _log(event.connected
        ? 'CONNECTION EVENT: ${event.peripheralId} -> connected'
        : 'DISCONNECTION EVENT: ${event.peripheralId} -> disconnected');

    final lostWhileConnected = !event.connected &&
        current.isConnected &&
        current.selected?.id == event.peripheralId;
    if (lostWhileConnected) {
      _publish(
        phase: ProbePhase.failed,
        connectedDeviceIds: Set<String>.unmodifiable(connected),
        error: 'CONNECTION LOST: ${event.peripheralId} disconnected; no '
            'automatic reconnect will be attempted',
      );
      return;
    }

    _publish(connectedDeviceIds: Set<String>.unmodifiable(connected));
  }

  void _logServices(List<GattServiceSnapshot> services) {
    _log('SERVICE DISCOVERY RESULT: ${services.length} services');
    for (final service in services) {
      _log('SERVICE UUID: ${service.uuid.toLowerCase()}');
      for (final characteristic in service.characteristics) {
        _log('CHARACTERISTIC UUID: ${characteristic.uuid.toLowerCase()}; '
            'properties=[${characteristic.propertyLabel}]');
      }
    }
  }

  List<ScannedPeripheral> _sortedDevices() {
    final devices = _devices.values.toList(growable: false)
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return List<ScannedPeripheral>.unmodifiable(devices);
  }

  Future<void> _bestEffortDisconnect(String peripheralId) async {
    try {
      await _central.disconnect(peripheralId).timeout(disconnectTimeout);
    } catch (_) {
      // The link may already be gone; teardown is best effort.
    }
  }

  void _fail(String message, Object error, StackTrace stackTrace) {
    _log(message, error: error, stackTrace: stackTrace);
    _log('  $error');
    _publish(phase: ProbePhase.failed, error: '$message: $error');
  }

  void _failMessage(String message) {
    _log(message);
    _publish(phase: ProbePhase.failed, error: message);
  }

  void _publish({
    ProbePhase? phase,
    BleAdapterState? adapterState,
    List<ScannedPeripheral>? devices,
    Object? selected = _keep,
    Object? report = _keep,
    Object? error = _keep,
    Set<String>? connectedDeviceIds,
    List<String>? logs,
  }) {
    if (_disposed) return;
    _state.value = _state.value.copyWith(
      phase: phase,
      adapterState: adapterState,
      devices: devices,
      selected: selected,
      report: report,
      error: error,
      connectedDeviceIds: connectedDeviceIds,
      logs: logs,
    );
  }

  void _log(String line, {Object? error, StackTrace? stackTrace}) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 23);
    final message = '$timestamp  $line';

    final onLog = _onLog;
    if (onLog != null) {
      onLog(message);
    } else {
      developer.log(
        line,
        name: 'WalseyBleProbe',
        error: error,
        stackTrace: stackTrace,
      );
      // Terminal output is intentional: this is the primary probe diagnostic.
      // ignore: avoid_print
      print('[WalseyBleProbe] $message');
    }

    _logLines.add(message);
    if (error != null) _logLines.add('$timestamp  $error');
    while (_logLines.length > _maxLogLines) {
      _logLines.removeAt(0);
    }
    _publish(logs: List<String>.unmodifiable(_logLines));
  }
}
