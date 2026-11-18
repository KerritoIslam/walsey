import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

/// Literal expectations for the paraphrase layer, brightness qualifiers and
/// the status-inquiry intent. These are hand-written sentences, never derived
/// from the parser's own vocabulary tables.
void main() {
  final parser = VoiceCommandParser();
  final planner = VoicePlanParser();

  VoiceCommand commandOf(String text) {
    final result = parser.parse(text);
    expect(result, isA<VoiceCommandResult>(), reason: 'expected a command');
    return (result as VoiceCommandResult).command;
  }

  VoiceFailure failureOf(String text) {
    final result = parser.parse(text);
    expect(result, isA<VoiceFailure>(), reason: 'expected a failure');
    return result as VoiceFailure;
  }

  group('power paraphrases', () {
    test('could you switch the lighting on', () {
      expect(commandOf('could you switch the lighting on').intent,
          VoiceIntent.powerOn);
    });

    test('i want the lights enabled', () {
      expect(
          commandOf('i want the lights enabled').intent, VoiceIntent.powerOn);
    });

    test('let us get the lights working', () {
      expect(commandOf('let us get the lights working').intent,
          VoiceIntent.powerOn);
    });

    test('power up the leds', () {
      expect(commandOf('power up the leds').intent, VoiceIntent.powerOn);
    });

    test('power down the leds', () {
      expect(commandOf('power down the leds').intent, VoiceIntent.powerOff);
    });

    test('switch off the leds', () {
      expect(commandOf('switch off the leds').intent, VoiceIntent.powerOff);
    });

    test('plain phrasing is unchanged', () {
      expect(commandOf('turn on the lights').intent, VoiceIntent.powerOn);
    });
  });

  group('colour paraphrases', () {
    test('give the lights a blue look', () {
      final command = commandOf('give the lights a blue look');
      expect(command.intent, VoiceIntent.setColor);
      expect(
        (command.parameters as ColorParameters).color,
        VoiceColor.blue,
      );
    });

    test('i want a blue color', () {
      final command = commandOf('i want a blue color');
      expect(command.intent, VoiceIntent.setColor);
      expect((command.parameters as ColorParameters).color, VoiceColor.blue);
    });

    test('can you make the lights cyan', () {
      final command = commandOf('can you make the lights cyan');
      expect(command.intent, VoiceIntent.setColor);
      expect((command.parameters as ColorParameters).color, VoiceColor.cyan);
    });
  });

  group('brightness qualifiers', () {
    test('half brightness is 50', () {
      final command = commandOf('set the brightness to half');
      expect(command.intent, VoiceIntent.setBrightness);
      expect(
        (command.parameters as BrightnessParameters).brightness.percent,
        50,
      );
    });

    test('maximum brightness is 100', () {
      final command = commandOf('maximum brightness');
      expect(
        (command.parameters as BrightnessParameters).brightness.percent,
        100,
      );
    });

    test('minimum brightness is 0', () {
      final command = commandOf('set brightness to minimum');
      expect(
        (command.parameters as BrightnessParameters).brightness.percent,
        0,
      );
    });

    test('an explicit number still wins', () {
      final command = commandOf('set brightness to 30 percent');
      expect(
        (command.parameters as BrightnessParameters).brightness.percent,
        30,
      );
    });
  });

  group('status inquiries', () {
    test('are the lights on', () {
      expect(commandOf('are the lights on').intent, VoiceIntent.queryStatus);
    });

    test('is the light off', () {
      expect(commandOf('is the light off').intent, VoiceIntent.queryStatus);
    });

    test('what is the brightness', () {
      expect(
        commandOf('what is the brightness').intent,
        VoiceIntent.queryStatus,
      );
    });

    test('what colour are the lights', () {
      expect(
        commandOf('what colour are the lights').intent,
        VoiceIntent.queryStatus,
      );
    });

    test('a question that contains an action is still refused', () {
      final failure = failureOf('should i turn the lights on');
      expect(failure.kind, VoiceFailureKind.unsupported);
    });
  });

  group('safety is unchanged', () {
    test('negated paraphrase is refused', () {
      expect(
        failureOf("don't enable the lights").kind,
        VoiceFailureKind.unsupported,
      );
    });

    test('unrelated speech is still unsupported', () {
      expect(
        failureOf('the weather is nice today').kind,
        VoiceFailureKind.unsupported,
      );
    });

    test('a statement about the lights stays a refusal', () {
      expect(failureOf('the lights are on').kind, VoiceFailureKind.unsupported);
    });
  });

  group('plans keep working with paraphrases', () {
    test('make them blue is a colour step', () {
      final result = planner.parse('make them blue');
      expect(result, isA<VoicePlanReady>());
      final plan = (result as VoicePlanReady).plan;
      expect(plan.steps.single, isA<SetColorStep>());
      expect((plan.steps.single as SetColorStep).color, VoiceColor.blue);
    });

    test('turn it on is a power step', () {
      final result = planner.parse('turn it on');
      expect(result, isA<VoicePlanReady>());
      expect((result as VoicePlanReady).plan.steps.single, isA<SetPowerStep>());
    });

    test('a status question becomes a query step, never an action', () {
      final result = planner.parse('are the lights on');
      expect(result, isA<VoicePlanReady>());
      final plan = (result as VoicePlanReady).plan;
      expect(plan.steps.single, isA<QueryStatusStep>());
    });

    test('two paraphrased actions stay two steps', () {
      final result = planner.parse(
        'could you switch the lighting on and make them blue',
      );
      expect(result, isA<VoicePlanReady>(), reason: 'expected a plan');
      final plan = (result as VoicePlanReady).plan;
      expect(plan.steps.whereType<SetPowerStep>().length, 1);
      expect(plan.steps.whereType<SetColorStep>().length, 1);
    });
  });
}
