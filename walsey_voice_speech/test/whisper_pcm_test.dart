import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

void main() {
  group('pcm16ToFloat32', () {
    test('maps full-scale extremes to ±1.0', () {
      final samples = pcm16ToFloat32(Uint8List.fromList(const [
        0x00, 0x80, // -32768
        0xff, 0x7f, //  32767
      ]));

      expect(samples.length, 2);
      expect(samples[0], -1.0);
      expect(samples[1], 32767 / 32768.0);
    });

    test('silence and small amplitudes convert exactly', () {
      final samples = pcm16ToFloat32(Uint8List.fromList(const [
        0x00, 0x00, //  0
        0x01, 0x00, //  1
        0xff, 0xff, // -1
      ]));

      expect(samples[0], 0.0);
      expect(samples[1], 1 / 32768.0);
      expect(samples[2], -1 / 32768.0);
    });

    test('reads little-endian bytes', () {
      // 0x1234 stored little-endian is 0x34, 0x12.
      final samples = pcm16ToFloat32(Uint8List.fromList(const [0x34, 0x12]));
      expect(samples.single, 0x1234 / 32768.0);
    });

    test('an odd byte count is rejected, not silently truncated', () {
      expect(
        () => pcm16ToFloat32(Uint8List.fromList(const [0x01, 0x02, 0x03])),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('odd length'),
          ),
        ),
      );
    });

    test('empty input converts to an empty sample list', () {
      expect(pcm16ToFloat32(Uint8List(0)), isEmpty);
    });

    test('a realistic 16 kHz chunk converts to the expected sample count', () {
      // 3200 bytes = 1600 samples = 0.1 s at 16 kHz.
      expect(pcm16ToFloat32(Uint8List(3200)).length, 1600);
    });
  });
}
