import 'dart:math' as math;
import 'dart:typed_data';

/// Incremental statistics over one captured PCM16 mono stream.
///
/// Everything is computed in a single pass so a 30-second take costs no extra
/// memory: the caller decides separately whether to keep the samples for a WAV
/// export. The numbers here are the only way to tell whether the engine really
/// received what it expects (16-bit samples at the requested rate) instead of
/// assuming the plugin honoured the configuration.
class AudioStats {
  AudioStats({
    required this.declaredSampleRate,
    this.reportSilenceBelow = 0.01,
  });

  /// The rate requested from the recorder, and the rate the engine was told.
  final int declaredSampleRate;

  /// Amplitude (as a fraction of full scale) below which a sample counts as
  /// silence. 0.01 ≈ −40 dBFS, comfortably above room/electrical noise.
  final double reportSilenceBelow;

  int _bytes = 0;
  int _samples = 0;
  int _chunks = 0;
  int _minChunkBytes = 0;
  int _maxChunkBytes = 0;
  int _peakAbs = 0;
  int _clippedSamples = 0;
  double _sumSquares = 0;
  int _silentSamples = 0;

  /// Sample index of the last sample above the silence threshold.
  int _lastLoudSample = -1;

  int get bytes => _bytes;

  int get sampleCount => _samples;

  int get chunkCount => _chunks;

  int get minChunkBytes => _minChunkBytes;

  int get maxChunkBytes => _maxChunkBytes;

  /// Peak absolute amplitude in raw units (0..32768).
  int get peakAbs => _peakAbs;

  /// Samples at or beyond ±32767, i.e. the converter ran out of range.
  int get clippedSamples => _clippedSamples;

  double get clippedPercent =>
      _samples == 0 ? 0 : (_clippedSamples / _samples) * 100;

  /// Duration derived from the sample count at [declaredSampleRate].
  double get durationSeconds =>
      declaredSampleRate == 0 ? 0 : _samples / declaredSampleRate;

  double get peakDbfs => _dbfs(_peakAbs);

  double get rmsDbfs {
    if (_samples == 0) {
      return double.negativeInfinity;
    }
    return _dbfs(math.sqrt(_sumSquares / _samples));
  }

  /// Fraction of samples below the silence threshold.
  double get silentPercent =>
      _samples == 0 ? 0 : (_silentSamples / _samples) * 100;

  /// Length of the silent run at the very end of the take, in seconds.
  ///
  /// A take that ends in the middle of speech may have lost its final word;
  /// a take that ends with silence is unlikely to have been cut off.
  double get trailingSilenceSeconds => _samples == 0
      ? 0
      : (_samples - (_lastLoudSample + 1)) / declaredSampleRate;

  /// Whether the audio looks usable at all, for the diagnostics panel.
  bool get isSilent => _samples > 0 && _peakAbs == 0;

  /// Adds one captured chunk. Odd trailing bytes are carried over by the
  /// recognizer, so chunks here are always whole samples.
  void addChunk(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    final usable = chunk.length - (chunk.length % 2);
    if (usable == 0) {
      return;
    }
    final view = ByteData.sublistView(chunk, 0, usable);
    final sampleCount = usable ~/ 2;
    final silenceLimit = reportSilenceBelow * 32768;
    for (var i = 0; i < sampleCount; i++) {
      final value = view.getInt16(i * 2, Endian.little);
      final magnitude = value == -32768 ? 32768 : value.abs();
      if (magnitude > _peakAbs) {
        _peakAbs = magnitude;
      }
      if (magnitude >= 32767) {
        _clippedSamples++;
      }
      if (magnitude < silenceLimit) {
        _silentSamples++;
      } else {
        _lastLoudSample = _samples + i;
      }
      _sumSquares += value.toDouble() * value;
    }
    _bytes += usable;
    _samples += sampleCount;
    _chunks++;
    if (_chunks == 1) {
      _minChunkBytes = usable;
      _maxChunkBytes = usable;
    } else {
      _minChunkBytes = math.min(_minChunkBytes, usable);
      _maxChunkBytes = math.max(_maxChunkBytes, usable);
    }
  }

  /// Peak sample scaled to a 0..1 full-scale value.
  double get peakFraction => _peakAbs / 32768;

  /// Machine-readable diagnostics, used by the app panel and the harness.
  Map<String, Object?> toJson() => {
    'declaredSampleRate': declaredSampleRate,
    'bytes': _bytes,
    'samples': _samples,
    'durationSeconds': _double(durationSeconds),
    'chunks': _chunks,
    'minChunkBytes': _minChunkBytes,
    'maxChunkBytes': _maxChunkBytes,
    'peakAbs': _peakAbs,
    'peakDbfs': _double(peakDbfs),
    'rmsDbfs': _double(rmsDbfs),
    'silentPercent': _double(silentPercent),
    'clippedSamples': _clippedSamples,
    'clippedPercent': _double(clippedPercent),
    'trailingSilenceSeconds': _double(trailingSilenceSeconds),
  };

  static double _dbfs(num amplitude) {
    if (amplitude <= 0) {
      return double.negativeInfinity;
    }
    return 20 * (math.log(amplitude / 32768) / math.ln10);
  }

  static double _double(double value) =>
      value.isFinite ? double.parse(value.toStringAsFixed(6)) : -999.0;

  @override
  String toString() =>
      'AudioStats(${durationSeconds.toStringAsFixed(2)} s @ '
      '$declaredSampleRate Hz, peak ${peakDbfs.toStringAsFixed(1)} dBFS, '
      'clipped ${clippedPercent.toStringAsFixed(2)}%)';
}
