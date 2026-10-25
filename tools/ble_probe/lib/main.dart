// Read-only BLE probe UI. Purpose: answer, on the real hardware, the questions
// the protocol research could not:
//   1. What name does the controller actually advertise?  (decides the layout)
//   2. Does it expose service FFE0 / characteristic FFE1, and with which
//      properties (write / writeWithoutResponse / notify)?
//   3. Do connect / discoverGATT / disconnect work on Windows and Android?
//
// It NEVER writes a characteristic, descriptor, sends a handshake, subscribes
// to notifications or issues an LED command. The transport workflow lives in
// lib/ble/ and depends on the walsey_led_core protocol types.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import 'ble/ble_port.dart';
import 'ble/gatt_profile.dart';
import 'ble/led_probe_service.dart';
import 'ble/plugin_central.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Walsey BLE probe',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const ProbePage(),
      );
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  /// The unit used for Stage 1 hardware checks. Other LEDDMX variants are still
  /// listed and can be connected manually.
  static const _preferredTargetName = 'LEDDMX-03-6B4A';

  late final LedProbeService _service;
  bool _onlyLed = true;

  @override
  void initState() {
    super.initState();
    final central = PluginBleCentral(log: _logFromAdapter);
    _service = LedProbeService(
      central: central,
      preferredTargetName: _preferredTargetName,
    );
  }

  @override
  void dispose() {
    unawaited(_service.dispose());
    super.dispose();
  }

  void _logFromAdapter(String line) => _service.log(line);

  Future<void> _toggleScan() async {
    if (_service.current.isScanning) {
      await _service.stopScan();
    } else {
      await _service.startScan();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Walsey BLE probe (read-only)')),
      body: ValueListenableBuilder<ProbeState>(
        valueListenable: _service.state,
        builder: (context, state, _) {
          final devices = state.devices
              .where((device) =>
                  !_onlyLed ||
                  (device.name ?? '').toUpperCase().startsWith('LED'))
              .toList();

          return Column(
            children: [
              _Controls(
                state: state,
                onlyLed: _onlyLed,
                onToggleScan: () => unawaited(_toggleScan()),
                onDisconnect: () => unawaited(_service.disconnect()),
                onToggleOnlyLed: (value) => setState(() => _onlyLed = value),
              ),
              _StatusBanner(state: state),
              if (state.report != null) _GattReportCard(report: state.report!),
              Expanded(
                flex: 2,
                child: devices.isEmpty
                    ? Center(
                        child: Text(state.isScanning
                            ? 'Scanning…'
                            : 'No devices. Start a scan.'),
                      )
                    : ListView(
                        children: [
                          for (final device in devices)
                            _DeviceTile(
                              device: device,
                              busy: state.connectionBusy || state.isConnected,
                              isConnected: state.isConnected &&
                                  state.selected?.id == device.id,
                              onConnect: () => unawaited(
                                _service.connect(device),
                              ),
                            ),
                        ],
                      ),
              ),
              const Divider(height: 1),
              Expanded(
                flex: 3,
                child: SelectionArea(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: state.logs.length,
                    itemBuilder: (_, i) => Text(
                      state.logs[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.state,
    required this.onlyLed,
    required this.onToggleScan,
    required this.onDisconnect,
    required this.onToggleOnlyLed,
  });

  final ProbeState state;
  final bool onlyLed;
  final VoidCallback onToggleScan;
  final VoidCallback onDisconnect;
  final ValueChanged<bool> onToggleOnlyLed;

  @override
  Widget build(BuildContext context) {
    // Scanning is refused while connected: only Disconnect may leave the
    // connected state.
    final canScan = !state.isConnected && !state.connectionBusy;
    final canDisconnect = state.isConnected ||
        state.phase == ProbePhase.connecting ||
        state.phase == ProbePhase.discovering;

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton(
            onPressed: canScan ? onToggleScan : null,
            child: Text(state.isScanning ? 'Stop scan' : 'Start scan'),
          ),
          FilledButton.tonal(
            onPressed: canDisconnect ? onDisconnect : null,
            child: const Text('Disconnect'),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(value: onlyLed, onChanged: onToggleOnlyLed),
              const Text('Only names starting "LED"'),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.state});

  final ProbeState state;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = state.phase == ProbePhase.failed;
    return Container(
      width: double.infinity,
      color: failed
          ? colors.errorContainer
          : colors.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        _statusText(state),
        style: TextStyle(
          color: failed ? colors.onErrorContainer : null,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  String _statusText(ProbeState state) {
    final selected = state.selected;
    final name = selected?.name ?? selected?.id ?? 'device';
    return switch (state.phase) {
      ProbePhase.disconnected => state.adapterState == BleAdapterState.poweredOn
          ? 'Disconnected. Bluetooth adapter is on.'
          : 'Disconnected. Adapter state: ${state.adapterState.name}.',
      ProbePhase.scanning => 'Scanning for LED devices…',
      ProbePhase.connecting => 'Connecting to $name…',
      ProbePhase.discovering =>
        'Discovering GATT and validating FFE0/FFE1 (read-only)…',
      ProbePhase.connected =>
        'Connected to $name. The BLE link stays open until you press '
            'Disconnect. Read-only: no frames were sent, so LED control is '
            'NOT verified.',
      ProbePhase.disconnecting => 'Disconnecting…',
      ProbePhase.failed => state.error ?? 'Probe failed.',
    };
  }
}

class _GattReportCard extends StatelessWidget {
  const _GattReportCard({required this.report});

  final TransportGattReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('GATT transport', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final finding in report.findings)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  finding,
                  style: TextStyle(
                    fontSize: 12,
                    color: finding.startsWith('FAIL:')
                        ? theme.colorScheme.error
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.busy,
    required this.isConnected,
    required this.onConnect,
  });

  final ScannedPeripheral device;
  final bool busy;
  final bool isConnected;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final supported = resolveVariant(device.name) is SupportedVariant;
    final name = device.name ?? '(no name)';
    return ListTile(
      enabled: !busy,
      title: Text(supported ? '$name  ·  LEDDMX' : name),
      subtitle: Text(
        '${device.id}\n'
        'RSSI ${device.rssi} · advertised services: '
        '${device.advertisedServiceUuids.length}',
      ),
      isThreeLine: true,
      trailing: Text(isConnected ? 'connected' : 'connect'),
      onTap: busy ? null : onConnect,
    );
  }
}
