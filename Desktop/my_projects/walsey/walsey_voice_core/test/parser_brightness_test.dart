import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'support.dart';

void main() {
  group('absolute brightness formats', () {
    const phrases = {
      'set brightness to 50 percent': 50,
      'set the brightness to 50 percent': 50,
      'brightness 50%': 50,
      'brightness 50 percent': 50,
      'set the brightness to 30': 30,
      'make the lights 50 percent': 50,
      'set brightness to fifty percent': 50,
      'brightness fifty five percent': 55,
      'brightness one hundred percent': 100,
      'Walsey, set brightness to 50 percent.': 50,
      '  SET   BRIGHTNESS   TO   50   PERCENT  ': 50,
    };

    phrases.forEach((phrase, expected) {
      test('recognizes "$phrase"', () {
        expectCommand(
          phrase,
          intent: VoiceIntent.setBrightness,
          parameters: ['Brightness: $expected%'],
        );
      });
    });
  });

  test('accepts the documented 0..100 boundaries', () {
    expectCommand(
      'set brightness to 0 percent',
      intent: VoiceIntent.setBrightness,
      parameters: ['Brightness: 0%'],
    );
    expectCommand(
      'set brightness to 100 percent',
      intent: VoiceIntent.setBrightness,
      parameters: ['Brightness: 100%'],
    );
  });

  test('rejects values outside 0..100 instead of clamping', () {
    for (final phrase in [
      'set brightness to 101 percent',
      'set brightness to 150',
      'set brightness to -1 percent',
      'brightness 999',
      'brightness 999999999999999999999999',
    ]) {
      final failure = failureFor(phrase);
      expect(
        failure.kind,
        VoiceFailureKind.invalidParameter,
        reason: phrase,
      );
      expect(failure.intent, VoiceIntent.setBrightness, reason: phrase);
    }
  });

  test('rejects non-integer values', () {
    final failure = failureFor('set brightness to 50.5 percent');
    expect(failure.kind, VoiceFailureKind.invalidParameter);
    expect(failure.intent, VoiceIntent.setBrightness);
  });

  test('missing brightness is a missing parameter', () {
    for (final phrase in [
      'set brightness',
      'brightness',
      'brightness percent'
    ]) {
      final failure = failureFor(phrase);
      expect(
        failure.kind,
        VoiceFailureKind.missingParameter,
        reason: phrase,
      );
      expect(failure.intent, VoiceIntent.setBrightness, reason: phrase);
    }
  });

  test('a non-numeric brightness value is invalid', () {
    for (final phrase in ['set brightness to high', 'set brightness to max']) {
      final failure = failureFor(phrase);
      expect(
        failure.kind,
        VoiceFailureKind.invalidParameter,
        reason: phrase,
      );
      expect(failure.intent, VoiceIntent.setBrightness, reason: phrase);
    }
  });

  test('two different brightness values are ambiguous', () {
    final failure = failureFor('set brightness to 50 and 60 percent');
    expect(failure.kind, VoiceFailureKind.ambiguous);
    expect(failure.intent, VoiceIntent.setBrightness);
  });

  group('relative brightness', () {
    const increases = [
      'increase brightness',
      'increase the brightness',
      'make the lights brighter',
      'brighten the lights',
      'turn up the brightness',
      'raise the brightness',
    ];

    for (final phrase in increases) {
      test('recognizes "$phrase"', () {
        expectCommand(phrase, intent: VoiceIntent.increaseBrightness);
      });
    }

    const decreases = [
      'decrease brightness',
      'decrease the brightness',
      'make the lights dimmer',
      'dim the lights',
      'turn down the brightness',
      'lower the brightness',
    ];

    for (final phrase in decreases) {
      test('recognizes "$phrase"', () {
        expectCommand(phrase, intent: VoiceIntent.decreaseBrightness);
      });
    }

    test('increase and decrease together are ambiguous', () {
      expect(
        failureFor('increase and decrease the brightness').kind,
        VoiceFailureKind.ambiguous,
      );
    });

    test('relative and absolute brightness together are ambiguous', () {
      expect(
        failureFor('increase brightness to 50 percent').kind,
        VoiceFailureKind.ambiguous,
      );
    });
  });

  test('a duration is not a brightness value', () {
    expectCommand('turn on the lights for 5 minutes',
        intent: VoiceIntent.powerOn);
  });

  test('volume is outside the LED domain', () {
    expect(
      failureFor('set the volume to 30 percent').kind,
      VoiceFailureKind.unsupported,
    );
  });
}
