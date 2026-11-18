import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/src/audio/voice_activity.dart';

const sampleRate = 16000;

Uint8List tone(Duration duration, {double amplitude = 0.5}) {
  final samples = (sampleRate * duration.inMicroseconds / 1000000).round();
  final data = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    final value =
        (math.sin(2 * math.pi * 220 * i / sampleRate) * amplitude * 32767)
            .round()
            .clamp(-32768, 32767);
    data.setInt16(i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List silence(Duration duration) {
  final samples = (sampleRate * duration.inMicroseconds / 1000000).round();
  return Uint8List(samples * 2);
}

List<VoiceActivityEvent> feedAll(
  VoiceActivityDetector detector,
  List<Uint8List> chunks, {
  int chunkBytes = 0,
}) {
  final events = <VoiceActivityEvent>[];
  for (final chunk in chunks) {
    if (chunkBytes <= 0) {
      events.addAll(detector.add(chunk));
      continue;
    }
    for (var offset = 0; offset < chunk.length; offset += chunkBytes) {
      final end = math.min(offset + chunkBytes, chunk.length);
      events.addAll(detector.add(Uint8List.sublistView(chunk, offset, end)));
    }
  }
  return events;
}

void main() {
  test('silence produces no events', () {
    final detector = VoiceActivityDetector();
    final events = feedAll(detector, [silence(const Duration(seconds: 2))]);
    expect(events, isEmpty);
    expect(detector.isSpeaking, isFalse);
  });

  test('quiet room noise stays below the threshold', () {
    final detector = VoiceActivityDetector();
    // 0.0045 amplitude ≈ −50 dBFS RMS, below the −42 dBFS threshold.
    final events = feedAll(
      detector,
      [tone(const Duration(seconds: 2), amplitude: 0.0045)],
    );
    expect(events, isEmpty);
  });

  test('a click shorter than the minimum speech duration does not start', () {
    final detector = VoiceActivityDetector();
    final events = feedAll(detector, [tone(const Duration(milliseconds: 100))]);
    expect(events, isEmpty);
  });

  test('speech starts after the minimum duration', () {
    final detector = VoiceActivityDetector();
    final events = feedAll(detector, [tone(const Duration(milliseconds: 300))]);
    expect(events.map((e) => e.type), [VoiceActivityEventType.speechStart]);
    expect(detector.isSpeaking, isTrue);
    expect(events.single.elapsed.inMilliseconds, greaterThanOrEqualTo(180));
  });

  test('a short pause inside a command does not end it', () {
    final detector = VoiceActivityDetector();
    final events = feedAll(detector, [
      tone(const Duration(milliseconds: 400)),
      silence(const Duration(milliseconds: 200)),
      tone(const Duration(milliseconds: 400)),
    ]);
    expect(events.map((e) => e.type), [VoiceActivityEventType.speechStart]);
    expect(detector.isSpeaking, isTrue);
  });

  test('the configured silence tail ends speech once', () {
    final detector = VoiceActivityDetector();
    final events = feedAll(detector, [
      tone(const Duration(milliseconds: 400)),
      silence(const Duration(milliseconds: 900)),
    ]);
    expect(events.map((e) => e.type), [
      VoiceActivityEventType.speechStart,
      VoiceActivityEventType.speechEnd,
    ]);
    expect(detector.isSpeaking, isFalse);
  });

  test('a frame split across recorder chunks is still detected', () {
    final detector = VoiceActivityDetector();
    final events = feedAll(
      detector,
      [
        tone(const Duration(milliseconds: 400)),
        silence(const Duration(milliseconds: 900)),
      ],
      chunkBytes: 137,
    );
    expect(events.map((e) => e.type), [
      VoiceActivityEventType.speechStart,
      VoiceActivityEventType.speechEnd,
    ]);
  });

  test('maximum speech length is enforced', () {
    final detector = VoiceActivityDetector(
      config: const VoiceActivityConfig(
        minSpeechDuration: Duration(milliseconds: 100),
        maxSpeechDuration: Duration(milliseconds: 300),
      ),
    );
    final events = feedAll(detector, [tone(const Duration(seconds: 2))]);
    expect(events.map((e) => e.type), [
      VoiceActivityEventType.speechStart,
      VoiceActivityEventType.maxSpeechReached,
    ]);
    expect(detector.isSpeaking, isFalse);
  });

  test('reset clears state and stream time', () {
    final detector = VoiceActivityDetector();
    feedAll(detector, [tone(const Duration(milliseconds: 300))]);
    expect(detector.isSpeaking, isTrue);

    detector.reset();

    expect(detector.isSpeaking, isFalse);
    expect(detector.elapsed, Duration.zero);
    final events = feedAll(detector, [silence(const Duration(milliseconds: 100))]);
    expect(events, isEmpty);
  });
}
