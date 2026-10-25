import 'package:test/test.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

Matcher get invalid => throwsA(isA<InvalidCommandException>());

void main() {
  group('RgbColor', () {
    test('accepts the full 0..255 range', () {
      expect(RgbColor(0, 0, 0), RgbColor(0, 0, 0));
      expect(RgbColor(255, 255, 255).r, 255);
    });
    test('rejects out-of-range channels', () {
      expect(() => RgbColor(256, 0, 0), invalid);
      expect(() => RgbColor(0, -1, 0), invalid);
      expect(() => RgbColor(0, 0, 999), invalid);
    });
  });

  group('BrightnessLevel', () {
    test('accepts 0..100', () {
      expect(BrightnessLevel(0).percent, 0);
      expect(BrightnessLevel(100).percent, 100);
    });
    test('rejects values outside 0..100', () {
      expect(() => BrightnessLevel(-1), invalid);
      expect(() => BrightnessLevel(101), invalid);
    });
  });

  group('LedEffect', () {
    test('accepts documented ids 1..210 and 255', () {
      for (final id in [1, 72, 73, 210, 255]) {
        expect(LedEffect(id).id, id);
      }
    });
    test('rejects ids outside the documented set', () {
      for (final id in [-1, 0, 211, 254, 256]) {
        expect(() => LedEffect(id), invalid, reason: 'id $id');
      }
    });
  });

  test('commands are only constructible from validated values', () {
    // A command wraps value objects, so an invalid value can't exist to wrap.
    final cmd = SetBrightnessCommand(BrightnessLevel(50));
    expect(cmd.brightness.percent, 50);
    expect(const PowerCommand(on: true).on, isTrue);
  });
}
