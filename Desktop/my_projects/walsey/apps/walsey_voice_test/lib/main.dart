import 'package:flutter/material.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

import 'record_selftest.dart';
import 'voice_test_page.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--record-selftest')) {
    // Diagnostic only: records the real microphone, writes a WAV + JSON and
    // exits. Never reached by the normal `flutter run` / app launch path.
    await runRecordSelfTest(arguments);
    return;
  }
  runApp(const WalseyVoiceTestApp());
}

/// Standalone Stage 2 testbed.
///
/// It parses typed text and recognized speech, and it has no BLE dependency:
/// no code path here can change the LEDs. The main Walsey app is untouched.
class WalseyVoiceTestApp extends StatelessWidget {
  const WalseyVoiceTestApp({
    super.key,
    this.recognizer,
    this.modelStore,
    this.parser,
    this.diagnostics,
  });

  /// Optional fakes for widget tests; production constructs the Vosk adapter.
  final SpeechRecognizer? recognizer;
  final ModelStore? modelStore;
  final VoiceCommandParser? parser;
  final SessionDiagnostics? diagnostics;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Walsey Voice Test',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: VoiceTestPage(
      recognizer: recognizer,
      modelStore: modelStore,
      parser: parser,
      diagnostics: diagnostics,
    ),
  );
}
