import 'package:test/test.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import 'test_utils.dart';

// Expected bytes are written out by hand from LED_UNION docs/protocol/ledble.md
// (and src/lib/protocol/ffe0.ts), NOT computed with the same logic as the
// encoder. They prove the encoder matches the documentation; they do not prove
// the controller accepts the frames.
void main() {
  const filler = LeddmxLayout.filler;
  const shifted = LeddmxLayout.shifted;

  group('power', () {
    test('filler', () {
      expect(hex(encodePower(filler, on: true)), '7b 04 04 01 ff ff ff ff bf');
      expect(hex(encodePower(filler, on: false)), '7b 04 04 00 ff ff ff ff bf');
    });
    test('shifted', () {
      expect(hex(encodePower(shifted, on: true)), '7b 04 01 ff ff ff ff ff bf');
      expect(hex(encodePower(shifted, on: false)), '7b 04 00 ff ff ff ff ff bf');
    });
  });

  group('rgb', () {
    // Distinct channel values so a swapped position is obvious.
    final c = RgbColor(0x11, 0x22, 0x33);
    test('filler', () {
      expect(hex(encodeRgb(filler, c)), '7b ff 07 11 22 33 00 ff bf');
    });
    test('shifted', () {
      expect(hex(encodeRgb(shifted, c)), '7b 07 11 22 33 00 ff ff bf');
    });
    test('channel extremes are preserved', () {
      expect(hex(encodeRgb(filler, RgbColor(255, 0, 128))),
          '7b ff 07 ff 00 80 00 ff bf');
    });
  });

  group('brightness', () {
    test('filler sends scaled (0..32) then raw', () {
      expect(hex(encodeBrightness(filler, BrightnessLevel(100))),
          '7b ff 01 20 64 00 ff ff bf');
      expect(hex(encodeBrightness(filler, BrightnessLevel(50))),
          '7b ff 01 10 32 00 ff ff bf');
      expect(hex(encodeBrightness(filler, BrightnessLevel(0))),
          '7b ff 01 00 00 00 ff ff bf');
    });
    test('filler scaling floors (documents the open floor-vs-round question)',
        () {
      // 30 * 32 / 100 = 9.6 -> 9 with integer division. LED_UNION's driver
      // would emit 10. Pinned here so a change is deliberate.
      expect(hex(encodeBrightness(filler, BrightnessLevel(30))),
          '7b ff 01 09 1e 00 ff ff bf');
    });
    test('shifted sends raw percent only', () {
      expect(hex(encodeBrightness(shifted, BrightnessLevel(50))),
          '7b 01 32 00 ff ff ff ff bf');
    });
  });

  group('effect', () {
    test('filler', () {
      expect(hex(encodeEffect(filler, LedEffect(3))),
          '7b ff 03 03 ff ff ff ff bf');
      expect(hex(encodeEffect(filler, LedEffect(255))),
          '7b ff 03 ff ff ff ff ff bf');
    });
    test('shifted', () {
      expect(hex(encodeEffect(shifted, LedEffect(3))),
          '7b 03 03 ff ff ff ff ff bf');
    });
    test('opcode byte is built-in 0x03, never DIY 0x13', () {
      // Opcode sits at index 2 (filler) or 1 (shifted). Effect ids are NOT
      // scanned: id 19 legitimately equals 0x13.
      for (final id in [1, 19, 72, 73, 210, 255]) {
        expect(encodeEffect(filler, LedEffect(id))[2], 0x03, reason: 'filler $id');
        expect(encodeEffect(shifted, LedEffect(id))[1], 0x03,
            reason: 'shifted $id');
      }
    });
  });

  group('handshake', () {
    // 2026-10-19 is a Monday (2026-10-23 is a Friday).
    test('Monday 14:30 -> tb = (1<<5)|14 = 0x2e', () {
      expect(hex(encodeHandshake(DateTime(2026, 10, 19, 14, 30))),
          '2a 02 a1 23 45 67 2e 1e af');
    });
    test('Sunday 23:59 -> weekIndex 7, tb = 0xf7', () {
      expect(hex(encodeHandshake(DateTime(2026, 10, 25, 23, 59))),
          '2a 02 a1 23 45 67 f7 3b af');
    });
    test('Saturday 00:00 -> weekIndex 6, tb = 0xc0', () {
      expect(hex(encodeHandshake(DateTime(2026, 10, 24, 0, 0))),
          '2a 02 a1 23 45 67 c0 00 af');
    });
    test('custom password', () {
      expect(
          hex(encodeHandshake(DateTime(2026, 10, 19, 14, 30),
              password: [1, 2, 3, 4])),
          '2a 02 01 02 03 04 2e 1e af');
    });
    test('rejects bad passwords', () {
      final t = DateTime(2026, 10, 19);
      expect(() => encodeHandshake(t, password: [1, 2, 3]),
          throwsA(isA<InvalidCommandException>()));
      expect(() => encodeHandshake(t, password: [1, 2, 3, 256]),
          throwsA(isA<InvalidCommandException>()));
      expect(() => encodeHandshake(t, password: [1, 2, 3, -1]),
          throwsA(isA<InvalidCommandException>()));
    });
    test('password query', () {
      expect(hex(encodePasswordQuery()), '2a 05 ff ff ff ff ff ff af');
    });
  });

  group('envelope invariants', () {
    test('every 7B frame is 9 bytes, starts 7b, ends bf', () {
      for (final layout in LeddmxLayout.values) {
        final frames = [
          encodePower(layout, on: true),
          encodePower(layout, on: false),
          for (var v = 0; v <= 100; v++) encodeBrightness(layout, BrightnessLevel(v)),
          for (final id in [...List.generate(210, (i) => i + 1), 255])
            encodeEffect(layout, LedEffect(id)),
          for (final r in [0, 1, 127, 255])
            for (final g in [0, 128, 255])
              for (final b in [0, 64, 255]) encodeRgb(layout, RgbColor(r, g, b)),
        ];
        for (final f in frames) {
          expect(f.length, 9);
          expect(f.first, 0x7b);
          expect(f.last, 0xbf);
        }
      }
    });
  });
}
