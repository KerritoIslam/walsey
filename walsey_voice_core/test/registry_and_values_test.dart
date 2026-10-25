import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

void main() {
  group('CommandRegistry', () {
    test('ledDefaults registers all LED actions once', () {
      final registry = CommandRegistry.ledDefaults();
      expect(registry.actions, hasLength(VoiceIntent.values.length));
      expect(
        registry.actions.map((a) => a.id).toSet(),
        VoiceIntent.values.map((i) => i.name).toSet(),
      );
      expect(
        registry.actions.every((a) => a.domain == VoiceDomain.led),
        isTrue,
      );
      for (final action in registry.actions) {
        expect(action.description, isNotEmpty);
        expect(action.example, isNotEmpty);
      }
    });

    test('lookup exposes the registered spec', () {
      final registry = CommandRegistry.ledDefaults();
      expect(registry.lookup(VoiceIntent.setColor)?.id, 'setColor');
      expect(registry.supports(VoiceIntent.applyEffect), isTrue);
    });

    test('duplicate intents are rejected', () {
      const action = VoiceActionSpec(
        intent: VoiceIntent.powerOn,
        domain: VoiceDomain.led,
        description: 'on',
        example: 'lights on',
      );
      expect(
        () => CommandRegistry(const [action, action]),
        throwsArgumentError,
      );
    });

    test('a blank description is rejected', () {
      const action = VoiceActionSpec(
        intent: VoiceIntent.powerOn,
        domain: VoiceDomain.led,
        description: '  ',
        example: 'lights on',
      );
      expect(() => CommandRegistry(const [action]), throwsArgumentError);
    });

    test('an empty registry authorizes nothing', () {
      final registry = CommandRegistry(const []);
      expect(registry.actions, isEmpty);
      expect(registry.supports(VoiceIntent.powerOn), isFalse);
      expect(registry.lookup(VoiceIntent.powerOn), isNull);
    });
  });

  group('parameter value objects', () {
    test('VoiceBrightness accepts 0..100', () {
      expect(VoiceBrightness(0).percent, 0);
      expect(VoiceBrightness(100).percent, 100);
    });

    test('VoiceBrightness rejects out-of-range values', () {
      expect(
          () => VoiceBrightness(-1), throwsA(isA<VoiceParameterException>()));
      expect(
          () => VoiceBrightness(101), throwsA(isA<VoiceParameterException>()));
    });

    test('VoiceEffect accepts the documented ids', () {
      for (final id in [1, 72, 73, 210, 255]) {
        expect(VoiceEffect(id).id, id);
      }
    });

    test('VoiceEffect rejects undocumented ids', () {
      for (final id in [-1, 0, 211, 254, 256]) {
        expect(
          () => VoiceEffect(id),
          throwsA(isA<VoiceParameterException>()),
          reason: 'id $id',
        );
      }
    });

    test('VoiceColor.fromWord only recognizes the controlled list', () {
      expect(VoiceColor.fromWord('blue'), VoiceColor.blue);
      expect(VoiceColor.fromWord('violet'), VoiceColor.purple);
      expect(VoiceColor.fromWord('teal'), isNull);
      expect(VoiceColor.fromWord('blueish'), isNull);
    });
  });
}
