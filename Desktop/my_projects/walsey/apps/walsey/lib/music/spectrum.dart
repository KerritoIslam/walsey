import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart spectrum analysis for a future music-reactive mode.
///
/// This is **analysis only**: it takes PCM samples, returns band energies and a
/// dominant frequency. It never touches BLE, a driver or a frame encoder, and no
/// shipped code path calls it. See `docs/music_mode.md` for why music mode is
/// not implemented and what would have to be verified on hardware.
final class SpectrumAnalyzer {
  const SpectrumAnalyzer({this.sampleRate = 16000});

  final int sampleRate;

  /// Analyzes one power-of-two window of mono PCM16 samples.
  ///
  /// A Hann window is applied before the transform to reduce spectral leakage.
  /// Returns `null` for an empty window; shorter windows are refused because a
  /// silent zero-pad would invent resolution that is not present.
  SpectrumFrame? analyze(Int16List samples) {
    if (samples.isEmpty) return null;
    if (samples.length & (samples.length - 1) != 0) {
      throw ArgumentError.value(
        samples.length,
        'samples',
        'length must be a power of two (e.g. 512, 1024, 2048)',
      );
    }

    final n = samples.length;
    final real = Float64List(n);
    final imag = Float64List(n);
    for (var i = 0; i < n; i++) {
      final window = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
      real[i] = (samples[i] / 32768.0) * window;
    }
    _fft(real, imag);

    final bins = n ~/ 2 + 1;
    final magnitudes = Float64List(bins);
    var peakBin = 0;
    var peak = 0.0;
    for (var i = 0; i < bins; i++) {
      final magnitude = math.sqrt(real[i] * real[i] + imag[i] * imag[i]);
      magnitudes[i] = magnitude;
      if (i > 0 && magnitude > peak) {
        peak = magnitude;
        peakBin = i;
      }
    }

    final bass = _band(magnitudes, 20, 250);
    final mid = _band(magnitudes, 250, 2000);
    final treble = _band(magnitudes, 2000, 6000);
    final total = magnitudes.fold<double>(0, (sum, value) => sum + value);

    return SpectrumFrame(
      sampleRate: sampleRate,
      fftSize: n,
      magnitudes: magnitudes,
      dominantFrequency:
          peak <= total * 1e-9 ? null : peakBin * sampleRate / n,
      bass: bass,
      mid: mid,
      treble: treble,
    );
  }

  /// Sums magnitudes whose bin frequency is inside `[low, high)`.
  double _band(Float64List magnitudes, double low, double high) {
    final bucket = sampleRate / ((magnitudes.length - 1) * 2);
    var sum = 0.0;
    for (var i = 1; i < magnitudes.length; i++) {
      final frequency = i * bucket;
      if (frequency < low) continue;
      if (frequency >= high) break;
      sum += magnitudes[i];
    }
    return sum;
  }

  /// In-place iterative radix-2 Cooley–Tukey FFT.
  static void _fft(Float64List real, Float64List imag) {
    final n = real.length;
    // Bit-reversal permutation.
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = real[i];
        real[i] = real[j];
        real[j] = tr;
        final ti = imag[i];
        imag[i] = imag[j];
        imag[j] = ti;
      }
    }
    for (var length = 2; length <= n; length <<= 1) {
      final angle = -2 * math.pi / length;
      final wReal = math.cos(angle);
      final wImag = math.sin(angle);
      for (var start = 0; start < n; start += length) {
        var curReal = 1.0;
        var curImag = 0.0;
        final half = length >> 1;
        for (var k = 0; k < half; k++) {
          final even = start + k;
          final odd = even + half;
          final oddReal = real[odd] * curReal - imag[odd] * curImag;
          final oddImag = real[odd] * curImag + imag[odd] * curReal;
          real[odd] = real[even] - oddReal;
          imag[odd] = imag[even] - oddImag;
          real[even] += oddReal;
          imag[even] += oddImag;
          final nextReal = curReal * wReal - curImag * wImag;
          curImag = curReal * wImag + curImag * wReal;
          curReal = nextReal;
        }
      }
    }
  }
}

/// One analyzed window.
final class SpectrumFrame {
  const SpectrumFrame({
    required this.sampleRate,
    required this.fftSize,
    required this.magnitudes,
    required this.dominantFrequency,
    required this.bass,
    required this.mid,
    required this.treble,
  });

  final int sampleRate;
  final int fftSize;

  /// Half-spectrum magnitude bins (`fftSize / 2 + 1`).
  final Float64List magnitudes;

  /// Strongest non-DC bin, or `null` for a window with no measurable energy.
  final double? dominantFrequency;

  final double bass;
  final double mid;
  final double treble;

  double get total => bass + mid + treble;

  @override
  String toString() =>
      'SpectrumFrame(${dominantFrequency == null ? 'no peak' : '${dominantFrequency!.toStringAsFixed(0)} Hz'}, '
      'bass ${bass.toStringAsFixed(3)}, mid ${mid.toStringAsFixed(3)}, '
      'treble ${treble.toStringAsFixed(3)})';
}
