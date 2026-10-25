import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'support.dart';

void main() {
  group('power on', () {
    const phrases = [
      'turn the lights on',
      'turn on the lights',
      'switch on the lights',
      'switch the lights on',
      'lights on',
      'turn the light on',
      'turn the LED on',
      'please turn the lights on',
      'can you turn on the lights',
      'Walsey, turn the lights on.',
      '  TURN   THE   LIGHTS   ON  ',
    ];

    for (final phrase in phrases) {
      test('recognizes "$phrase"', () {
        expectCommand(phrase, intent: VoiceIntent.powerOn);
      });
    }
  });

  group('power off', () {
    const phrases = [
      'turn the lights off',
      'turn off the lights',
      'switch off the lights',
      'switch the lights off',
      'lights off',
      'turn the light off',
      'shut the lights off',
      'Walsey, turn off the lights!',
    ];

    for (final phrase in phrases) {
      test('recognizes "$phrase"', () {
        expectCommand(phrase, intent: VoiceIntent.powerOff);
      });
    }
  });

  test('power commands have no parameters', () {
    final command = commandFor('turn on the lights');
    expect(command.parameters, isA<NoParameters>());
    expect(command.parameters.summary, isEmpty);
    expect(command.actionId, 'powerOn');
  });

  test('a statement about power is not a command', () {
    for (final phrase in [
      'the lights are on',
      'the lights are off',
      'lights are on',
      'is the light on',
    ]) {
      expect(
        failureFor(phrase).kind,
        VoiceFailureKind.unsupported,
        reason: phrase,
      );
    }
  });

  test('power words without an LED subject are not an LED command', () {
    expect(
      failureFor('turn on the tv').kind,
      VoiceFailureKind.unsupported,
    );
    expect(failureFor('turn on').kind, VoiceFailureKind.unsupported);
  });
}
