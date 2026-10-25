// Private named parameters cannot be initializing formals; the constructor's
// public names are the package API.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import '../control/led_control_service.dart';

/// Connection lifecycle for the main app.
///
/// [AppConnectionPhase.connected] means the link is open, FFE0/FFE1 were
/// validated and (for a supported `LEDDMX-NN` name) the command API is bound.
/// It does NOT mean any command frame has been accepted by the controller.
enum AppConnectionPhase {
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
final class AppConnectionState {
  const AppConnectionState({
    this.phase = AppConnectionPhase.disconnected,
    this.adapterState = BleAdapterState.unknown,
    this.devices = const <ScannedPeripheral>[],
    this.selected,
    this.report,
    this.error,
    this.variant,
    this.controlsBlockedReason,
    this.connectedDeviceIds = const <String>{},
    this.logs = const <String>[],
  });

  final AppConnectionPhase phase;
  final BleAdapterState adapterState;

  /// Sorted by RSSI, deduplicated by [ScannedPeripheral.id].
  final List<ScannedPeripheral> devices;
  final ScannedPeripheral? selected;
  final TransportGattReport? report;
  final String? error;

  /// Non-null only when a documented LEDDMX layout was resolved.
  final SupportedVariant? variant;

  /// Why controls are disabled despite a usable GATT transport (unsupported
  /// advertised name), or null when controls are available.
  final String? controlsBlockedReason;

  final Set<String> connectedDeviceIds;
  final List<String> logs;

  bool get isScanning => phase == AppConnectionPhase.scanning;
  bool get isConnected => phase == AppConnectionPhase.connected;
  bool get connectionBusy =>
      phase == AppConnectionPhase.connecting ||
      phase == AppConnectionPhase.discovering ||
      phase == AppConnectionPhase.disconnecting;

  bool get controlsAvailable =>
      isConnected && variant != null && controlsBlockedReason == null;

  AppConnectionState copyWith({
    AppConnectionPhase? phase,
    BleAdapterState? adapterState,
    List<ScannedPeripheral>? devices,
    Object? selected = _keep,
    Object? report = _keep,
    Object? error = _keep,
    Object? variant = _keep,
    Object? controlsBlockedReason = _keep,
    Set<String>? connectedDeviceIds,
    List<String>? logs,
  }) =>
      AppConnectionState(
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
        variant: identical(variant, _keep)
            ? this.variant
            : variant as SupportedVariant?,
        controlsBlockedReason: identical(controlsBlockedReason, _keep)
            ? this.controlsBlockedReason
            : controlsBlockedReason as String?,
        connectedDeviceIds: connectedDeviceIds ?? this.connectedDeviceIds,
        logs: logs ?? this.logs,
      );
}

/// Scan/connect/validate state machine plus the command API binding.
///
/// Reuses the Stage 1 probe's guarantee set:
/// - one connection attempt at a time; duplicate requests are ignored;
/// - the link stays open after FFE0/FFE1 validation until [disconnect], link
///   loss or [dispose];
/// - no automatic reconnect, retry loop or auto-disconnect;
/// - scanning is refused while connected;
/// - no command frame is ever sent automatically, including the handshake.
///
/// Added in Stage 2: after validation it enables FFE1 notifications (receive
/// only), binds [LeddmxDriver] for supported variants and exposes
/// [LedControlService] for typed commands.
final class LedConnectionService {
  LedConnectionService({
    required BleCentral central,
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
    _log('Walsey app initialized; no frames are sent until you press a '
        'command button');
  }

  static const int _maxLogLines = 800;

  final BleCentral _central;
  final void Function(String line)? _onLog;

  final Duration connectionTimeout;
  final Duration discoveryTimeout;
  final Duration disconnectTimeout;

  final ValueNotifier<AppConnectionState> _state =
      ValueNotifier<AppConnectionState>(const AppConnectionState());

  final Map<String, ScannedPeripheral> _devices = {};
  final List<String> _logLines = [];

  late final StreamSubscription<ScannedPeripheral> _discoveredSub;
  late final StreamSubscription<BleAdapterState> _adapterSub;
  late final StreamSubscription<BleConnectionEvent> _connectionSub;

  LeddmxDriver? _driver;
  PluginLedTransport? _transport;
  LedControlService? _controls;

  bool _disposed = false;
  bool _scanRequested = false;
  bool _discoveryActive = false;
  bool _teardownRequested = false;
  int _scanGeneration = 0;

  ValueListenable<AppConnectionState> get state => _state;

  AppConnectionState get current => _state.value;

  /// Typed command API; null unless connected to a supported variant.
  LedControlService? get controls => _controls;

  /// App-level diagnostics (also exposed in state.logs).
  void log(String line) => _log(line);

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
    _devices.clear();
    _publish(
      phase: AppConnectionPhase.scanning,
      devices: const <ScannedPeripheral>[],
      selected: null,
      report: null,
      error: null,
      variant: null,
      controlsBlockedReason: null,
    );
    _log('SCAN REQUESTED (scan #$_scanGeneration)');

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
        try {
          await _central.stopDiscovery();
        } catch (_) {
          // Best effort during teardown.
        }
        return;
      }
      if (!_scanRequested) {
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
    if (!_disposed && _state.value.phase == AppConnectionPhase.scanning) {
      _publish(phase: AppConnectionPhase.disconnected);
    }
  }

  /// Connects, discovers GATT, validates FFE0/FFE1 and keeps the link open.
  ///
  /// Commands become available only for a supported `LEDDMX-NN` advertised
  /// name. No handshake or command frame is sent here.
  Future<void> connect(ScannedPeripheral device) async {
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
      phase: AppConnectionPhase.connecting,
      selected: device,
      report: null,
      error: null,
      variant: null,
      controlsBlockedReason: null,
    );
    _log('--- CONNECT "${device.name ?? '(no name)'}" (${device.id}) ---');

    final resolution = resolveVariant(device.name);
    SupportedVariant? supported;
    switch (resolution) {
      case SupportedVariant(:final layout, :final advertisedName):
        supported = resolution;
        _log('SELECTED TARGET: "$advertisedName" is documented LEDDMX; '
            'layout=$layout');
      case UnsupportedVariant(:final reason):
        _log('SELECTED DEVICE is not a supported LEDDMX variant; the link '
            'may connect but controls stay disabled; reason=$reason');
    }

    TransportGattReport? report;
    String? failure;
    PluginLedTransport? transport;
    LeddmxDriver? driver;
    LedControlService? controls;
    String? controlsBlockedReason;

    try {
      _log('CONNECTION ATTEMPT: ${device.id}');
      await _central.connect(device.id).timeout(connectionTimeout);
      if (_disposed) {
        await _bestEffortDisconnect(device.id);
        return;
      }
      _publish(phase: AppConnectionPhase.discovering);
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
          _log('DISCONNECT REQUESTED during service discovery; releasing the '
              'connection');
        } else {
          _logServices(services);
          report = validateTransportGatt(services);
          for (final finding in report.findings) {
            _log(finding);
          }

          if (report.isUsable) {
            _log('GATT TRANSPORT RESULT: FFE0/FFE1 validated for the '
                'documented LEDDMX transport. The link stays open. No frame '
                'has been sent yet.');
          } else {
            failure = 'GATT VALIDATION FAILED: ${report.blockers.join('; ')}';
            _log(failure);
          }

          if (report.isUsable && supported != null && !_teardownRequested) {
            transport = PluginLedTransport(
              central: _central,
              peripheralId: device.id,
            );
            try {
              await transport
                  .enableNotifications()
                  .timeout(discoveryTimeout);
              _log('NOTIFICATIONS ENABLED on FFE1 (receive-only; password '
                  'replies only)');
            } catch (error, stackTrace) {
              _log('NOTIFICATION SUBSCRIPTION FAILED (commands can still be '
                  'written; password replies will be unavailable)',
                  error: error, stackTrace: stackTrace);
            }

            driver = LeddmxDriver(transport: transport);
            driver.attach(supported);
            controls = LedControlService(
              driver: driver,
              layout: supported.layout,
              log: _log,
            );
            _log('CONTROL API BOUND to ${supported.advertisedName} '
                '(layout=${supported.layout.name}). Commands require an '
                'explicit button press.');
          } else if (report.isUsable && supported == null) {
            controlsBlockedReason =
                'advertised name is not a documented LEDDMX variant; '
                'no command format is implemented for it';
            _log('CONTROLS DISABLED: $controlsBlockedReason');
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
      _driver = driver;
      _transport = transport;
      _controls = controls;
      _publish(
        phase: AppConnectionPhase.connected,
        report: report,
        variant: supported,
        controlsBlockedReason:
            supported == null ? controlsBlockedReason : null,
        error: null,
      );
      _log('CONNECTED: link stays open until Disconnect, link loss or app '
          'disposal. No LED state is known or claimed.');
      return;
    }

    if (driver != null) await driver.dispose();
    _publish(report: report, error: failure);
    await _releaseLink(device.id);
  }

  /// Explicitly releases the current connection.
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
    if (current.phase == AppConnectionPhase.connecting ||
        current.phase == AppConnectionPhase.discovering) {
      _teardownRequested = true;
      _log('DISCONNECT REQUESTED during ${current.phase.name}; the current '
          'attempt will release the link without retrying');
      return;
    }
    if (!current.isConnected) {
      _log('DISCONNECT IGNORED: not connected (${current.phase.name})');
      return;
    }

    _publish(phase: AppConnectionPhase.disconnecting);
    final driver = _driver;
    final transport = _transport;
    final controls = _controls;
    _driver = null;
    _transport = null;
    _controls = null;
    controls?.dispose();
    if (driver != null) await driver.dispose();

    String? failure;
    try {
      _log('DISCONNECTION ATTEMPT: ${selected.id}');
      if (transport != null) {
        await transport.close().timeout(disconnectTimeout);
      } else {
        await _central.disconnect(selected.id).timeout(disconnectTimeout);
      }
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
      _publish(phase: AppConnectionPhase.failed, error: failure);
      return;
    }
    _publish(
      phase: AppConnectionPhase.disconnected,
      selected: null,
      report: null,
      variant: null,
      controlsBlockedReason: null,
      error: null,
    );
  }

  /// Cancels subscriptions, stops discovery, releases a live connection and
  /// disposes the state notifier.
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

    final driver = _driver;
    final transport = _transport;
    final controls = _controls;
    final selected = _state.value.selected;
    _driver = null;
    _transport = null;
    _controls = null;
    controls?.dispose();
    if (driver != null) await driver.dispose();
    if (transport != null) {
      try {
        await transport.close().timeout(disconnectTimeout);
      } catch (_) {
        // Link may already be gone.
      }
    } else if (selected != null && _state.value.isConnected) {
      await _bestEffortDisconnect(selected.id);
    }
    _state.dispose();
  }

  /// Logs a manual observation (separate from a BLE write result).
  void logObservation({required bool ledsChanged, String? note}) {
    final suffix = note == null || note.trim().isEmpty ? '' : '; note: $note';
    _log('USER OBSERVATION: LEDs visibly changed = '
        '${ledsChanged ? 'YES' : 'NO'}$suffix. This is manual evidence and '
        'does not by itself confirm the protocol.');
  }

  void _handleDiscovered(ScannedPeripheral device) {
    if (_disposed || !_scanRequested) return;
    if (_state.value.phase != AppConnectionPhase.scanning) return;

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
        phase: AppConnectionPhase.failed,
        connectedDeviceIds: Set<String>.unmodifiable(connected),
        error: 'CONNECTION LOST: ${event.peripheralId} disconnected; no '
            'automatic reconnect will be attempted',
      );
      unawaited(_dropDriverAfterLinkLoss());
      return;
    }

    _publish(connectedDeviceIds: Set<String>.unmodifiable(connected));
  }

  Future<void> _dropDriverAfterLinkLoss() async {
    final driver = _driver;
    final controls = _controls;
    _driver = null;
    _transport = null;
    _controls = null;
    controls?.dispose();
    if (driver != null) await driver.dispose();
  }

  Future<void> _releaseLink(String peripheralId) async {
    _publish(phase: AppConnectionPhase.disconnecting);
    String? failure;
    try {
      _log('DISCONNECTION ATTEMPT: $peripheralId');
      await _central.disconnect(peripheralId).timeout(disconnectTimeout);
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
      _publish(
        phase: AppConnectionPhase.failed,
        error: _state.value.error ?? failure,
      );
      return;
    }
    if (_teardownRequested) {
      _log('DISCONNECT RESULT: user requested; connection released');
      _publish(
        phase: AppConnectionPhase.disconnected,
        selected: null,
        report: null,
        variant: null,
        controlsBlockedReason: null,
        error: null,
      );
      return;
    }

    _publish(
      phase: AppConnectionPhase.failed,
      error: _state.value.error ?? 'CONNECTION FAILED: transport did not validate',
    );
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
    _publish(phase: AppConnectionPhase.failed, error: '$message: $error');
  }

  void _failMessage(String message) {
    _log(message);
    _publish(phase: AppConnectionPhase.failed, error: message);
  }

  void _publish({
    AppConnectionPhase? phase,
    BleAdapterState? adapterState,
    List<ScannedPeripheral>? devices,
    Object? selected = _keep,
    Object? report = _keep,
    Object? error = _keep,
    Object? variant = _keep,
    Object? controlsBlockedReason = _keep,
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
      variant: variant,
      controlsBlockedReason: controlsBlockedReason,
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
        name: 'WalseyApp',
        error: error,
        stackTrace: stackTrace,
      );
      // Terminal output is intentional: it is the primary diagnostic channel.
      // ignore: avoid_print
      print('[WalseyApp] $message');
    }

    _logLines.add(message);
    if (error != null) _logLines.add('$timestamp  $error');
    while (_logLines.length > _maxLogLines) {
      _logLines.removeAt(0);
    }
    _publish(logs: List<String>.unmodifiable(_logLines));
  }
}
