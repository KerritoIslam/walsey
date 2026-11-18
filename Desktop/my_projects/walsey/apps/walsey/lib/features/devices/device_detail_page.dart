import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/connection_presentation.dart';
import '../../app/walsey_navigation.dart';
import '../../connection/led_connection_service.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import 'hardware_test_view.dart';

class DeviceDetailPage extends StatelessWidget {
  const DeviceDetailPage({
    super.key,
    required this.service,
    required this.onNavigate,
  });

  final LedConnectionService service;
  final ValueChanged<WalseyPage> onNavigate;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppConnectionState>(
    valueListenable: service.state,
    builder: (context, state, _) {
      final compact = MediaQuery.sizeOf(context).width < 720;
      final selected = state.selected;
      final controls = service.controls;
      return Scaffold(
        body: SafeArea(
          child: WPageBody(
            compact: compact,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: WalseySpacing.xs),
                  Expanded(
                    child: WPageHeader(
                      title: selected == null
                          ? 'Device details'
                          : deviceLabel(selected),
                      compact: compact,
                      caption: selected == null
                          ? 'No device selected.'
                          : '${selected.id} · RSSI ${selected.rssi}',
                    ),
                  ),
                  WBadge(
                    label: connectionPhaseLabel(state),
                    tone: connectionTone(state),
                  ),
                ],
              ),
              if (selected == null)
                WCard(
                  child: WEmptyState(
                    icon: Icons.bluetooth_disabled,
                    title: 'No device selected',
                    message:
                        'Connect a controller from Devices to inspect it here.',
                    action: FilledButton(
                      onPressed: () {
                        Navigator.of(context).maybePop();
                        onNavigate(WalseyPage.devices);
                      },
                      child: const Text('Go to Devices'),
                    ),
                  ),
                )
              else ...[
                WCard(
                  label: 'Status',
                  trailing: WBadge(
                    label: state.controlsAvailable
                        ? 'Controls ready'
                        : 'Controls unavailable',
                    tone: state.controlsAvailable
                        ? WBadgeTone.online
                        : WBadgeTone.connecting,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(connectionDetail(state), style: WalseyType.body),
                      const SizedBox(height: WalseySpacing.lg),
                      Wrap(
                        spacing: WalseySpacing.sm,
                        runSpacing: WalseySpacing.sm,
                        children: [
                          if (state.controlsAvailable)
                            FilledButton(
                              onPressed: () {
                                Navigator.of(context).maybePop();
                                onNavigate(WalseyPage.studio);
                              },
                              child: const Text('Open Studio'),
                            ),
                          if (state.isConnected)
                            OutlinedButton(
                              onPressed: () =>
                                  unawaited(service.disconnect()),
                              child: const Text('Disconnect'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (state.variant != null)
                  WCard(
                    label: 'Resolved variant',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.variant!.advertisedName,
                          style: WalseyType.rowTitle,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Layout: ${state.variant!.layout.name} · resolved '
                          'only from the advertised LEDDMX name.',
                          style: WalseyType.caption,
                        ),
                      ],
                    ),
                  ),
                if (state.report != null)
                  WCard(
                    label: 'GATT transport',
                    trailing: WBadge(
                      label: state.report!.isUsable ? 'Validated' : 'Blocked',
                      tone: state.report!.isUsable
                          ? WBadgeTone.online
                          : WBadgeTone.error,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final finding in state.report!.findings)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: WalseySpacing.xxs,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  finding.startsWith('FAIL:')
                                      ? Icons.cancel_outlined
                                      : Icons.check_circle_outline,
                                  size: 15,
                                  color: finding.startsWith('FAIL:')
                                      ? WalseyColors.errorText
                                      : WalseyColors.successText,
                                ),
                                const SizedBox(width: WalseySpacing.sm),
                                Expanded(
                                  child: Text(
                                    finding,
                                    style: WalseyType.caption,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                if (controls != null)
                  ValueListenableBuilder<bool>(
                    valueListenable: controls.busy,
                    builder: (context, busy, _) => HardwareTestView(
                      service: service,
                      controls: controls,
                      busy: busy,
                    ),
                  )
                else
                  WCard(
                    label: 'Diagnostics',
                    child: WEmptyState(
                      icon: Icons.lock_outline,
                      title: 'Hardware test unavailable',
                      message: state.controlsBlockedReason ??
                          'Connect to a documented LEDDMX controller to run '
                              'the controlled test procedure.',
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
