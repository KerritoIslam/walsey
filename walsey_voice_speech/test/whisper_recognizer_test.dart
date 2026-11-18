import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

import 'support/fakes.dart';

void main() {
  late Directory tempDirectory;
  late ModelStore store;
  late FakeEngine engine;
  late FakeCapture capture;
  late WhisperSpeechRecognizer recognizer;
  late StreamSubscription<SpeechRecognitionEvent> subscription;
  late List<SpeechRecognitionEvent> events;

  final model = SpeechModel.whisperBaseEnglish;

  /// The store validates the published size byte-for-byte, so the fixture
  /// extends a tiny valid file to 147,964,211 bytes with `truncate` — on NTFS
  /// that is metadata-only, no 141 MB of zeros are written.
  Future<void> createInstalledModel() async {
    final file = File(
      p.join(tempDirectory.path, 'walsey_models', model.id, model.modelFileName!),
    );
    await file.parent.create(recursive: true);
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.writeFrom(const [0x6c, 0x6d, 0x67, 0x67]); // ggml LE
      await handle.truncate(model.archiveSizeBytes);
    } finally {
      await handle.close();
    }
  }

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('walsey_whisper_rec');
    store = ModelStore(baseDirectory: () async => tempDirectory);
    engine = FakeEngine();
    capture = FakeCapture();
    recognizer = WhisperSpeechRecognizer(
      modelStore: store,
      engine: engine,
      audioCapture: capture,
    );
    events = [];
    subscription = recognizer.events.listen(events.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await recognizer.dispose();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  group('binding', () {
    test('the engine is named Whisper and models come from the catalogue', () {
      expect(recognizer.engineName, 'Whisper');
      expect(recognizer.modelFor(SpeechLanguage.englishUs),
          SpeechModel.whisperBaseEnglish);
      expect(recognizer.modelFor(SpeechLanguage.french), isNull);
      expect(recognizer.modelFor(SpeechLanguage.algerianDarija), isNull);
      expect(recognizer.downloadableModels, SpeechModel.all);
      expect(recognizer.downloadableModels.first.kind, ModelKind.whisperGgml);
    });
  });

  group('initialize', () {
    test('reports the installed model and loads it once', () async {
      await createInstalledModel();

      expect(await recognizer.initialize(), isA<SpeechReady>());
      expect(await recognizer.initialize(), isA<SpeechReady>());

      expect(engine.loadedPath, endsWith('ggml-base.en.bin'));
    });

    test('a missing model asks for ggml-base.en without downloading', () async {
      final availability = await recognizer.initialize();

      expect(availability, isA<SpeechModelRequired>());
      expect(
        (availability as SpeechModelRequired).message,
        contains('ggml-base.en'),
      );
      expect(engine.loadedPath, isNull);
    });

    test('French is an unsupported language for Whisper', () async {
      final french = WhisperSpeechRecognizer(
        modelStore: store,
        engine: engine,
        audioCapture: capture,
        language: SpeechLanguage.french,
      );
      addTearDown(french.dispose);

      final availability = await french.initialize();

      expect(availability, isA<SpeechUnavailable>());
      expect(
        (availability as SpeechUnavailable).kind,
        SpeechFailureKind.unsupportedLanguage,
      );
      expect(engine.loadedPath, isNull);
    });

    test('Algerian Darija is an unsupported language for Whisper', () async {
      final darija = WhisperSpeechRecognizer(
        modelStore: store,
        engine: engine,
        audioCapture: capture,
        language: SpeechLanguage.algerianDarija,
      );
      addTearDown(darija.dispose);

      final availability = await darija.initialize();

      expect(availability, isA<SpeechUnavailable>());
      expect(
        (availability as SpeechUnavailable).kind,
        SpeechFailureKind.unsupportedLanguage,
      );
    });

    test('reports unsupported platforms instead of throwing', () async {
      final unsupported = WhisperSpeechRecognizer(
        modelStore: store,
        engine: engine,
        audioCapture: capture,
        platformSupported: false,
      );
      addTearDown(unsupported.dispose);

      final availability = await unsupported.initialize();

      expect(availability, isA<SpeechUnavailable>());
      expect(
        (availability as SpeechUnavailable).kind,
        SpeechFailureKind.unsupportedPlatform,
      );
    });

    test('maps a model rejection to modelInvalid', () async {
      await createInstalledModel();
      engine.loadError = StateError('bad ggml');

      final availability = await recognizer.initialize();

      expect(availability, isA<SpeechUnavailable>());
      expect(
        (availability as SpeechUnavailable).kind,
        SpeechFailureKind.modelInvalid,
      );
    });
  });

  group('sessions', () {
    test('captures 16 kHz PCM and passes the transcript through verbatim', () async {
      await createInstalledModel();
      engine.finalText = 'Turn the lights on.';

      await recognizer.start();
      await pumpEventQueue();
      // SpeechSessionStarted waits for the first chunk of real audio.
      expect(events, isEmpty);
      expect(capture.requestedSampleRate, 16000);
      expect(engine.sessions, 1);

      capture.add(Uint8List.fromList(const [0, 1, 0, 2]));
      await pumpEventQueue();
      expect(events.first, isA<SpeechSessionStarted>());
      expect(engine.chunks.single, const [0, 1, 0, 2]);

      await recognizer.stop();
      await pumpEventQueue();

      expect(events.last, isA<SpeechFinalTranscript>());
      // Whisper output is never rewritten: what the engine heard is what the
      // parser (and the UI) receives, even with imperfect punctuation.
      expect(
        (events.last as SpeechFinalTranscript).text,
        'Turn the lights on.',
      );
      expect(capture.stops, greaterThanOrEqualTo(1));
    });

    test('no grammar is forwarded: Whisper decodes freely', () async {
      await createInstalledModel();

      await recognizer.start();
      await pumpEventQueue();
      capture.add(Uint8List.fromList(const [0, 0]));
      await pumpEventQueue();
      await recognizer.stop();
      await pumpEventQueue();

      expect(engine.requestedGrammar, isNull);
    });

    test('a missing model becomes a modelNotInstalled failure event', () async {
      await recognizer.start();
      await pumpEventQueue();

      expect(events.single, isA<SpeechSessionFailed>());
      expect(
        (events.single as SpeechSessionFailed).kind,
        SpeechFailureKind.modelNotInstalled,
      );
      expect(capture.starts, 0);
      expect(engine.sessions, 0);
    });

    test('an empty final transcript is reported as no speech', () async {
      await createInstalledModel();
      engine.finalText = null;
      await recognizer.start();
      await pumpEventQueue();
      await recognizer.stop();
      await pumpEventQueue();

      expect(events.last, isA<SpeechNoSpeechDetected>());
    });

    test('cancel resets the engine and emits cancelled', () async {
      await createInstalledModel();
      await recognizer.start();
      await pumpEventQueue();

      await recognizer.cancel();
      await pumpEventQueue();

      expect(events.last, isA<SpeechSessionCancelled>());
      expect(engine.resets, 1);
    });

    test('a second start while active is refused', () async {
      await createInstalledModel();
      await recognizer.start();
      await pumpEventQueue();

      await expectLater(recognizer.start(), throwsStateError);
      expect(engine.sessions, 1);
    });
  });

  group('disposal', () {
    test('releases the engine and the microphone', () async {
      await createInstalledModel();
      await recognizer.start();
      await pumpEventQueue();

      await recognizer.dispose();
      await pumpEventQueue();

      expect(engine.disposed, isTrue);
      expect(capture.disposals, 1);
    });

    test('disposing without ever recording stays plugin-free', () async {
      final untouched = WhisperSpeechRecognizer(
        modelStore: store,
        engine: engine,
        audioCapture: capture,
      );

      await untouched.dispose();

      expect(capture.disposals, 0);
      expect(engine.disposed, isTrue);
    });
  });
}
