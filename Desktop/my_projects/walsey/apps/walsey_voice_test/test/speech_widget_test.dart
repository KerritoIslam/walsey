import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';
import 'package:walsey_voice_test/main.dart';

import 'support/fakes.dart';

Future<void> pumpApp(
  WidgetTester tester,
  FakeSpeechRecognizer recognizer, {
  FakeModelStore? store,
  SessionDiagnostics? diagnostics,
}) async {
  // The Stage 2 page is much taller than the 800x600 default surface; a tall
  // phone-sized surface keeps every button hit-testable.
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    WalseyVoiceTestApp(
      recognizer: recognizer,
      modelStore: store ?? FakeModelStore(),
      diagnostics: diagnostics,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> startListening(WidgetTester tester) async {
  await tester.tap(find.text('Start listening'));
  await tester.pumpAndSettle();
}

void main() {
  late FakeSpeechRecognizer recognizer;

  setUp(() {
    recognizer = FakeSpeechRecognizer();
  });

  testWidgets('mic starts a session, then parses the final transcript', (
    tester,
  ) async {
    await pumpApp(tester, recognizer);

    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Model installed'), findsOneWidget);

    await startListening(tester);
    expect(find.text('Listening…'), findsOneWidget);
    expect(recognizer.startCalls, 1);

    recognizer.emit(const SpeechPartialTranscript('set bright'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"set bright"'), findsOneWidget);

    await tester.tap(find.text('Stop & recognize'));
    await tester.pumpAndSettle();
    // Shown both in the status chip and on the disabled button.
    expect(find.text('Recognizing…'), findsWidgets);

    recognizer.emit(const SpeechFinalTranscript('Set brightness to 50 percent'));
    await tester.pumpAndSettle();

    expect(find.text('Recognized'), findsOneWidget);
    expect(find.text('Recognized text'), findsOneWidget);
    expect(find.text('Set brightness to 50 percent'), findsWidgets);
    expect(find.text('Set brightness'), findsOneWidget);
    expect(find.text('setBrightness'), findsOneWidget);
    expect(find.text('Brightness: 50%'), findsOneWidget);
    expect(find.text('Valid command'), findsWidgets);
    expect(find.text('Recognized speech'), findsOneWidget);
    expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
    expect(find.textContaining('Nothing was executed'), findsOneWidget);
  });

  testWidgets('recognized unsupported text shows the parser failure', (
    tester,
  ) async {
    await pumpApp(tester, recognizer);
    await startListening(tester);

    recognizer.emit(const SpeechFinalTranscript('Tell me a joke'));
    await tester.pumpAndSettle();

    expect(find.text('Unsupported command'), findsWidgets);
    expect(find.text('Valid command'), findsNothing);
    expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
  });

  testWidgets('recognized invalid parameter is rejected, not clamped', (
    tester,
  ) async {
    await pumpApp(tester, recognizer);
    await startListening(tester);

    recognizer.emit(
      const SpeechFinalTranscript('Set brightness to 150 percent'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Invalid parameter'), findsWidgets);
    expect(
      find.textContaining('Brightness must be 0..100 percent, got 150'),
      findsOneWidget,
    );
  });

  testWidgets('cancel discards the session and ignores a late result', (
    tester,
  ) async {
    await pumpApp(tester, recognizer);
    await startListening(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Cancelled'), findsOneWidget);
    expect(recognizer.cancelCalls, 1);

    recognizer.emit(const SpeechFinalTranscript('Turn the lights on'));
    await tester.pumpAndSettle();

    expect(find.text('Recognized text'), findsNothing);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('no speech is reported instead of keeping old text', (
    tester,
  ) async {
    await pumpApp(tester, recognizer);

    await startListening(tester);
    recognizer.emit(const SpeechFinalTranscript('Turn the lights on'));
    await tester.pumpAndSettle();
    expect(find.text('Recognized text'), findsOneWidget);

    await startListening(tester);
    expect(find.text('Recognized text'), findsNothing);

    recognizer.emit(const SpeechNoSpeechDetected());
    await tester.pumpAndSettle();

    expect(find.text('No speech detected'), findsWidgets);
    expect(find.text('Recognized text'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a failed session shows an error and retry starts again', (
    tester,
  ) async {
    recognizer.availability = const SpeechUnavailable(
      kind: SpeechFailureKind.permissionDenied,
      message: 'Microphone permission was denied by the system.',
    );
    await pumpApp(tester, recognizer);

    await startListening(tester);

    expect(find.text('Microphone permission denied'), findsOneWidget);
    expect(
      find.textContaining('denied by the system'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);

    recognizer.availability = const SpeechReady();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Listening…'), findsOneWidget);
    expect(find.text('Microphone permission denied'), findsNothing);
  });

  testWidgets('missing model is actionable and typed input still works', (
    tester,
  ) async {
    recognizer.availability = const SpeechModelRequired(
      message: 'English (US) needs the small model.',
    );
    await pumpApp(tester, recognizer, store: FakeModelStore(installedFor: {}));

    await startListening(tester);

    expect(find.text('Language model missing'), findsOneWidget);
    expect(find.text('Set up a language model'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'Set brightness to 20 percent',
    );
    await tester.tap(find.text('Analyze'));
    await tester.pumpAndSettle();

    expect(find.text('Brightness: 20%'), findsOneWidget);
    expect(find.text('Typed command'), findsOneWidget);
    expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
  });

  testWidgets('a new session never shows the previous transcript', (
    tester,
  ) async {
    await pumpApp(tester, recognizer);

    await startListening(tester);
    recognizer.emit(const SpeechFinalTranscript('Turn the lights on'));
    await tester.pumpAndSettle();
    expect(find.text('Turn the lights on'), findsWidgets);

    await startListening(tester);
    expect(find.text('Recognized text'), findsNothing);
    expect(find.text('Turn the lights on'), findsNothing);

    recognizer.emit(const SpeechFinalTranscript('Turn the lights blue'));
    await tester.pumpAndSettle();
    expect(find.text('Turn the lights blue'), findsWidgets);
    expect(find.text('Turn the lights on'), findsNothing);
  });

  testWidgets('Algerian Darija is selectable but disables the microphone', (
    tester,
  ) async {
    await pumpApp(tester, recognizer);

    await tester.tap(find.byType(DropdownButton<SpeechLanguage>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Algerian Darija (unsupported)').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('No Vosk model exists'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start listening'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('model manager lists the explicit download setup', (
    tester,
  ) async {
    await pumpApp(tester, recognizer, store: FakeModelStore(installedFor: {}));

    await tester.tap(find.text('Language models'));
    await tester.pumpAndSettle();

    expect(find.text('Offline language models'), findsOneWidget);
    expect(
      find.textContaining('vosk-model-small-en-us-0.15'),
      findsWidgets,
    );
    expect(find.textContaining('vosk-model-small-fr-0.22'), findsWidgets);
    expect(find.textContaining('vosk-model-small-ar-0.3'), findsWidgets);
    expect(find.text('Install'), findsNWidgets(3));
    expect(find.textContaining('Nothing is downloaded at startup'), findsOneWidget);
    expect(
      find.textContaining('No Algerian Darija model exists'),
      findsNothing,
      reason: 'the catalogue only lists models that exist',
    );

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Offline language models'), findsNothing);
  });

  testWidgets('there is no execution control anywhere', (tester) async {
    await pumpApp(tester, recognizer);
    await startListening(tester);
    recognizer.emit(const SpeechFinalTranscript('Turn the lights on'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Execute'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Execute'), findsNothing);
    expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
  });

  testWidgets('typed analysis remains available without any session', (
    tester,
  ) async {
    await pumpApp(tester, recognizer);

    await tester.enterText(find.byType(TextField), 'Make the lights teal');
    await tester.tap(find.text('Analyze'));
    await tester.pumpAndSettle();

    expect(find.text('Set color'), findsOneWidget);
    expect(find.text('Typed command'), findsOneWidget);
    expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
    expect(recognizer.startCalls, 0);
  });

  testWidgets('diagnostic mode shows capture facts and the verbatim text', (
    tester,
  ) async {
    final diagnostics = SessionDiagnostics();
    addTearDown(diagnostics.dispose);
    diagnostics.beginSession(sampleRate: 16000);
    // 3200 bytes = 0.10 s of 16 kHz mono PCM16.
    diagnostics.addChunk(Uint8List(3200));
    diagnostics.complete(transcript: 'set brightness to fifty percent');

    await pumpApp(tester, recognizer, diagnostics: diagnostics);

    expect(
      find.text('Diagnostic mode — audio actually captured'),
      findsOneWidget,
    );
    expect(find.text('Duration'), findsOneWidget);
    expect(find.text('16000 Hz, mono, 16-bit PCM'), findsOneWidget);
    expect(find.text('Raw transcript (Vosk, verbatim)'), findsOneWidget);
    expect(find.text('set brightness to fifty percent'), findsWidgets);
    expect(find.text('Save test recording (WAV)'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Execute'), findsNothing);

    await tester.tap(find.text('Clear diagnostics'));
    await tester.pumpAndSettle();
    expect(
      find.text('Diagnostic mode — audio actually captured'),
      findsNothing,
    );
  });
}
