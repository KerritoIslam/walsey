import 'package:flutter/material.dart';

import '../../app/walsey_navigation.dart';
import '../../connection/led_connection_service.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/activity_log.dart';
import 'diagnostics_page.dart';

enum _ActivityFilter { all, commands, connections, voice }

class ActivityPage extends StatefulWidget {
  const ActivityPage({
    super.key,
    required this.activity,
    required this.service,
    required this.onNavigate,
    required this.compact,
  });

  final ActivityLog activity;
  final LedConnectionService service;
  final ValueChanged<WalseyPage> onNavigate;
  final bool compact;

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  _ActivityFilter _filter = _ActivityFilter.all;

  bool _matches(ActivityEntry entry) => switch (_filter) {
    _ActivityFilter.all => true,
    _ActivityFilter.commands => entry.kind == ActivityKind.command,
    _ActivityFilter.connections => entry.kind == ActivityKind.connection,
    _ActivityFilter.voice => entry.kind == ActivityKind.voice,
  };

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear activity history?'),
        content: const Text(
          'This removes the saved history of connection events, commands and '
          'voice results. It does not change the controller or its settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.activity.clear();
  }

  @override
  Widget build(BuildContext context) => WPageBody(
    compact: widget.compact,
    children: [
      WPageHeader(
        title: 'Activity',
        caption:
            'Connection events, commands and voice outcomes recorded by this '
            'app. Stored locally.',
        compact: widget.compact,
        actions: [
          if (widget.compact)
            IconButton(
              tooltip: 'Back to dashboard',
              onPressed: () => widget.onNavigate(WalseyPage.home),
              icon: const Icon(Icons.arrow_back),
            ),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    DiagnosticsPage(service: widget.service),
              ),
            ),
            icon: const Icon(Icons.terminal, size: 18),
            label: const Text('Diagnostics'),
          ),
          TextButton.icon(
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Clear'),
          ),
        ],
      ),
      Wrap(
        spacing: WalseySpacing.sm,
        runSpacing: WalseySpacing.sm,
        children: [
          for (final filter in _ActivityFilter.values)
            ChoiceChip(
              label: Text(switch (filter) {
                _ActivityFilter.all => 'All',
                _ActivityFilter.commands => 'Commands',
                _ActivityFilter.connections => 'Connections',
                _ActivityFilter.voice => 'Voice',
              }),
              selected: _filter == filter,
              onSelected: (_) => setState(() => _filter = filter),
            ),
        ],
      ),
      ListenableBuilder(
        listenable: widget.activity,
        builder: (context, _) {
          final entries = widget.activity.entries.where(_matches).toList();
          return WCard(
            label: 'History',
            child: entries.isEmpty
                ? WEmptyState(
                    icon: Icons.history,
                    title: 'Nothing here yet',
                    message: _filter == _ActivityFilter.all
                        ? 'Connect a device or send a command. Every event is '
                              'recorded with the real result.'
                        : 'No ${_filter.name} events have been recorded.',
                  )
                : Column(
                    children: [
                      for (var index = 0; index < entries.length; index++)
                        _ActivityRow(
                          entry: entries[index],
                          showDivider: index != entries.length - 1,
                        ),
                    ],
                  ),
          );
        },
      ),
      const WInfoBanner(
        tone: WInfoTone.info,
        title: 'What history means',
        message:
            'A command entry reports the BLE write result. It never claims '
            'that the LEDs changed — the protocol has no state read-back. '
            'Handshake passwords are redacted before anything is stored.',
      ),
    ],
  );
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.entry, required this.showDivider});

  final ActivityEntry entry;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
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
    final status = switch (entry.success) {
      true => 'Written',
      false => 'Failed',
      null => null,
    };
    return WListRow(
      title: entry.title,
      caption: entry.detail.isEmpty ? null : entry.detail,
      showDivider: showDivider,
      leading: Icon(icon, size: 18, color: color),
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(entry.timeLabel, style: WalseyType.caption),
          if (status != null) ...[
            const SizedBox(height: 2),
            WBadge(
              label: status,
              tone: entry.success == true
                  ? WBadgeTone.online
                  : WBadgeTone.error,
            ),
          ],
        ],
      ),
    );
  }
}
