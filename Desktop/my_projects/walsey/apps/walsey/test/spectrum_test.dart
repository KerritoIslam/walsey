import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/music/spectrum.dart';

Int16List _sine({double frequency = 1000, int n = 1024}) {
  final samples = Int16List(n);
  for (var i = 0; i < n; i++) {
    samples[i] = (math.sin(2 * math.pi * frequency * i / 16000) * 12000).round();
  }
  return samples;
}

/// Offline analysis only: no microphone, no BLE, no frame and no hardware.
void main() {
  test('a 1 kHz sine peaks at 1 kHz in the mid band', () {
    final frame = const SpectrumAnalyzer().analyze(_sine());
    expect(frame, isNotNull);
    expect(frame!.dominantFrequency, closeTo(1000, 1));
    expect(frame.mid, greaterThan(0));
    expect(frame.bass, lessThan(frame.mid));
    expect(frame.treble, lessThan(frame.mid));
  });

  test('a 4 kHz sine lands in the treble band', () {
    final frame = const SpectrumAnalyzer().analyze(_sine(frequency: 4000));
    expect(frame!.dominantFrequency, closeTo(4000, 1));
    expect(frame.treble, greaterThan(0));
    expect(frame.bass, lessThan(frame.treble));
  });

  test('DC energy stays in the bass band, not in the treble', () {
    final samples = Int16List(256)..fillRange(0, 256, 8000);
    final frame = const SpectrumAnalyzer().analyze(samples);
    // Hann-window leakage can put a little energy in bin 1, so only the band
    // and the absence of high-frequency content are asserted.
    expect(frame!.bass, greaterThan(frame.treble));
    expect(frame.treble, lessThan(0.01));
  });

  test('silence has no dominant frequency and no band energy', () {
    final frame = const SpectrumAnalyzer().analyze(Int16List(512));
    expect(frame!.dominantFrequency, isNull);
    expect(frame.total, 0);
  });

  test('an empty window is not analyzed', () {
    expect(const SpectrumAnalyzer().analyze(Int16List(0)), isNull);
  });

  test('a non-power-of-two window is refused, not zero-padded', () {
    expect(
      () => const SpectrumAnalyzer().analyze(Int16List(1000)),
      throwsArgumentError,
    );
  });

  test('two windows are independent (no hidden streaming state)', () {
    const analyzer = SpectrumAnalyzer();
    final first = analyzer.analyze(_sine(frequency: 1000));
    final second = analyzer.analyze(_sine(frequency: 4000));
    expect(first!.dominantFrequency, closeTo(1000, 1));
    expect(second!.dominantFrequency, closeTo(4000, 1));
  });
}
