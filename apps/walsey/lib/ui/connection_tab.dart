import 'dart:async';

import 'package:flutter/material.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import '../connection/led_connection_service.dart';

class ConnectionTab extends StatefulWidget {
  const ConnectionTab({
    super.key,
    required this.service,
    required this.state,
  });

  final LedConnectionService service;
  final AppConnectionState state;

  @override
  State<ConnectionTab> createState() => _ConnectionTabState();
}

class _ConnectionTabState extends State<ConnectionTab> {
  bool _onlyLed = true;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final service = widget.service;
    final devices = state.devices
        .where((device) =>
            !_onlyLed ||
            (device.name ?? '').toUpperCase().startsWith('LED'))
        .toList();

    // Scanning is refused while connected: only Disconnect leaves that state.
    final canScan = !state.isConnected && !state.connectionBusy;
    final canDisconnect = state.isConnected ||
        state.phase == AppConnectionPhase.connecting ||
        state.phase == AppConnectionPhase.discovering;

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: canScan
                    ? () => unawaited(
                          state.isScanning ? service.stopScan() : service.startScan(),
                        )
                    : null,
                child: Text(state.isScanning ? 'Stop scan' : 'Start scan'),
              ),
              FilledButton.tonal(
                onPressed: canDisconnect
                    ? () => unawaited(service.disconnect())
                    : null,
                child: const Text('Disconnect'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _onlyLed,
                    onChanged: (value) =>
                        setState(() => _onlyLed = value ?? true),
                  ),
                  const Text('Only names starting "LED"'),
                ],
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              'Force-close the vendor app (LED LAMP) before connecting: these '
              'controllers typically accept one central at a time.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (state.report != null) _GattReportCard(report: state.report!),
          Expanded(
            child: devices.isEmpty
                ? Center(
                    child: Text(
                      state.isScanning
                          ? 'Scanning…'
                          : 'No devices. Start a scan.',
                    ),
                  )
                : ListView(
                    children: [
                      for (final device in devices)
                        _DeviceTile(
                          device: device,
                          busy: state.connectionBusy || state.isConnected,
                          isConnected: state.isConnected &&
                              state.selected?.id == device.id,
                          onConnect: () =>
                              unawaited(service.connect(device)),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _GattReportCard extends StatelessWidget {
  const _GattReportCard({required this.report});

  final TransportGattReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
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
    final resolution = resolveVariant(device.name);
    final layout = resolution is SupportedVariant ? resolution.layout : null;
    final name = device.name ?? '(no name)';
    return ListTile(
      enabled: !busy,
      title: Text(layout == null ? name : '$name  ·  LEDDMX ${layout.name}'),
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
