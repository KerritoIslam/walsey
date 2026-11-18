import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

import 'support/fakes.dart';

/// Four samples per frame: one 8-byte chunk is one score.
class _FakeScorer implements WakeWordScorer {
  @override
  String get name => 'fake-wake';

  @override
  int get frameSamples => 4;

  final List<double> nextScores = [];
  double fallbackScore = 0;
  int loads = 0;
  bool disposed = false;

  @override
  Future<void> load(String modelPath) async => loads++;

  @override
  Future<double> score(Int16List frame) async =>
      nextScores.isEmpty ? fallbackScore : nextScores.removeAt(0);

  @override
  Future<void> reset() async {}

  @override
  Future<void> dispose() async => disposed = true;
}

class _FakeBufferedRecognizer implements BufferedRecognizer {
  String? text = 'turn the lights on';
  Object? error;
  final List<Uint8List> calls = [];
  final List<int> detectorStopsAtCall = [];

  /// Set by the test to observe that the detector was stopped first.
  FakeCapture? capture;

  @override
  Future<String?> recognize(Uint8List pcm16) async {
    calls.add(pcm16);
    if (capture != null) detectorStopsAtCall.add(capture!.stops);
    final failure = error;
    if (failure != null) throw failure;
    return text;
  }
}

Uint8List tone(Duration duration, {double amplitude = 0.5}) {
  const sampleRate = 16000;
  final samples = (sampleRate * duration.inMicroseconds / 1000000).round();
  final data = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    final value =
        (math.sin(2 * math.pi * 220 * i / sampleRate) * amplitude * 32767)
            .round();
    data.setInt16(i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List silence(Duration duration) {
  const sampleRate = 16000;
  final samples = (sampleRate * duration.inMicroseconds / 1000000).round();
  return Uint8List(samples * 2);
}

Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> feed(FakeCapture capture, Uint8List pcm, {int chunk = 640}) async {
  for (var offset = 0; offset < pcm.length; offset += chunk) {
    final end = math.min(offset + chunk, pcm.length);
    capture.add(Uint8List.sublistView(pcm, offset, end));
    await settle();
  }
}

void main() {
  late FakeCapture capture;
  late _FakeScorer scorer;
  late OnnxWakeWordDetector detector;
  late _FakeBufferedRecognizer recognizer;
  late WakeWordCommandLoop loop;
  late List<WakeCommandEvent> events;
  late StreamSubscription<WakeCommandEvent> subscription;

  setUp(() {
    capture = FakeCapture();
    scorer = _FakeScorer();
    detector = OnnxWakeWordDetector(
      scorer: scorer,
      capture: capture,
      modelPath: 'walsey.onnx',
      threshold: 0.5,
      modelPresent: () => true,
      platformSupported: true,
    );
    recognizer = _FakeBufferedRecognizer()..capture = capture;
    loop = WakeWordCommandLoop(
      detector: detector,
      recognizer: recognizer,
      preRoll: const Duration(milliseconds: 500),
      commandTimeout: const Duration(milliseconds: 400),
      vadConfig: const VoiceActivityConfig(
        minSpeechDuration: Duration(milliseconds: 100),
        silenceDuration: Duration(milliseconds: 300),
      ),
    );
    events = [];
    subscription = loop.events.listen(events.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await loop.dispose();
    await detector.dispose();
  });

  test('detection captures the command and returns a transcript', () async {
    await loop.start();
    await settle();
    expect(events.whereType<WakeListening>(), hasLength(1));

    // Some pre-roll audio, then the wake hit.
    await feed(capture, silence(const Duration(milliseconds: 100)));
    scorer.nextScores.add(0.9);
    await feed(capture, Uint8List(640));
    await settle();

    expect(events.whereType<WakeDetected>(), hasLength(1));

    await feed(capture, tone(const Duration(milliseconds: 300)));
    await feed(capture, silence(const Duration(milliseconds: 400)));
    await settle();

    expect(events.whereType<WakeCapturing>(), hasLength(1));
    final transcript = events.whereType<WakeTranscript>().single;
    expect(transcript.text, 'turn the lights on');
    // The recognizer saw the pre-roll plus the command audio.
    expect(recognizer.calls.single.length, greaterThan(3200));
    // The microphone was closed before the decode started.
    expect(recognizer.detectorStopsAtCall.single, greaterThanOrEqualTo(1));
  });

  test('no command after the wake word ends empty and resumes listening',
      () async {
    await loop.start();
    scorer.nextScores.add(0.9);
    await feed(capture, Uint8List(640));
    await settle();
    expect(events.whereType<WakeDetected>(), hasLength(1));

    await Future<void>.delayed(const Duration(milliseconds: 600));
    await settle();

    expect(events.whereType<WakeEmpty>(), hasLength(1));
    expect(recognizer.calls, isEmpty);
    // One automatic resume after a completed take.
    expect(events.whereType<WakeListening>(), hasLength(2));
    expect(capture.starts, 2);
  });

  test('the detector is stopped before transcription', () async {
    await loop.start();
    scorer.nextScores.add(0.9);
    await feed(capture, Uint8List(640));
    await settle();
    await feed(capture, tone(const Duration(milliseconds: 300)));
    await feed(capture, silence(const Duration(milliseconds: 400)));
    await settle();

    expect(capture.stops, greaterThanOrEqualTo(1));
    expect(recognizer.calls, hasLength(1));
    expect(recognizer.detectorStopsAtCall.single, greaterThanOrEqualTo(1));
    expect(detector.isRunning, isTrue, reason: 'listening resumed');
  });

  test('an empty transcript is reported as empty, not executed', () async {
    recognizer.text = '   ';
    await loop.start();
    scorer.nextScores.add(0.9);
    await feed(capture, Uint8List(640));
    await settle();
    await feed(capture, tone(const Duration(milliseconds: 300)));
    await feed(capture, silence(const Duration(milliseconds: 400)));
    await settle();

    expect(events.whereType<WakeTranscript>(), isEmpty);
    expect(events.whereType<WakeEmpty>(), hasLength(1));
  });

  test('a decode failure is surfaced and stops the loop', () async {
    recognizer.error = StateError('engine exploded');
    await loop.start();
    scorer.nextScores.add(0.9);
    await feed(capture, Uint8List(640));
    await settle();
    await feed(capture, tone(const Duration(milliseconds: 300)));
    await feed(capture, silence(const Duration(milliseconds: 400)));
    await settle();

    final failure = events.whereType<WakeFailed>().single;
    expect(failure.recoverable, isFalse);
    expect(failure.message, contains('could not be transcribed'));
    expect(capture.starts, 1, reason: 'no automatic retry after a failure');
  });

  test('stop closes the microphone and reports stopped once', () async {
    await loop.start();
    await loop.stop();
    await settle();

    expect(events.whereType<WakeStopped>(), hasLength(1));
    expect(capture.stops, greaterThanOrEqualTo(1));
    expect(loop.isRunning, isFalse);
  });

  test('autoResume false leaves the loop idle after a take', () async {
    await loop.dispose();
    loop = WakeWordCommandLoop(
      detector: detector,
      recognizer: recognizer,
      autoResume: false,
      preRoll: const Duration(milliseconds: 500),
      vadConfig: const VoiceActivityConfig(
        minSpeechDuration: Duration(milliseconds: 100),
        silenceDuration: Duration(milliseconds: 300),
      ),
    );
    subscription = loop.events.listen(events.add);
    await loop.start();
    scorer.nextScores.add(0.9);
    await feed(capture, Uint8List(640));
    await settle();
    await feed(capture, tone(const Duration(milliseconds: 300)));
    await feed(capture, silence(const Duration(milliseconds: 400)));
    await settle();

    expect(events.whereType<WakeTranscript>(), hasLength(1));
    expect(capture.starts, 1, reason: 'no resume when autoResume is off');
    expect(loop.isRunning, isFalse);
  });
}
