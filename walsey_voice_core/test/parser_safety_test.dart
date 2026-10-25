import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'support.dart';

void main() {
  group('empty and meaningless input', () {
    test('empty and whitespace-only input is reported explicitly', () {
      for (final phrase in ['', '   ', '\n\t']) {
        expect(
          failureFor(phrase).kind,
          VoiceFailureKind.emptyInput,
          reason: 'input: "$phrase"',
        );
      }
    });

    test('punctuation-only input is empty', () {
      expect(failureFor('!!! ???').kind, VoiceFailureKind.emptyInput);
    });

    test('a wake word with no command is unsupported', () {
      for (final phrase in ['Walsey', 'Walsey,', 'hey Walsey']) {
        expect(
          failureFor(phrase).kind,
          VoiceFailureKind.unsupported,
          reason: phrase,
        );
      }
    });
  });

  group('unknown sentences', () {
    test('unrelated text is unsupported', () {
      for (final phrase in [
        'What is the weather?',
        'Tell me a joke',
        'make me a sandwich',
        'I like blue cars',
        'how are you',
        'the lights are on',
      ]) {
        expect(
          failureFor(phrase).kind,
          VoiceFailureKind.unsupported,
          reason: phrase,
        );
      }
    });
  });

  group('negation and misleading sentences', () {
    test('negated requests are never turned into actions', () {
      for (final phrase in [
        "I don't want the lights on",
        'do not turn on the lights',
        'never turn off the lights',
        "don't make the lights blue",
        'without turning on the lights',
      ]) {
        final failure = failureFor(phrase);
        expect(
          failure.kind,
          VoiceFailureKind.unsupported,
          reason: phrase,
        );
        expect(failure.explanation, contains('Negated'), reason: phrase);
      }
    });

    test('a question is not executed', () {
      expect(
        failureFor('how do I turn on the lights').kind,
        VoiceFailureKind.unsupported,
      );
    });
  });

  group('contradictions and multiple actions', () {
    test('asking for on and off is ambiguous', () {
      for (final phrase in [
        'turn the lights on and off',
        'turn the lights off and on',
        'switch the lights on then off',
      ]) {
        final failure = failureFor(phrase);
        expect(
          failure.kind,
          VoiceFailureKind.ambiguous,
          reason: phrase,
        );
        expect(failure.explanation, contains('on'), reason: phrase);
        expect(failure.explanation, contains('off'), reason: phrase);
      }
    });

    test('two LED actions in one sentence are ambiguous', () {
      for (final phrase in [
        'turn on the lights and set brightness to 50 percent',
        'make the lights blue and set brightness to 50 percent',
        'set the color to blue and turn off the lights',
        'turn on the lights and make them brighter',
      ]) {
        expect(
          failureFor(phrase).kind,
          VoiceFailureKind.ambiguous,
          reason: phrase,
        );
      }
    });
  });

  group('domains that are not implemented in Stage 1', () {
    test('system actions are refused, not silently ignored', () {
      for (final phrase in [
        'open Chrome',
        'launch notepad',
        'turn on the lights and open Chrome',
      ]) {
        expect(
          failureFor(phrase).kind,
          VoiceFailureKind.unsupported,
          reason: phrase,
        );
      }
    });

    test('non-LED devices are refused', () {
      expect(
        failureFor('turn on the tv').kind,
        VoiceFailureKind.unsupported,
      );
      expect(
        failureFor('set the volume to 30 percent').kind,
        VoiceFailureKind.unsupported,
      );
    });
  });

  group('registry authorization', () {
    test('an unregistered intent cannot become a valid command', () {
      final parser = VoiceCommandParser(registry: CommandRegistry(const []));
      final result = parser.parse('turn on the lights');
      expect(result, isA<VoiceFailure>());
      final failure = result as VoiceFailure;
      expect(failure.kind, VoiceFailureKind.unsupported);
      expect(failure.intent, VoiceIntent.powerOn);
      expect(failure.explanation, contains('not in this command registry'));
    });

    test('the default registry contains every LED action', () {
      final registry = CommandRegistry.ledDefaults();
      for (final intent in VoiceIntent.values) {
        expect(registry.supports(intent), isTrue, reason: intent.name);
      }
    });
  });

  group('parsed is not executed', () {
    test('a valid command still reports notExecuted', () {
      final result = parser.parse('make the lights blue');
      expect(result, isA<VoiceCommandResult>());
      expect(result.executionStatus, VoiceExecutionStatus.notExecuted);
      expect(
        result.executionStatus.label,
        'Not executed — Stage 2 testing mode',
      );
    });

    test('a failure also reports notExecuted', () {
      final result = parser.parse('Tell me a joke');
      expect(result, isA<VoiceFailure>());
      expect(result.executionStatus, VoiceExecutionStatus.notExecuted);
    });
  });

  group('case, whitespace and punctuation regressions', () {
    test('variants produce the same command', () {
      for (final phrase in [
        'turn the lights on',
        'TURN THE LIGHTS ON',
        '   turn   the   lights   on   ',
        'Turn the lights on!',
        'Walsey, turn the lights on.',
      ]) {
        expectCommand(phrase, intent: VoiceIntent.powerOn);
      }
    });

    test('normalized text is exposed without the wake word', () {
      final command = commandFor('Walsey, TURN  the lights  ON!');
      expect(command.normalizedText, 'turn the lights on');
      expect(command.sourceText, 'Walsey, TURN  the lights  ON!');
    });

    test('regression: colour verbs are not mistaken for power', () {
      expectCommand(
        'turn the lights green',
        intent: VoiceIntent.setColor,
        parameters: ['Color: green'],
      );
    });

    test('regression: brightness comparatives are not colours', () {
      expectCommand(
        'make the lights brighter',
        intent: VoiceIntent.increaseBrightness,
      );
      expectCommand(
        'make the lights dimmer',
        intent: VoiceIntent.decreaseBrightness,
      );
    });

    test('regression: "I don\'t want the lights on" never becomes power on',
        () {
      final failure = failureFor("I don't want the lights on");
      expect(failure.kind, VoiceFailureKind.unsupported);
      expect(failure.intent, isNull);
    });
  });
}
