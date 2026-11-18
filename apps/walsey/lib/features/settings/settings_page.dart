import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/walsey_navigation.dart';
import '../../connection/led_connection_service.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/activity_log.dart';
import '../../state/app_settings.dart';
import '../activity/diagnostics_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.activity,
    required this.service,
    required this.onNavigate,
    required this.compact,
  });

  final AppSettingsService settings;
  final ActivityLog activity;
  final LedConnectionService service;
  final ValueChanged<WalseyPage> onNavigate;
  final bool compact;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.settings.value.displayName,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    await widget.settings.setDisplayName(_nameController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Display name saved on this device.')),
    );
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear activity history?'),
        content: const Text(
          'Connection events, commands and voice results stored on this '
          'device will be removed. The controller is not affected.',
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
    if (confirmed != true) return;
    await widget.activity.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Activity history cleared.')),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppSettings>(
    valueListenable: widget.settings.listenable,
    builder: (context, preferences, _) => WPageBody(
      compact: widget.compact,
      children: [
        WPageHeader(
          title: 'Settings',
          caption: 'Appearance, privacy and diagnostics for this device.',
          compact: widget.compact,
        ),
        WResponsiveGrid(
          minChildWidth: 340,
          children: [
            WCard(
              label: 'Profile',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                      hintText: 'Shown on the dashboard',
                    ),
                    onSubmitted: (_) => _saveName(),
                  ),
                  const SizedBox(height: WalseySpacing.md),
                  const Text(
                    'Stored locally. Walsey has no account and sends nothing '
                    'to a server.',
                    style: WalseyType.caption,
                  ),
                  const SizedBox(height: WalseySpacing.lg),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: _saveName,
                      style: FilledButton.styleFrom(
                        backgroundColor: WalseyColors.surfaceRaised,
                        foregroundColor: WalseyColors.text,
                      ),
                      child: const Text('Save name'),
                    ),
                  ),
                ],
              ),
            ),
            WCard(
              label: 'Appearance',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Accent tint',
                    style: WalseyType.caption,
                  ),
                  const SizedBox(height: WalseySpacing.md),
                  Wrap(
                    spacing: WalseySpacing.md,
                    runSpacing: WalseySpacing.md,
                    children: [
                      for (final accent in WalseyAccent.values)
                        Semantics(
                          button: true,
                          selected: preferences.accent == accent,
                          label: accent.label,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => widget.settings.setAccent(accent),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: WalseySpacing.md,
                                vertical: WalseySpacing.sm,
                              ),
                              decoration: BoxDecoration(
                                color: preferences.accent == accent
                                    ? WalseyColors.surfaceRaised
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: preferences.accent == accent
                                      ? accent.color
                                      : WalseyColors.border,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
                                      color: accent.color,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: WalseySpacing.sm),
                                  Text(
                                    accent.label,
                                    style: WalseyType.caption.copyWith(
                                      color: preferences.accent == accent
                                          ? WalseyColors.text
                                          : WalseyColors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: WalseySpacing.lg),
                  const Divider(height: 1),
                  WToggleRow(
                    title: 'Show diagnostic dock',
                    caption:
                        'Desktop only. Keeps the raw connection log visible '
                        'below the main content.',
                    value: preferences.showDiagnosticsPanel,
                    onChanged: widget.settings.setShowDiagnosticsPanel,
                  ),
                ],
              ),
            ),
            WCard(
              label: 'Voice',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Whisper is the primary offline engine; Vosk is an '
                    'explicit fallback. Models are installed only from the '
                    'Assistant model manager.',
                    style: WalseyType.caption,
                  ),
                  const SizedBox(height: WalseySpacing.lg),
                  WToggleRow(
                    title: 'Spoken responses',
                    caption:
                        'Speak a short result after a voice command using the '
                        'system voice. Off by default; nothing is downloaded.',
                    value: preferences.spokenResponses,
                    onChanged: widget.settings.setSpokenResponses,
                  ),
                  const SizedBox(height: WalseySpacing.lg),
                  OutlinedButton.icon(
                    onPressed: () => widget.onNavigate(WalseyPage.assistant),
                    icon: const Icon(Icons.mic_none, size: 18),
                    label: const Text('Open Assistant'),
                  ),
                ],
              ),
            ),
            WCard(
              label: 'Devices and permissions',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Android: scanning needs Bluetooth and the Nearby devices '
                    'permission. Windows: Bluetooth must be on, and the vendor '
                    'app should be closed because these controllers accept one '
                    'central at a time.',
                    style: WalseyType.caption,
                  ),
                  const SizedBox(height: WalseySpacing.lg),
                  OutlinedButton.icon(
                    onPressed: () => widget.onNavigate(WalseyPage.devices),
                    icon: const Icon(Icons.devices_other_outlined, size: 18),
                    label: const Text('Manage devices'),
                  ),
                ],
              ),
            ),
            WCard(
              label: 'Privacy and data',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.activity.entries.length} activity entries are '
                    'stored locally. Nothing is uploaded: recognition is '
                    'offline and there is no account or telemetry.',
                    style: WalseyType.caption,
                  ),
                  const SizedBox(height: WalseySpacing.lg),
                  TextButton.icon(
                    onPressed: _clearHistory,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Clear activity history'),
                  ),
                ],
              ),
            ),
            WCard(
              label: 'About and diagnostics',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Walsey · Stage 2 build\n'
                    '${switch (defaultTargetPlatform) {
                      TargetPlatform.windows => 'Windows',
                      TargetPlatform.android => 'Android',
                      TargetPlatform.iOS => 'iOS',
                      TargetPlatform.macOS => 'macOS',
                      TargetPlatform.linux => 'Linux',
                      TargetPlatform.fuchsia => 'Fuchsia',
                    }} · offline core',
                    style: WalseyType.caption,
                  ),
                  const SizedBox(height: WalseySpacing.lg),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            DiagnosticsPage(service: widget.service),
                      ),
                    ),
                    icon: const Icon(Icons.terminal, size: 18),
                    label: const Text('Open diagnostics'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const Text(
          'No account, no cloud, no telemetry. Preferences and history stay on '
          'this device.',
          style: WalseyType.caption,
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}
