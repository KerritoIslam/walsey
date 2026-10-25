import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'support.dart';

void main() {
  group('set color variations', () {
    final cases = <String, VoiceColor>{
      'make the lights blue': VoiceColor.blue,
      'turn the lights blue': VoiceColor.blue,
      'set the color to blue': VoiceColor.blue,
      'set the colour to blue': VoiceColor.blue,
      'change the lights to red': VoiceColor.red,
      'turn the lights green': VoiceColor.green,
      'change color to white': VoiceColor.white,
      'Walsey, make the lights blue.': VoiceColor.blue,
      '  make   the   lights   BLUE  ': VoiceColor.blue,
    };

    cases.forEach((phrase, color) {
      test('recognizes "$phrase"', () {
        expectCommand(
          phrase,
          intent: VoiceIntent.setColor,
          parameters: ['Color: ${color.label}'],
        );
      });
    });
  });

  test('every controlled colour can be selected', () {
    for (final color in VoiceColor.values) {
      final command = commandFor('make the lights ${color.name}');
      expect(
        (command.parameters as ColorParameters).color,
        color,
        reason: color.name,
      );
    }
  });

  test('colour aliases resolve to the canonical entry', () {
    expect(
      (commandFor('make the lights violet').parameters as ColorParameters)
          .color,
      VoiceColor.purple,
    );
    expect(
      (commandFor('make the lights turquoise').parameters as ColorParameters)
          .color,
      VoiceColor.cyan,
    );
  });

  test('the controlled list maps to fixed RGB values', () {
    expect((VoiceColor.red.r, VoiceColor.red.g, VoiceColor.red.b), (255, 0, 0));
    expect(
      (VoiceColor.green.r, VoiceColor.green.g, VoiceColor.green.b),
      (0, 255, 0),
    );
    expect(
      (VoiceColor.blue.r, VoiceColor.blue.g, VoiceColor.blue.b),
      (0, 0, 255),
    );
  });

  test('an unknown colour is rejected without guessing', () {
    final failure = failureFor('set the color to teal');
    expect(failure.kind, VoiceFailureKind.invalidParameter);
    expect(failure.intent, VoiceIntent.setColor);
    expect(failure.explanation, contains('teal'));
    expect(failure.explanation, contains('Supported colours'));
  });

  test('an unknown colour after the light noun is rejected', () {
    final failure = failureFor('make the lights teal');
    expect(failure.kind, VoiceFailureKind.invalidParameter);
    expect(failure.intent, VoiceIntent.setColor);
  });

  test('a missing colour is a missing parameter, not a guess', () {
    final failure = failureFor('set the color');
    expect(failure.kind, VoiceFailureKind.missingParameter);
    expect(failure.intent, VoiceIntent.setColor);
  });

  test('more than one colour is ambiguous', () {
    final failure = failureFor('make the lights blue and red');
    expect(failure.kind, VoiceFailureKind.ambiguous);
    expect(failure.explanation, contains('blue'));
    expect(failure.explanation, contains('red'));
  });

  test('colour words inside unrelated sentences do not become commands', () {
    for (final phrase in [
      'Tell me about blue cars',
      'I like blue cars',
      'the weather is blue',
      'blue',
    ]) {
      expect(
        failureFor(phrase).kind,
        VoiceFailureKind.unsupported,
        reason: phrase,
      );
    }
  });

  test('colour in a question is not executed', () {
    expect(
      failureFor('what color are the lights').kind,
      VoiceFailureKind.unsupported,
    );
  });

  test('power and colour in one sentence is ambiguous', () {
    expect(
      failureFor('turn on the lights blue').kind,
      VoiceFailureKind.ambiguous,
    );
  });
}
