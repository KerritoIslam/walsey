import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'support.dart';

void main() {
  group('effect ids', () {
    const cases = {
      'activate effect 1': 1,
      'apply effect 5': 5,
      'set effect to 72': 72,
      'activate effect seventy two': 72,
      'effect 210': 210,
      'activate effect 255': 255,
      'Walsey, activate effect 5.': 5,
    };

    cases.forEach((phrase, expected) {
      test('recognizes "$phrase"', () {
        expectCommand(
          phrase,
          intent: VoiceIntent.applyEffect,
          parameters: ['Effect id: $expected'],
        );
      });
    });
  });

  test('rejects ids outside the documented set without clamping', () {
    for (final id in [0, 211, 999]) {
      final failure = failureFor('activate effect $id');
      expect(
        failure.kind,
        VoiceFailureKind.invalidParameter,
        reason: 'id $id',
      );
      expect(failure.intent, VoiceIntent.applyEffect, reason: 'id $id');
    }
    final huge = failureFor('activate effect 999999999999999999999999');
    expect(huge.kind, VoiceFailureKind.invalidParameter);
  });

  test('rejects a non-integer effect id', () {
    final failure = failureFor('activate effect 5.5');
    expect(failure.kind, VoiceFailureKind.invalidParameter);
    expect(failure.intent, VoiceIntent.applyEffect);
  });

  test('a missing effect id is a missing parameter', () {
    for (final phrase in ['activate effect', 'effect']) {
      final failure = failureFor(phrase);
      expect(
        failure.kind,
        VoiceFailureKind.missingParameter,
        reason: phrase,
      );
      expect(failure.intent, VoiceIntent.applyEffect, reason: phrase);
    }
  });

  test('two effect ids are ambiguous', () {
    expect(
      failureFor('activate effect 5 and 6').kind,
      VoiceFailureKind.ambiguous,
    );
  });

  test('next/previous effect is unsupported because state is unreadable', () {
    for (final phrase in [
      'activate the next effect',
      'previous effect',
      'play a random effect',
    ]) {
      final failure = failureFor(phrase);
      expect(
        failure.kind,
        VoiceFailureKind.unsupported,
        reason: phrase,
      );
      expect(failure.intent, VoiceIntent.applyEffect, reason: phrase);
      expect(failure.explanation, contains('read-back'), reason: phrase);
    }
  });

  test('talking about effects is not a command', () {
    expect(
      failureFor('tell me about effects').kind,
      VoiceFailureKind.unsupported,
    );
  });
}
