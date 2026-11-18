import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/connection_presentation.dart';
import '../../app/walsey_navigation.dart';
import '../../connection/led_connection_service.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/activity_log.dart';
import '../../state/app_settings.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.service,
    required this.state,
    required this.settings,
    required this.activity,
    required this.onNavigate,
    required this.compact,
  });

  final LedConnectionService service;
  final AppConnectionState state;
  final AppSettingsService settings;
  final ActivityLog activity;
  final ValueChanged<WalseyPage> onNavigate;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final preferences = settings.value;
    return WPageBody(
      compact: compact,
      children: [
        WPageHeader(
          title: 'Dashboard',
          compact: compact,
          caption: [
            formatShortDate(DateTime.now()),
            if (preferences.displayName.trim().isNotEmpty)
              '· ${preferences.displayName.trim()}',
          ].join(' '),
          actions: [
            WBadge(
              label: connectionPhaseLabel(state),
              tone: connectionTone(state),
            ),
            if (compact)
              IconButton(
                tooltip: 'Activity',
                onPressed: () => onNavigate(WalseyPage.activity),
                icon: const Icon(Icons.history),
              ),
          ],
        ),
        _ConnectionCard(
          state: state,
          service: service,
          settings: settings,
          onNavigate: onNavigate,
        ),
        const _SectionHeading(
          title: 'Your workspace',
          caption: 'Everything here talks to real services in this build.',
        ),
        WResponsiveGrid(
          children: [
            _QuickCard(
              icon: Icons.lightbulb_outline,
              title: 'LED Studio',
              description: state.controlsAvailable
                  ? 'Colour, brightness, effects and saved favourites for the '
                        'connected controller.'
                  : 'Colour and brightness controls become available once a '
                        'documented LEDDMX controller is connected.',
              action: state.controlsAvailable ? 'Open Studio' : 'View devices',
              onTap: () => onNavigate(
                state.controlsAvailable
                    ? WalseyPage.studio
                    : WalseyPage.devices,
              ),
            ),
            _QuickCard(
              icon: Icons.mic_none,
              title: 'Assistant',
              description:
                  'Push-to-talk recognition runs offline with Whisper, then the '
                  'existing parser decides what the sentence means.',
              action: 'Open Assistant',
              onTap: () => onNavigate(WalseyPage.assistant),
            ),
            _QuickCard(
              icon: Icons.devices_other_outlined,
              title: 'Devices',
              description: state.isConnected
                  ? 'One controller connected. Scan stays disabled until you '
                        'disconnect.'
                  : 'Scan for nearby LEDDMX controllers and inspect the GATT '
                        'transport before sending anything.',
              action: 'Manage devices',
              onTap: () => onNavigate(WalseyPage.devices),
            ),
          ],
        ),
        const _SectionHeading(
          title: 'The ecosystem',
          caption: 'Designed and visible, but honest about what is not built.',
        ),
        WResponsiveGrid(
          minChildWidth: 300,
          children: [
            _PlannedCard(
              icon: Icons.sync_alt,
              title: 'Phone ↔ PC',
              description:
                  'Files, clipboard, notifications and remote input between '
                  'Walsey devices. No transport service exists in this build.',
              onTap: () => onNavigate(WalseyPage.connect),
            ),
            _PlannedCard(
              icon: Icons.bolt_outlined,
              title: 'Automations',
              description:
                  'Triggers, conditions and actions over supported devices. '
                  'The execution engine and storage are not implemented yet.',
              onTap: () => onNavigate(WalseyPage.automations),
            ),
          ],
        ),
        _RecentActivity(activity: activity, onNavigate: onNavigate),
        const _HonestyNote(),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.caption});

  final String title;
  final String caption;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: WalseyType.sectionTitle),
      const SizedBox(height: 2),
      Text(caption, style: WalseyType.caption),
    ],
  );
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.state,
    required this.service,
    required this.settings,
    required this.onNavigate,
  });

  final AppConnectionState state;
  final LedConnectionService service;
  final AppSettingsService settings;
  final ValueChanged<WalseyPage> onNavigate;

  @override
  Widget build(BuildContext context) {
    final device = state.selected;
    final name = state.isConnected
        ? deviceLabel(device)
        : 'No controller connected';
    final lastDevice = settings.value.lastDeviceName;

    final actions = <Widget>[];
    if (state.isConnected) {
      actions.addAll([
        OutlinedButton(
          onPressed: () => unawaited(service.disconnect()),
          child: const Text('Disconnect'),
        ),
        FilledButton(
          onPressed: () => onNavigate(
            state.controlsAvailable ? WalseyPage.studio : WalseyPage.devices,
          ),
          child: Text(state.controlsAvailable ? 'Open Studio' : 'Details'),
        ),
      ]);
    } else if (state.isScanning) {
      actions.add(
        FilledButton(
          onPressed: () => onNavigate(WalseyPage.devices),
          child: const Text('View scan'),
        ),
      );
    } else if (state.connectionBusy) {
      actions.add(
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else {
      actions.addAll([
        FilledButton(
          onPressed: () {
            unawaited(service.startScan());
            onNavigate(WalseyPage.devices);
          },
          child: const Text('Start scan'),
        ),
        OutlinedButton(
          onPressed: () => onNavigate(WalseyPage.devices),
          child: const Text('Devices'),
        ),
      ]);
    }

    return WCard(
      label: 'Connection',
      trailing: WBadge(
        label: connectionPhaseLabel(state),
        tone: connectionTone(state),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: state.isConnected
                      ? WalseyColors.primaryTint
                      : WalseyColors.surfaceRaised,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  state.isConnected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  color: state.isConnected
                      ? WalseyColors.primaryText
                      : WalseyColors.textMuted,
                ),
              ),
              const SizedBox(width: WalseySpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: WalseyType.sectionTitle),
                    const SizedBox(height: 2),
                    Text(connectionDetail(state), style: WalseyType.caption),
                  ],
                ),
              ),
            ],
          ),
          if (state.isScanning || state.connectionBusy) ...[
            const SizedBox(height: WalseySpacing.lg),
            const LinearProgressIndicator(),
          ],
          if (state.phase == AppConnectionPhase.failed &&
              state.error != null) ...[
            const SizedBox(height: WalseySpacing.lg),
            WInfoBanner(
              tone: WInfoTone.error,
              title: 'Connection unavailable',
              message: state.error!,
            ),
          ],
          if (!state.isConnected && lastDevice != null) ...[
            const SizedBox(height: WalseySpacing.md),
            Text(
              'Last connected: $lastDevice'
              '${settings.value.lastDeviceAt == null ? '' : ' · '
                  '${formatShortDate(settings.value.lastDeviceAt!)}'}',
              style: WalseyType.caption,
            ),
          ],
          const SizedBox(height: WalseySpacing.xxl),
          Wrap(
            spacing: WalseySpacing.sm,
            runSpacing: WalseySpacing.sm,
            children: actions,
          ),
          if (state.isConnected && !state.controlsAvailable) ...[
            const SizedBox(height: WalseySpacing.lg),
            WInfoBanner(
              tone: WInfoTone.warning,
              title: 'Controls disabled',
              message:
                  state.controlsBlockedReason ??
                  'The advertised name is not a documented LEDDMX variant.',
            ),
          ],
        ],
      ),
    );
  }
}

class _QuickCard extends StatelessWidget {
  const _QuickCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: WalseyColors.primaryTint,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: WalseyColors.primaryText),
            ),
            const SizedBox(width: WalseySpacing.md),
            Text(title, style: WalseyType.sectionTitle),
          ],
        ),
        const SizedBox(height: WalseySpacing.lg),
        Text(description, style: WalseyType.caption),
        const SizedBox(height: WalseySpacing.xxl),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(action),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_forward, size: 16),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _PlannedCard extends StatelessWidget {
  const _PlannedCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WCard(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: WalseyColors.textMuted),
        const SizedBox(width: WalseySpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: WalseyType.rowTitle)),
                  const WBadge(label: 'Planned', tone: WBadgeTone.planned),
                ],
              ),
              const SizedBox(height: WalseySpacing.xs),
              Text(description, style: WalseyType.caption),
            ],
          ),
        ),
        const SizedBox(width: WalseySpacing.sm),
        IconButton(
          tooltip: 'Open $title',
          onPressed: onTap,
          icon: const Icon(Icons.arrow_forward, size: 18),
        ),
      ],
    ),
  );
}

class _RecentActivity extends StatelessWidget {
  const _RecentActivity({required this.activity, required this.onNavigate});

  final ActivityLog activity;
  final ValueChanged<WalseyPage> onNavigate;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: activity,
    builder: (context, _) {
      final entries = activity.entries.take(4).toList();
      return WCard(
        label: 'Recent activity',
        trailing: TextButton(
          onPressed: () => onNavigate(WalseyPage.activity),
          child: const Text('View all'),
        ),
        child: entries.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: WalseySpacing.md,
                ),
                child: Text(
                  'No activity yet. Connection events, commands and voice '
                  'results will appear here.',
                  style: WalseyType.caption,
                ),
              )
            : Column(
                children: [
                  for (var index = 0; index < entries.length; index++)
                    WListRow(
                      title: entries[index].title,
                      caption: entries[index].detail,
                      showDivider: index != entries.length - 1,
                      leading: _activityIcon(entries[index]),
                      trailing: WBadge(
                        label: entries[index].timeLabel,
                        tone: WBadgeTone.offline,
                      ),
                    ),
                ],
              ),
      );
    },
  );
}

Widget _activityIcon(ActivityEntry entry) {
  final icon = switch (entry.kind) {
    ActivityKind.command => Icons.lightbulb_outline,
    ActivityKind.connection => Icons.bluetooth,
    ActivityKind.voice => Icons.mic_none,
    ActivityKind.system => Icons.info_outline,
  };
  final color = switch (entry.success) {
    true => WalseyColors.successText,
    false => WalseyColors.errorText,
    null => WalseyColors.textMuted,
  };
  return Icon(icon, size: 18, color: color);
}

class _HonestyNote extends StatelessWidget {
  const _HonestyNote();

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.lock_outline, size: 14, color: WalseyColors.textMuted),
      const SizedBox(width: WalseySpacing.sm),
      Expanded(
        child: Text(
          'Walsey never sends a frame automatically, not even the handshake. '
          'A BLE write is reported as a completed write — never as confirmed '
          'LED behaviour.',
          style: WalseyType.caption,
        ),
      ),
    ],
  );
}
