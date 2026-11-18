import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

import 'support/fakes.dart';

/// Frame-scoring backend with no native library and no model file.
class _FakeScorer implements WakeWordScorer {
  @override
  String get name => 'fake';

  @override
  int get frameSamples => 4;

  final List<Int16List> frames = [];
  final List<double> nextScores = [];
  double fallbackScore = 0;
  int loads = 0;
  int resets = 0;
  bool disposed = false;
  Object? scoreError;

  @override
  Future<void> load(String modelPath) async => loads++;

  @override
  Future<double> score(Int16List frame) async {
    final error = scoreError;
    if (error != null) throw error;
    frames.add(Int16List.fromList(frame));
    return nextScores.isEmpty ? fallbackScore : nextScores.removeAt(0);
  }

  @override
  Future<void> reset() async => resets++;

  @override
  Future<void> dispose() async => disposed = true;
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeScorer scorer;
  late FakeCapture capture;

  setUp(() {
    scorer = _FakeScorer();
    capture = FakeCapture();
  });

  OnnxWakeWordDetector build({
    double threshold = 0.5,
    int consecutive = 1,
    Duration duplicateWindow = const Duration(seconds: 2),
  }) =>
      OnnxWakeWordDetector(
        scorer: scorer,
        capture: capture,
        modelPath: 'unused',
        threshold: threshold,
        requiredConsecutiveFrames: consecutive,
        duplicateWindow: duplicateWindow,
        platformSupported: true,
        modelPresent: () => true,
      );

  Uint8List frame(int seed) =>
      Uint8List.fromList([seed, 0, seed + 1, 0, seed + 2, 0, seed + 3, 0]);

  group('prepare', () {
    test('available when permission and model checks pass', () async {
      final detector = build();
      final availability = await detector.prepare();
      expect(availability.capability, WakeWordCapability.available);
      expect(scorer.loads, 0);
      await detector.dispose();
    });

    test('reports a missing wake model', () async {
      final detector = OnnxWakeWordDetector(
        scorer: scorer,
        capture: capture,
        modelPath: 'unused',
        platformSupported: true,
        modelPresent: () => false,
      );
      final availability = await detector.prepare();
      expect(availability.capability, WakeWordCapability.notConfigured);
      expect(availability.message, contains('No wake-word model'));
      await detector.dispose();
    });

    test('reports missing permission before touching the model', () async {
      capture.permission = false;
      final detector = build();
      final availability = await detector.prepare();
      expect(availability.capability, WakeWordCapability.permissionDenied);
      await detector.dispose();
    });

    test('refuses to start when the model is absent', () async {
      final detector = OnnxWakeWordDetector(
        scorer: scorer,
        capture: capture,
        modelPath: 'unused',
        platformSupported: true,
        modelPresent: () => false,
      );
      await expectLater(
        detector.start(),
        throwsA(isA<WakeWordStartException>()),
      );
      expect(capture.starts, 0);
      await detector.dispose();
    });
  });

  group('framing and detection', () {
    test('scores exact 4-sample frames and discards no audio', () async {
      final detector = build();
      await detector.start();
      capture.add(frame(1));
      capture.add(frame(5));
      await _settle();
      expect(scorer.frames, hasLength(2));
      expect(scorer.frames[0], [1, 2, 3, 4]);
      expect(scorer.frames[1], [5, 6, 7, 8]);
      await detector.dispose();
    });

    test('re-frames audio split across capture chunks', () async {
      final detector = build();
      await detector.start();
      capture.add(Uint8List.fromList([1, 0, 2, 0]));
      capture.add(Uint8List.fromList([3, 0, 4, 0]));
      await _settle();
      expect(scorer.frames.single, [1, 2, 3, 4]);
      await detector.dispose();
    });

    test('emits when the score reaches the threshold', () async {
      scorer.nextScores.addAll([0.1, 0.9]);
      final detector = build(threshold: 0.5);
      await detector.start();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      capture.add(frame(1));
      await _settle();
      expect(events, isEmpty);
      capture.add(frame(2));
      await _settle();
      expect(events.single, isA<WakeWordDetected>());
      await subscription.cancel();
      await detector.dispose();
    });

    test('requires the configured number of consecutive frames', () async {
      scorer.nextScores.addAll([0.9, 0.2, 0.9, 0.9]);
      final detector = build(threshold: 0.5, consecutive: 2);
      await detector.start();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      for (var i = 0; i < 4; i++) {
        capture.add(frame(i + 1));
        await _settle();
      }
      expect(events, hasLength(1));
      await subscription.cancel();
      await detector.dispose();
    });

    test('a low score never emits', () async {
      scorer.fallbackScore = 0.49;
      final detector = build(threshold: 0.5);
      await detector.start();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      for (var i = 0; i < 5; i++) {
        capture.add(frame(i + 1));
      }
      await _settle();
      expect(events, isEmpty);
      await subscription.cancel();
      await detector.dispose();
    });

    test('duplicate detections inside the window are suppressed', () async {
      scorer.fallbackScore = 0.9;
      final detector = build();
      await detector.start();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      capture.add(frame(1));
      await _settle();
      capture.add(frame(2));
      await _settle();
      expect(events, hasLength(1));
      await subscription.cancel();
      await detector.dispose();
    });

    test('the scorer is reset after a detection', () async {
      scorer.fallbackScore = 0.9;
      final detector = build();
      await detector.start();
      final resetsBefore = scorer.resets;
      capture.add(frame(1));
      await _settle();
      expect(scorer.resets, greaterThan(resetsBefore));
      await detector.dispose();
    });

    test('a scoring error becomes WakeWordFailed and stops', () async {
      scorer.scoreError = StateError('model exploded');
      final detector = build();
      await detector.start();
      final events = <WakeWordEvent>[];
      final subscription = detector.events.listen(events.add);
      capture.add(frame(1));
      await _settle();
      expect(events.single, isA<WakeWordFailed>());
      expect(detector.isRunning, isFalse);
      await subscription.cancel();
      await detector.dispose();
    });
  });

  group('lifecycle', () {
    test('start loads the scorer once and opens the microphone', () async {
      final detector = build();
      await detector.start();
      await detector.stop();
      await detector.start();
      expect(scorer.loads, 1);
      expect(capture.starts, 2);
      await detector.dispose();
    });

    test('stop releases capture and keeps the scorer', () async {
      final detector = build();
      await detector.start();
      await detector.stop();
      expect(capture.stops, 1);
      expect(scorer.disposed, isFalse);
      await detector.dispose();
    });

    test('dispose releases the scorer and closes events', () async {
      final detector = build();
      await detector.start();
      final done = detector.events.toList();
      await detector.dispose();
      expect(scorer.disposed, isTrue);
      expect(capture.disposals, 1);
      await expectLater(done, completes);
    });
  });
}
