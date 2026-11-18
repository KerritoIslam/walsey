import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/design/color_picker.dart';

void main() {
  const size = Size(200, 200);
  const radius = 100.0;

  group('colorFromWheel', () {
    test('maps the centre to white', () {
      expect(
        colorFromWheel(const Offset(radius, radius), size),
        const Color(0xFFFFFFFF),
      );
    });

    test('maps the top of the disc to a pure hue', () {
      // The sweep starts at the top of the circle, so the rim there is red.
      expect(
        colorFromWheel(const Offset(radius, 0), size),
        const Color(0xFFFF0000),
      );
    });

    test('rotates hue around the rim', () {
      expect(
        colorFromWheel(const Offset(200, radius), size),
        const Color(0xFF80FF00),
      );
      expect(
        colorFromWheel(const Offset(radius, 200), size),
        const Color(0xFF00FFFF),
      );
    });

    test('raises lightness towards the centre', () {
      expect(
        colorFromWheel(const Offset(150, radius), size),
        const Color(0xFFBFFF80),
      );
    });

    test('clamps pointers outside the disc to the rim', () {
      expect(
        colorFromWheel(const Offset(radius, -400), size),
        colorFromWheel(const Offset(radius, 0), size),
      );
      expect(
        colorFromWheel(const Offset(400, radius), size),
        colorFromWheel(const Offset(200, radius), size),
      );
    });

    test('returns white for a degenerate size', () {
      expect(
        colorFromWheel(const Offset(0, 0), Size.zero),
        const Color(0xFFFFFFFF),
      );
    });
  });

  group('wheelPositionFor', () {
    test('places white in the centre', () {
      final position = wheelPositionFor(const Color(0xFFFFFFFF), size);
      expect(position.dx, closeTo(radius, 0.001));
      expect(position.dy, closeTo(radius, 0.001));
    });

    test('places red at the top of the rim', () {
      final position = wheelPositionFor(const Color(0xFFFF0000), size);
      expect(position.dx, closeTo(radius, 0.001));
      expect(position.dy, closeTo(0, 0.001));
    });

    test('round-trips a rim colour through the picker model', () {
      const blue = Color(0xFF0000FF);
      expect(colorFromWheel(wheelPositionFor(blue, size), size), blue);
    });
  });

  group('hex helpers', () {
    test('format lowercase #RRGGBB', () {
      expect(colorToHex(const Color(0xFF7B6CF6)), '#7b6cf6');
      expect(colorToHex(const Color(0xFFFFFFFF)), '#ffffff');
      expect(colorToHex(const Color(0xFF000000)), '#000000');
    });

    test('parse with or without the leading hash', () {
      expect(colorFromHex('#7B6CF6'), const Color(0xFF7B6CF6));
      expect(colorFromHex('7b6cf6'), const Color(0xFF7B6CF6));
      expect(colorFromHex('  #7b6cf6  '), const Color(0xFF7B6CF6));
    });

    test('reject malformed hex input', () {
      expect(colorFromHex(''), isNull);
      expect(colorFromHex('#'), isNull);
      expect(colorFromHex('#7b6cf'), isNull);
      expect(colorFromHex('#7b6cf6aa'), isNull);
      expect(colorFromHex('#gggggg'), isNull);
      expect(colorFromHex('7b6cf6 '), const Color(0xFF7B6CF6));
    });
  });

  group('rgb helpers', () {
    test('format channel values', () {
      expect(colorToRgbText(const Color(0xFF7B6CF6)), '123, 108, 246');
      expect(colorToRgbText(const Color(0xFFFF0000)), '255, 0, 0');
    });

    test('parse comma separated channels', () {
      expect(colorFromRgbText('123, 108, 246'), const Color(0xFF7B6CF6));
      expect(colorFromRgbText(' 255 ,0,  1 '), const Color(0xFFFF0001));
      expect(colorFromRgbText('0,0,0'), const Color(0xFF000000));
    });

    test('reject out of range or malformed channels', () {
      expect(colorFromRgbText(''), isNull);
      expect(colorFromRgbText('256, 0, 0'), isNull);
      expect(colorFromRgbText('-1, 0, 0'), isNull);
      expect(colorFromRgbText('1, 2'), isNull);
      expect(colorFromRgbText('1, 2, 3, 4'), isNull);
      expect(colorFromRgbText('1.5, 2, 3'), isNull);
      expect(colorFromRgbText('a, b, c'), isNull);
    });
  });
}
