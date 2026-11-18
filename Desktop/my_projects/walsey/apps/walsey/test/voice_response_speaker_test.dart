import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/voice/voice_response_speaker.dart';

class _FakeTtsEngine implements TtsEngine {
  final List<String> spoken = [];
  int stops = 0;
  int disposals = 0;
  bool disposed = false;
  Object? speakError;

  @override
  Future<void> speak(String text) async {
    final error = speakError;
    if (error != null) throw error;
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    disposed = true;
  }
}

/// Spoken responses are off by default and use only the system voice. These
/// tests prove the policy (off, best-effort, echo suppression); no audio device
/// or platform voice is involved.
void main() {
  late _FakeTtsEngine engine;

  setUp(() => engine = _FakeTtsEngine());

  test('is silent and never touches the engine while disabled', () async {
    final speaker = VoiceResponseSpeaker(engine: engine);
    expect(speaker.enabled, isFalse);

    await speaker.announce('Done.');
    await speaker.silence();

    expect(engine.spoken, isEmpty);
    expect(engine.stops, 0);
    await speaker.dispose();
  });

  test('speaks a short outcome when enabled', () async {
    final speaker = VoiceResponseSpeaker(engine: engine, enabled: true);
    await speaker.announce('Done.');
    expect(engine.spoken, ['Done.']);
    await speaker.dispose();
  });

  test('silence stops in-progress speech before a take', () async {
    final speaker = VoiceResponseSpeaker(engine: engine, enabled: true);
    await speaker.silence();
    expect(engine.stops, 1);
    await speaker.dispose();
  });

  test('blank text is not spoken', () async {
    final speaker = VoiceResponseSpeaker(engine: engine, enabled: true);
    await speaker.announce('   ');
    await speaker.announce(null);
    expect(engine.spoken, isEmpty);
    await speaker.dispose();
  });

  test('turning responses off stops speech and silences further results',
      () async {
    final speaker = VoiceResponseSpeaker(engine: engine, enabled: true);
    speaker.enabled = false;
    await Future<void>.delayed(Duration.zero);
    expect(engine.stops, 1);

    await speaker.announce('Done.');
    await speaker.silence();
    expect(engine.spoken, isEmpty);
    expect(engine.stops, 1);
    await speaker.dispose();
  });

  test('an engine failure never escapes to the caller', () async {
    engine.speakError = StateError('no voice installed');
    final speaker = VoiceResponseSpeaker(engine: engine, enabled: true);
    await expectLater(speaker.announce('Done.'), completes);
    await speaker.dispose();
  });

  test('dispose stops the engine and ignores later announcements', () async {
    final speaker = VoiceResponseSpeaker(engine: engine, enabled: true);
    await speaker.dispose();
    expect(engine.disposed, isTrue);

    await speaker.announce('Done.');
    expect(engine.spoken, isEmpty);
  });
}
