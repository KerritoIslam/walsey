import 'dart:async';

import 'package:flutter/material.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import 'app/app_shell.dart';
import 'connection/led_connection_service.dart';
import 'control/led_control_service.dart';
import 'design/theme.dart';
import 'state/activity_log.dart';
import 'state/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettingsService.load();
  final activity = await ActivityLog.load();
  runApp(WalseyApp(settings: settings, activity: activity));
}

class WalseyApp extends StatefulWidget {
  const WalseyApp({
    super.key,
    required this.settings,
    required this.activity,
  });

  final AppSettingsService settings;
  final ActivityLog activity;

  @override
  State<WalseyApp> createState() => _WalseyAppState();
}

class _WalseyAppState extends State<WalseyApp> {
  late final LedConnectionService _service = LedConnectionService(
    central: PluginBleCentral(),
    onCommand: _recordCommand,
  );

  void _recordCommand(CommandActivity activity) {
    final result = activity.result;
    final (title, detail) = switch (result) {
      CommandSent(:final hex, :final writeMode) => (
        '${activity.name} · write completed',
        'Frame $hex · ${writeMode.name} · LED response not confirmed',
      ),
      CommandUnsupported(:final reason) => (
        '${activity.name} · unsupported',
        reason,
      ),
      CommandFailed(:final message) => (
        '${activity.name} · failed',
        message,
      ),
    };
    widget.activity.add(
      kind: ActivityKind.command,
      title: title,
      detail: detail,
      success: result is CommandSent,
    );
  }

  @override
  void dispose() {
    unawaited(_service.dispose());
    widget.settings.dispose();
    widget.activity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppSettings>(
    valueListenable: widget.settings.listenable,
    builder: (context, settings, _) {
      final theme = buildWalseyTheme(accent: settings.accent);
      return MaterialApp(
        title: 'Walsey',
        debugShowCheckedModeBanner: false,
        theme: theme,
        darkTheme: theme,
        themeMode: ThemeMode.dark,
        home: WalseyShell(
          service: _service,
          settings: widget.settings,
          activity: widget.activity,
        ),
      );
    },
  );
}
