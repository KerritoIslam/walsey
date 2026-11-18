import 'dart:async';

import 'package:flutter/material.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import '../../app/connection_presentation.dart';
import '../../app/walsey_navigation.dart';
import '../../connection/led_connection_service.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import 'device_detail_page.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({
    super.key,
    required this.service,
    required this.state,
    required this.onNavigate,
    required this.compact,
  });

  final LedConnectionService service;
  final AppConnectionState state;
  final ValueChanged<WalseyPage> onNavigate;
  final bool compact;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _supportedOnly = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final service = widget.service;
    final canScan = !state.isConnected && !state.connectionBusy;
    final devices = state.devices
        .where(
          (device) =>
              !_supportedOnly ||
              resolveVariant(device.name) is SupportedVariant,
        )
        .toList();
    final adapterOff = state.adapterState != BleAdapterState.poweredOn;

    return WPageBody(
      compact: widget.compact,
      children: [
        WPageHeader(
          title: 'Devices',
          caption:
              'Scan, validate and connect. One link at a time; scanning is '
              'refused while connected.',
          compact: widget.compact,
          actions: [
            if (state.isScanning)
              FilledButton.icon(
                onPressed: canScan
                    ? () => unawaited(service.stopScan())
                    : null,
                icon: const Icon(Icons.stop, size: 18),
                label: const Text('Stop scan'),
              )
            else
              FilledButton.icon(
                onPressed: canScan
                    ? () => unawaited(service.startScan())
                    : null,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('Start scan'),
              ),
            if (widget.compact)
              IconButton(
                tooltip: 'Device details',
                onPressed: state.selected == null
                    ? null
                    : () => _openDetail(context),
                icon: const Icon(Icons.tune),
              ),
          ],
        ),
        if (adapterOff)
          WInfoBanner(
            tone: WInfoTone.error,
            title: 'Bluetooth is ${state.adapterState.name}',
            message:
                'Turn on Bluetooth and grant the Nearby devices permission '
                'before scanning.',
          ),
        if (state.isConnected || state.phase == AppConnectionPhase.failed)
          _ConnectedCard(
            state: state,
            service: service,
            onNavigate: widget.onNavigate,
            onOpenDetail: () => _openDetail(context),
          ),
        WCard(
          label: 'Nearby devices',
          trailing: TextButton.icon(
            onPressed: () =>
                setState(() => _supportedOnly = !_supportedOnly),
            icon: Icon(
              _supportedOnly ? Icons.check_box : Icons.check_box_outline_blank,
              size: 16,
            ),
            label: const Text('Supported only'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.isScanning) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: WalseySpacing.md),
              ],
              if (devices.isEmpty)
                state.isScanning
                    ? const Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: WalseySpacing.giant,
                        ),
                        child: WEmptyState(
                          icon: Icons.bluetooth_searching,
                          title: 'Searching…',
                          message:
                              'Keep the controller awake and close the vendor '
                              'app. Devices appear here as they advertise.',
                        ),
                      )
                    : WEmptyState(
                        icon: Icons.bluetooth_disabled,
                        title: 'No devices found',
                        message:
                            'Start a scan to look for nearby LEDDMX '
                            'controllers. Force-close the vendor app first: '
                            'these controllers usually accept one central at a '
                            'time.',
                        action: FilledButton(
                          onPressed: canScan
                              ? () => unawaited(service.startScan())
                              : null,
                          child: const Text('Start scan'),
                        ),
                      )
                  else
                    for (var index = 0; index < devices.length; index++)
                      _DeviceRow(
                        device: devices[index],
                        state: state,
                        onConnect: () =>
                            unawaited(service.connect(devices[index])),
                      ),
            ],
          ),
        ),
        const WInfoBanner(
          tone: WInfoTone.info,
          title: 'Before connecting',
          message:
              'Force-close the vendor app (LED LAMP). Walsey validates '
              'FFE0/FFE1, then keeps the link open without sending a frame. '
              'Nothing is written until you press a command.',
        ),
      ],
    );
  }

  void _openDetail(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeviceDetailPage(
          service: widget.service,
          onNavigate: widget.onNavigate,
        ),
      ),
    );
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({
    required this.state,
    required this.service,
    required this.onNavigate,
    required this.onOpenDetail,
  });

  final AppConnectionState state;
  final LedConnectionService service;
  final ValueChanged<WalseyPage> onNavigate;
  final VoidCallback onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final connected = state.isConnected;
    return WCard(
      label: connected ? 'Connected controller' : 'Last connection attempt',
      trailing: WBadge(
        label: connectionPhaseLabel(state),
        tone: connectionTone(state),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            connected
                ? deviceLabel(state.selected)
                : (state.selected?.name ?? 'Connection failed'),
            style: WalseyType.sectionTitle,
          ),
          const SizedBox(height: 2),
          Text(connectionDetail(state), style: WalseyType.caption),
          if (state.variant != null) ...[
            const SizedBox(height: WalseySpacing.sm),
            Text(
              'Variant ${state.variant!.advertisedName} · layout '
              '${state.variant!.layout.name}',
              style: WalseyType.caption.copyWith(color: WalseyColors.textSecondary),
            ),
          ],
          if (connected && !state.controlsAvailable) ...[
            const SizedBox(height: WalseySpacing.lg),
            WInfoBanner(
              tone: WInfoTone.warning,
              title: 'Controls disabled',
              message:
                  state.controlsBlockedReason ??
                  'No command format is implemented for this advertised name.',
            ),
          ],
          if (state.error != null) ...[
            const SizedBox(height: WalseySpacing.lg),
            WInfoBanner(
              tone: WInfoTone.error,
              title: 'Error',
              message: state.error!,
            ),
          ],
          const SizedBox(height: WalseySpacing.xxl),
          Wrap(
            spacing: WalseySpacing.sm,
            runSpacing: WalseySpacing.sm,
            children: [
              if (connected)
                FilledButton(
                  onPressed: () => onNavigate(
                    state.controlsAvailable
                        ? WalseyPage.studio
                        : WalseyPage.devices,
                  ),
                  child: Text(
                    state.controlsAvailable ? 'Open Studio' : 'Devices',
                  ),
                ),
              OutlinedButton(
                onPressed: onOpenDetail,
                child: const Text('Device details'),
              ),
              if (connected)
                OutlinedButton(
                  onPressed: () => unawaited(service.disconnect()),
                  child: const Text('Disconnect'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.state,
    required this.onConnect,
  });

  final ScannedPeripheral device;
  final AppConnectionState state;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final resolution = resolveVariant(device.name);
    final supported = resolution is SupportedVariant;
    final isTarget = state.selected?.id == device.id;
    final connected = isTarget && state.isConnected;
    final connecting = isTarget &&
        (state.phase == AppConnectionPhase.connecting ||
            state.phase == AppConnectionPhase.discovering);
    final canConnect = !state.isConnected && !state.connectionBusy;

    return WListRow(
      title: device.name ?? '(no name)',
      caption: '${device.id} · RSSI ${device.rssi} · '
          '${device.advertisedServiceUuids.length} advertised services'
          '${supported ? ' · LEDDMX ${resolution.layout.name}' : ''}',
      leading: Icon(
        supported ? Icons.lightbulb_outline : Icons.bluetooth,
        color: supported
            ? WalseyColors.primaryText
            : WalseyColors.textMuted,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          WBadge(
            label: connected
                ? 'Online'
                : connecting
                ? 'Connecting'
                : supported
                ? 'Supported'
                : 'Not supported',
            tone: connected
                ? WBadgeTone.online
                : connecting
                ? WBadgeTone.connecting
                : supported
                ? WBadgeTone.planned
                : WBadgeTone.unsupported,
          ),
          const SizedBox(width: WalseySpacing.md),
          if (connected)
            const Icon(
              Icons.link,
              size: 18,
              color: WalseyColors.successText,
            )
          else
            FilledButton.tonal(
              onPressed: canConnect ? onConnect : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(88, 44),
                backgroundColor: WalseyColors.surfaceRaised,
                foregroundColor: WalseyColors.text,
              ),
              child: Text(connecting ? '…' : 'Connect'),
            ),
        ],
      ),
    );
  }
}
