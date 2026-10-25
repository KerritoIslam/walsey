import 'dart:async';

import 'package:flutter/material.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';

import 'connection/led_connection_service.dart';
import 'ui/home_page.dart';

void main() => runApp(const WalseyApp());

class WalseyApp extends StatefulWidget {
  const WalseyApp({super.key});

  @override
  State<WalseyApp> createState() => _WalseyAppState();
}

class _WalseyAppState extends State<WalseyApp> {
  late final LedConnectionService _service = LedConnectionService(
    central: PluginBleCentral(),
  );

  @override
  void dispose() {
    unawaited(_service.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Walsey',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: WalseyHomePage(service: _service),
      );
}
