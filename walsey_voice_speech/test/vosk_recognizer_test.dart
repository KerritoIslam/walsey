import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

class FakeEngine implements SpeechEngine {
  final StreamController<SpeechEngineEvent> _events =
      StreamController<SpeechEngineEvent>.broadcast();

  String? loadedPath;
  Object? loadError;
  String? finalText = 'set brightness to 50 percent';
  int sessions = 0;
  int resets = 0;
  bool disposed = false;
  List<String>? requestedGrammar;
  final List<Uint8List> chunks = [];

  @override
  Stream<SpeechEngineEvent> get events => _events.stream;

  @override
  Future<void> loadModel(String modelPath) async {
    final error = loadError;
    if (error != null) {
      throw error;
    }
    loadedPath = modelPath;
  }

  @override
  Future<void> beginSession({
    required int sampleRate,
    List<String>? grammar,
  }) async {
    sessions++;
    requestedGrammar = grammar;
  }

  @override
  void accept(Uint8List pcm) => chunks.add(pcm);

  @override
  Future<String?> finish() async => finalText;

  @override
  Future<void> reset() async {
    resets++;
    finalText = null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }

  void emit(SpeechEngineEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}

class FakeCapture implements AudioCapture {
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast();

  bool permission = true;
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  int? requestedSampleRate;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<Uint8List>> startStream({required int sampleRate}) async {
    starts++;
    requestedSampleRate = sampleRate;
    return _chunks.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await _chunks.close();
  }

  void add(Uint8List chunk) => _chunks.add(chunk);
}

/// Behaves like a real recorder on shutdown: the platform emits one final buffer
/// inside `stop()` and only then closes the stream.
class TailCapture implements AudioCapture {
  final StreamController<Uint8List> _chunks = StreamController<Uint8List>();
  bool started = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> startStream({required int sampleRate}) async {
    started = true;
    return _chunks.stream;
  }

  @override
  Future<void> stop() async {
    if (!started || _chunks.isClosed) {
      return;
    }
    _chunks.add(Uint8List.fromList(const [7, 7]));
    await _chunks.close();
  }

  @override
  Future<void> dispose() async {
    if (!_chunks.isClosed) {
      await _chunks.close();
    }
  }

  void add(Uint8List chunk) => _chunks.add(chunk);
}

void main() {
  late Directory tempDirectory;
  late ModelStore store;
  late FakeEngine engine;
  late FakeCapture capture;
  late VoskSpeechRecognizer recognizer;
  late StreamSubscription<SpeechRecognitionEvent> subscription;
  late List<SpeechRecognitionEvent> events;

  final model = SpeechModel.englishUs;

  Future<void> createInstalledModel() async {
    final directory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}walsey_models'
      '${Platform.pathSeparator}${model.id}',
    );
    await Directory(
      '${directory.path}${Platform.pathSeparator}am',
    ).create(recursive: true);
    await File(
      '${directory.path}${Platform.pathSeparator}am'
      '${Platform.pathSeparator}final.mdl',
    ).writeAsBytes(const [1, 2, 3]);
  }

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('walsey_speech_test');
    store = ModelStore(baseDirectory: () async => tempDirectory);
    engine = FakeEngine();
    capture = FakeCapture();
    recognizer = VoskSpeechRecognizer(
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

  group('initialize', () {
    test('reports the installed model and loads it once', () async {
      await createInstalledModel();

      expect(await recognizer.initialize(), isA<SpeechReady>());
      expect(await recognizer.initialize(), isA<SpeechReady>());

      expect(engine.loadedPath, endsWith(model.id));
      expect(engine.loadedPath, isNot(contains('am')));
    });

    test('reports a missing model without downloading anything', () async {
      final availability = await recognizer.initialize();

      expect(availability, isA<SpeechModelRequired>());
      expect(
        (availability as SpeechModelRequired).message,
        contains('vosk-model-small-en-us-0.15'),
      );
      expect(engine.loadedPath, isNull);
    });

    test('reports unsupported platforms instead of throwing', () async {
      final unsupported = VoskSpeechRecognizer(
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

    test('reports Algerian Darija as unsupported', () async {
      final darija = VoskSpeechRecognizer(
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

    test('maps a Vosk model rejection to modelInvalid', () async {
      await createInstalledModel();
      engine.loadError = StateError('bad model');

      final availability = await recognizer.initialize();

      expect(availability, isA<SpeechUnavailable>());
      expect(
        (availability as SpeechUnavailable).kind,
        SpeechFailureKind.modelInvalid,
      );
    });
  });

  group('sessions', () {
    test('permission denial becomes a permission failure event', () async {
      await createInstalledModel();
      capture.permission = false;

      await recognizer.start();
      await pumpEventQueue();

      expect(events.single, isA<SpeechSessionFailed>());
      expect(
        (events.single as SpeechSessionFailed).kind,
        SpeechFailureKind.permissionDenied,
      );
      expect(engine.sessions, 0);
      expect(capture.starts, 0);
    });

    test('missing model becomes a modelNotInstalled failure event', () async {
      await recognizer.start();
      await pumpEventQueue();

      expect(events.single, isA<SpeechSessionFailed>());
      expect(
        (events.single as SpeechSessionFailed).kind,
        SpeechFailureKind.modelNotInstalled,
      );
      expect(capture.starts, 0);
    });

    test('captures 16 kHz PCM and publishes the final transcript', () async {
      await createInstalledModel();

      await recognizer.start();
      await pumpEventQueue();
      expect(events.single, isA<SpeechSessionStarted>());
      expect(capture.requestedSampleRate, 16000);
      expect(engine.sessions, 1);

      capture.add(Uint8List.fromList(const [0, 1, 0, 2]));
      await pumpEventQueue();
      expect(engine.chunks.single, const [0, 1, 0, 2]);

      await recognizer.stop();
      await pumpEventQueue();

      expect(events.last, isA<SpeechFinalTranscript>());
      expect(
        (events.last as SpeechFinalTranscript).text,
        'set brightness to 50 percent',
      );
      expect(capture.stops, greaterThanOrEqualTo(1));
    });

    test('grammar is off by default and forwarded when configured', () async {
      await createInstalledModel();

      await recognizer.start();
      await pumpEventQueue();
      expect(engine.requestedGrammar, isNull);
      await recognizer.stop();
      await pumpEventQueue();

      final constrained = VoskSpeechRecognizer(
        modelStore: store,
        engine: engine,
        audioCapture: capture,
        grammar: const ['turn the lights on', 'turn the lights off'],
      );
      addTearDown(constrained.dispose);
      await constrained.start();
      await pumpEventQueue();
      expect(engine.requestedGrammar, const [
        'turn the lights on',
        'turn the lights off',
      ]);
      await constrained.stop();
      await pumpEventQueue();
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

    test('engine partials reach the port as partial transcripts', () async {
      await createInstalledModel();
      await recognizer.start();
      await pumpEventQueue();

      engine.emit(const SpeechEnginePartial('set bright'));
      await pumpEventQueue();

      expect(events.last, isA<SpeechPartialTranscript>());
      expect((events.last as SpeechPartialTranscript).text, 'set bright');
    });

    test('engine errors end the session with recognitionFailed', () async {
      await createInstalledModel();
      await recognizer.start();
      await pumpEventQueue();

      engine.emit(const SpeechEngineError('engine exploded'));
      await pumpEventQueue();

      expect(events.last, isA<SpeechSessionFailed>());
      expect(
        (events.last as SpeechSessionFailed).kind,
        SpeechFailureKind.recognitionFailed,
      );
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

    test('audio chunks are ignored after stop', () async {
      await createInstalledModel();
      await recognizer.start();
      await pumpEventQueue();
      await recognizer.stop();
      await pumpEventQueue();

      final delivered = engine.chunks.length;
      capture.add(Uint8List.fromList(const [9, 9]));
      await pumpEventQueue();
      expect(engine.chunks.length, delivered);
    });
  });

  group('capture tail and diagnostics', () {
    test(
      'the last chunk emitted while stopping still reaches the engine',
      () async {
        await createInstalledModel();
        final tail = TailCapture();
        final tailRecognizer = VoskSpeechRecognizer(
          modelStore: store,
          engine: engine,
          audioCapture: tail,
        );
        addTearDown(tailRecognizer.dispose);
        final tailEvents = <SpeechRecognitionEvent>[];
        final tailSubscription = tailRecognizer.events.listen(tailEvents.add);
        addTearDown(tailSubscription.cancel);

        await tailRecognizer.start();
        await pumpEventQueue();
        tail.add(Uint8List.fromList(const [1, 1]));
        await pumpEventQueue();

        await tailRecognizer.stop();
        await pumpEventQueue();

        // The plugin delivered one more buffer inside stop(); it must be fed to
        // Vosk instead of being dropped by an early subscription cancel.
        expect(engine.chunks, [
          [1, 1],
          [7, 7],
        ]);
        expect(tailEvents.last, isA<SpeechFinalTranscript>());
      },
    );

    test(
      'diagnostics measure the stream and keep the verbatim transcript',
      () async {
        await createInstalledModel();
        final diagnostics = SessionDiagnostics();
        addTearDown(diagnostics.dispose);
        final recording = VoskSpeechRecognizer(
          modelStore: store,
          engine: engine,
          audioCapture: capture,
          diagnostics: diagnostics,
        );
        addTearDown(recording.dispose);
        final recordingEvents = <SpeechRecognitionEvent>[];
        final recordingSubscription = recording.events.listen(
          recordingEvents.add,
        );
        addTearDown(recordingSubscription.cancel);

        await recording.start();
        await pumpEventQueue();
        // 3200 bytes = 1600 samples = 0.1 s at 16 kHz.
        capture.add(Uint8List(3200));
        await pumpEventQueue();

        await recording.stop();
        await pumpEventQueue();

        final stats = diagnostics.stats!;
        expect(stats.sampleCount, 1600);
        expect(stats.durationSeconds, closeTo(0.1, 1e-9));
        expect(diagnostics.rawTranscript, 'set brightness to 50 percent');
        expect(diagnostics.declaredSampleRate, 16000);
        expect(diagnostics.bufferedBytes, 3200);
        expect(recordingEvents.last, isA<SpeechFinalTranscript>());

        await recording.cancel();
        expect(diagnostics.rawTranscript, isNull);
      },
    );
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
      final untouched = VoskSpeechRecognizer(
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
