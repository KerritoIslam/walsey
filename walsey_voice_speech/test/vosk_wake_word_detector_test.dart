import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

import 'support/fakes.dart';

/// The detector is exercised with an in-memory engine and capture only: no
/// microphone, no native library, no model archive and no network.
///
/// These tests prove the *wiring and safety rules*, not acoustic accuracy.
/// False-activation and miss rates are measured by `bin/wake_accuracy.dart`
/// against recorded audio and are reported in `docs/wake_word.md`.
void main() {
  late Directory modelDirectory;
  late FakeEngine engine;
  late FakeCapture capture;

  setUp(() {
    modelDirectory = Directory.systemTemp.createTempSync('walsey-wake-test');
    engine = FakeEngine();
    capture = FakeCapture();
  });

  tearDown(() {
    if (modelDirectory.existsSync()) {
      modelDirectory.deleteSync(recursive: true);
    }
  });

  VoskWakeWordDetector build({
    Duration duplicateWindow = const Duration(seconds: 2),
    bool requireLeadingPhrase = true,
    bool? platformSupported,
  }) =>
      VoskWakeWordDetector(
        engine: engine,
        capture: capture,
        modelPath: modelDirectory.path,
        duplicateWindow: duplicateWindow,
        requireLeadingPhrase: requireLeadingPhrase,
        platformSupported: platformSupported,
      );

  group('prepare', () {
    test('is available when the platform, permission and model are present',
        () async {
      final detector = build();
      final availability = await detector.prepare();
      expect(availability.capability, WakeWordCapability.available);
      expect(availability.isReady, isTrue);
      expect(availability.message, contains('Nothing is listening'));
      await detector.dispose();
    });

    test('reports an unsupported platform', () async {
      final detector = build(platformSupported: false);
      final availability = await detector.prepare();
      expect(availability.capability, WakeWordCapability.unsupportedPlatform);
      await detector.dispose();
    });

    test('reports missing microphone permission', () async {
      capture.permission = false;
      final detector = build();
      final availability = await detector.prepare();
      expect(availability.capability, WakeWordCapability.permissionDenied);
      await detector.dispose();
    });

    test('reports a missing model without loading it', () async {
      modelDirectory.deleteSync(recursive: true);
      final detector = build();
      final availability = await detector.prepare();
      expect(availability.capability, WakeWordCapability.notConfigured);
      expect(engine.loadedPath, isNull);
      await detector.dispose();
    });

    test('prepare never starts the microphone', () async {
      final detector = build();
      await detector.prepare();
      expect(capture.starts, 0);
      await detector.dispose();
    });
  });

  group('start', () {
    test('refuses to start without permission', () async {
      capture.permission = false;
      final detector = build();
      await expectLater(
        detector.start(),
        throwsA(isA<WakeWordStartException>()),
      );
      expect(capture.starts, 0);
      expect(engine.sessions, 0);
      await detector.dispose();
    });

    test('loads the model, opens a 16 kHz session and the microphone', () async {
      final detector = build();
      await detector.start();
      expect(engine.loadedPath, modelDirectory.path);
      expect(engine.sessions, 1);
      expect(capture.starts, 1);
      expect(capture.requestedSampleRate, 16000);
      expect(detector.isRunning, isTrue);
      await detector.stop();
      expect(detector.isRunning, isFalse);
      await detector.dispose();
    });

    test('a second start is a no-op while running', () async {
      final detector = build();
      await detector.start();
      await detector.start();
      expect(capture.starts, 1);
      await detector.dispose();
    });

    test('forwards captured audio to the engine', () async {
      final detector = build();
      await detector.start();
      capture.add(Uint8List.fromList(const [1, 2, 3, 4]));
      await Future<void>.delayed(Duration.zero);
      expect(engine.chunks.single, const [1, 2, 3, 4]);
      await detector.dispose();
    });
  });

  group('detection', () {
    Future<VoskWakeWordDetector> started({
      Duration duplicateWindow = const Duration(seconds: 2),
      bool requireLeadingPhrase = true,
    }) async {
      final detector = build(
        duplicateWindow: duplicateWindow,
        requireLeadingPhrase: requireLeadingPhrase,
      );
      await detector.start();
      return detector;
    }

    test('emits WakeWordDetected for a leading canonical phrase', () async {
      final detector = await started();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      engine.emit(const SpeechEnginePartial('Walsey turn on the lights'));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single, isA<WakeWordDetected>());
      expect((events.single as WakeWordDetected).phrase, 'walsey');
      await subscription.cancel();
      await detector.dispose();
    });

    test('emits for an observed engine variant', () async {
      final detector = await started();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      engine.emit(const SpeechEnginePartial('Volsity turn the lights off'));
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<WakeWordDetected>());
      await subscription.cancel();
      await detector.dispose();
    });

    test('emits for a segment too, not only partials', () async {
      final detector = await started();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      engine.emit(const SpeechEngineSegment('hey walsey make it blue'));
      await Future<void>.delayed(Duration.zero);
      expect((events.single as WakeWordDetected).phrase, 'hey walsey');
      await subscription.cancel();
      await detector.dispose();
    });

    test('does not fire when the phrase is not the first word', () async {
      final detector = await started();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      engine.emit(
        const SpeechEnginePartial('I told him about Walsey yesterday'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await subscription.cancel();
      await detector.dispose();
    });

    test('the leading rule can be relaxed explicitly', () async {
      final detector = await started(requireLeadingPhrase: false);
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      engine.emit(const SpeechEnginePartial('and then walsey listened'));
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<WakeWordDetected>());
      await subscription.cancel();
      await detector.dispose();
    });

    test('does not fire on the common-word misrecognitions', () async {
      final detector = await started();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      for (final text in [
        'well see you later',
        'the city lights are on',
        'will say it again',
        'while she is talking',
      ]) {
        engine.emit(SpeechEnginePartial(text));
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await subscription.cancel();
      await detector.dispose();
    });

    test('a repeated phrase inside the duplicate window fires once', () async {
      final detector = await started();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      engine.emit(const SpeechEnginePartial('walsey'));
      engine.emit(const SpeechEnginePartial('walsey'));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      await subscription.cancel();
      await detector.dispose();
    });

    test('a zero duplicate window allows repeated detections', () async {
      final detector = await started(duplicateWindow: Duration.zero);
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      engine.emit(const SpeechEnginePartial('walsey'));
      await Future<void>.delayed(Duration.zero);
      engine.emit(const SpeechEnginePartial('walsey'));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      await subscription.cancel();
      await detector.dispose();
    });

    test('resets and reopens the decoder after a detection', () async {
      final detector = await started();
      expect(engine.resets, 0);
      expect(engine.sessions, 1);
      engine.emit(const SpeechEnginePartial('walsey'));
      await Future<void>.delayed(Duration.zero);
      expect(engine.resets, 1);
      expect(engine.sessions, 2);
      await detector.dispose();
    });

    test('an engine error becomes WakeWordFailed and stops listening',
        () async {
      final detector = await started();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      engine.emit(const SpeechEngineError('native decode failed'));
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<WakeWordFailed>());
      expect((events.single as WakeWordFailed).message, contains('decode'));
      expect(detector.isRunning, isFalse);
      await subscription.cancel();
      await detector.dispose();
    });
  });

  group('stop and dispose', () {
    test('stop closes the microphone and resets the engine', () async {
      final detector = build();
      await detector.start();
      final resetsBefore = engine.resets;
      await detector.stop();
      expect(capture.stops, 1);
      expect(engine.resets, resetsBefore + 1);
      expect(engine.disposed, isFalse);
      await detector.dispose();
    });

    test('dispose releases the engine and capture and closes events',
        () async {
      final detector = build();
      await detector.start();
      final done = detector.events.toList();
      await detector.dispose();
      expect(engine.disposed, isTrue);
      expect(capture.disposals, 1);
      await expectLater(done, completes);
    });

    test('stop is safe when never started', () async {
      final detector = build();
      await detector.stop();
      expect(capture.stops, 1);
      await detector.dispose();
    });
  });
}
