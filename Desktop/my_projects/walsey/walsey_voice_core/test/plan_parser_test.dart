import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

/// Literal expectations: the plan grammar is pinned by hand, not derived from
/// implementation details.
void main() {
  final parser = VoicePlanParser();

  VoicePlan planFor(String input) {
    final result = parser.parse(input);
    expect(result, isA<VoicePlanReady>(), reason: 'expected a plan for "$input"');
    return (result as VoicePlanReady).plan;
  }

  VoicePlanFailure failureFor(String input) {
    final result = parser.parse(input);
    expect(
      result,
      isA<VoicePlanFailure>(),
      reason: 'expected a failure for "$input"',
    );
    return result as VoicePlanFailure;
  }

  group('single commands stay Stage 1 commands', () {
    test('power on', () {
      final steps = planFor('Turn the lights on').steps;
      expect(steps, hasLength(1));
      expect((steps.single as SetPowerStep).on, isTrue);
    });

    test('colour', () {
      final steps = planFor('set the color to blue').steps;
      expect((steps.single as SetColorStep).color, VoiceColor.blue);
    });

    test('brightness', () {
      final steps = planFor('set brightness to 50 percent').steps;
      expect((steps.single as SetBrightnessStep).brightness.percent, 50);
    });

    test('effect', () {
      final steps = planFor('apply effect 5').steps;
      expect((steps.single as ApplyEffectStep).effect.id, 5);
    });

    test('pronoun sentence resolves against the connected light', () {
      final steps = planFor('change it to blue').steps;
      expect((steps.single as SetColorStep).color, VoiceColor.blue);
    });

    test('a spoken wake phrase is stripped, not treated as a command', () {
      final steps = planFor('Hey Walsey, turn the lights on').steps;
      expect(steps, hasLength(1));
      expect((steps.single as SetPowerStep).on, isTrue);
    });
  });

  group('multi-step plans', () {
    test('scan and turn the first one on', () {
      final steps = planFor('Scan for devices and turn the first one on').steps;
      expect(steps, hasLength(4));
      expect(steps[0], isA<ScanDevicesStep>());
      expect(
        (steps[1] as SelectDeviceStep).target,
        VoiceDeviceTarget.firstAvailable,
      );
      expect(steps[2], isA<ConnectDeviceStep>());
      expect((steps[3] as SetPowerStep).on, isTrue);
    });

    test('connect to first device and set colour gets an implied scan', () {
      final steps =
          planFor('connect to the first device and set the color to blue').steps;
      expect(steps, hasLength(4));
      expect(steps[0], isA<ScanDevicesStep>());
      expect(
        (steps[1] as SelectDeviceStep).target,
        VoiceDeviceTarget.firstAvailable,
      );
      expect(steps[2], isA<ConnectDeviceStep>());
      expect((steps[3] as SetColorStep).color, VoiceColor.blue);
    });

    test('connect to my LED and change it to blue', () {
      final steps = planFor('connect to my LED and change it to blue').steps;
      expect(steps, hasLength(3));
      expect(
        (steps[0] as SelectDeviceStep).target,
        VoiceDeviceTarget.knownOrFirst,
      );
      expect(steps[1], isA<ConnectDeviceStep>());
      expect((steps[2] as SetColorStep).color, VoiceColor.blue);
    });

    test('two independent lighting actions', () {
      final steps = planFor('turn the lights on and set brightness to 50%').steps;
      expect(steps, hasLength(2));
      expect((steps[0] as SetPowerStep).on, isTrue);
      expect((steps[1] as SetBrightnessStep).brightness.percent, 50);
    });

    test('named device', () {
      final steps =
          planFor('connect to LEDDMX-03-6B4A and turn it on').steps;
      final select = steps.first as SelectDeviceStep;
      expect(select.target, VoiceDeviceTarget.named);
      expect(select.name, 'leddmx 03 6b4a');
      expect(steps[1], isA<ConnectDeviceStep>());
      expect((steps[2] as SetPowerStep).on, isTrue);
    });

    test('last device also gets an implied scan', () {
      final steps = planFor('connect to the last device and turn it on').steps;
      expect(steps[0], isA<ScanDevicesStep>());
      expect(
        (steps[1] as SelectDeviceStep).target,
        VoiceDeviceTarget.lastAvailable,
      );
    });

    test('a wake phrase prefix does not break a compound plan', () {
      final steps =
          planFor('Walsey, scan for devices and turn the first one on').steps;
      expect(steps, hasLength(4));
      expect(steps[0], isA<ScanDevicesStep>());
      expect(
        (steps[1] as SelectDeviceStep).target,
        VoiceDeviceTarget.firstAvailable,
      );
    });
  });

  group('device-only commands', () {
    test('find available devices', () {
      expect(planFor('Find available LED devices').steps.single,
          isA<ScanDevicesStep>());
    });

    test('disconnect', () {
      expect(planFor('disconnect from the current device').steps.single,
          isA<DisconnectDeviceStep>());
    });

    test('reconnect', () {
      expect(planFor('reconnect to the last connected device').steps.single,
          isA<ReconnectLastDeviceStep>());
    });

    test('save scene is recognized but not executable', () {
      expect(planFor('save this scene').steps.single, isA<SaveSceneStep>());
    });

    test('apply scene is refused honestly', () {
      final failure = failureFor('apply the scene');
      expect(failure.kind, VoiceFailureKind.unsupported);
      expect(failure.explanation, contains('Scenes are not implemented'));
    });
  });

  group('safety guarantees are preserved', () {
    test('negation', () {
      expect(
        failureFor("don't scan for devices").kind,
        VoiceFailureKind.unsupported,
      );
    });

    test('questions', () {
      expect(
        failureFor('which devices can you find?').kind,
        VoiceFailureKind.unsupported,
      );
    });

    test('unregistered action in a compound sentence', () {
      expect(
        failureFor('scan for devices and open the door').kind,
        VoiceFailureKind.unsupported,
      );
    });

    test('a whole-sentence command is not half-executed when a connector '
        'introduces an unsupported clause', () {
      // "turn on the lights" alone parses. The trailing clause must not be
      // silently dropped: the plan is refused instead of turning the lights on.
      final failure = failureFor('turn on the lights and play music');
      expect(failure.kind, VoiceFailureKind.unsupported);
    });

    test('a question that mentions a device action is still a question', () {
      final failure = failureFor('should I scan for devices');
      expect(failure.kind, VoiceFailureKind.unsupported);
    });

    test('both on and off is ambiguous, not two actions', () {
      final failure = failureFor('turn the lights on and off');
      expect(failure.kind, VoiceFailureKind.ambiguous);
    });

    test('two brightness values are not split into two steps', () {
      final failure = failureFor('set brightness to 50 and 60 percent');
      expect(failure.kind, VoiceFailureKind.ambiguous);
    });

    test('invalid brightness is reported, never clamped', () {
      final failure = failureFor('set brightness to 150');
      expect(failure.kind, VoiceFailureKind.invalidParameter);
      expect(failure.explanation, contains('0..100'));
    });

    test('an out-of-range effect is refused before any plan', () {
      final failure = failureFor('apply effect 300');
      expect(failure.kind, VoiceFailureKind.invalidParameter);
      expect(failure.explanation, contains('1..210'));
    });

    test('relative brightness stays unexecutable', () {
      final failure = failureFor('increase the brightness');
      expect(failure.kind, VoiceFailureKind.unsupported);
      expect(failure.explanation, contains('device state'));
    });

    test('unrelated sentence is unsupported', () {
      expect(
        failureFor('make me a sandwich').kind,
        VoiceFailureKind.unsupported,
      );
    });
  });
}
