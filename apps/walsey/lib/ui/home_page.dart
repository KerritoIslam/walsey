import 'package:flutter/material.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';

import '../connection/led_connection_service.dart';
import 'connection_tab.dart';
import 'control_tab.dart';
import 'hardware_test_tab.dart';
import 'log_view.dart';

class WalseyHomePage extends StatelessWidget {
  const WalseyHomePage({super.key, required this.service});

  final LedConnectionService service;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Walsey'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Connection'),
              Tab(text: 'Controls'),
              Tab(text: 'Hardware test'),
            ],
          ),
        ),
        body: ValueListenableBuilder<AppConnectionState>(
          valueListenable: service.state,
          builder: (context, state, _) {
            final controls = service.controls;
            return Column(
              children: [
                _StatusBanner(state: state),
                Expanded(
                  child: TabBarView(
                    children: [
                      ConnectionTab(service: service, state: state),
                      controls == null
                          ? _ControlsUnavailable(state: state)
                          : ValueListenableBuilder<bool>(
                              valueListenable: controls.busy,
                              builder: (context, busy, _) => ControlTab(
                                controls: controls,
                                busy: busy,
                              ),
                            ),
                      controls == null
                          ? _ControlsUnavailable(state: state)
                          : ValueListenableBuilder<bool>(
                              valueListenable: controls.busy,
                              builder: (context, busy, _) => HardwareTestTab(
                                service: service,
                                controls: controls,
                                busy: busy,
                              ),
                            ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                SizedBox(
                  height: 190,
                  child: LogView(logs: state.logs),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.state});

  final AppConnectionState state;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = state.phase == AppConnectionPhase.failed;
    return Container(
      width: double.infinity,
      color: failed
          ? colors.errorContainer
          : colors.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        statusText(state),
        style: TextStyle(
          color: failed ? colors.onErrorContainer : null,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

String statusText(AppConnectionState state) {
  final selected = state.selected;
  final name = selected?.name ?? selected?.id ?? 'device';
  return switch (state.phase) {
    AppConnectionPhase.disconnected =>
      state.adapterState == BleAdapterState.poweredOn
          ? 'Disconnected. Bluetooth adapter is on.'
          : 'Disconnected. Adapter state: ${state.adapterState.name}.',
    AppConnectionPhase.scanning => 'Scanning for LED devices…',
    AppConnectionPhase.connecting => 'Connecting to $name…',
    AppConnectionPhase.discovering =>
      'Discovering GATT and validating FFE0/FFE1…',
    AppConnectionPhase.connected =>
      state.controlsAvailable
          ? 'Connected to '
              '${state.variant?.advertisedName ?? name}. Link stays open until '
              'Disconnect or link loss. No LED state is known or claimed.'
          : 'Connected to $name. Controls are disabled: '
              '${state.controlsBlockedReason ?? 'transport not usable'}.',
    AppConnectionPhase.disconnecting => 'Disconnecting…',
    AppConnectionPhase.failed => state.error ?? 'Connection failed.',
  };
}

class _ControlsUnavailable extends StatelessWidget {
  const _ControlsUnavailable({required this.state});

  final AppConnectionState state;

  @override
  Widget build(BuildContext context) {
    final reason = state.controlsBlockedReason ??
        (state.isConnected
            ? 'transport not usable'
            : 'connect to a documented LEDDMX controller first');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 32),
            const SizedBox(height: 8),
            const Text('No command API available'),
            const SizedBox(height: 4),
            Text(reason, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
