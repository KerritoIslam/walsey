import 'dart:typed_data';

/// Canonical 16-bit PCM WAV helpers.
///
/// Pure Dart on purpose: the diagnostics layer must be usable from the app, the
/// measurement harness and unit tests without a Flutter binding, a microphone
/// or a native library.
///
/// Vosk consumes raw little-endian 16-bit mono samples at a fixed sample rate,
/// so the only format written here is PCM (`audioFormat = 1`), 16 bits, with a
/// 44-byte canonical header. Nothing is resampled: if the bytes were captured at
/// a different rate than [sampleRate] claims, the WAV is mislabelled and the
/// diagnostics must say so instead of hiding it.

const int _riffHeaderBytes = 44;
const int _audioFormatPcm = 1;

/// Encodes [pcm] (little-endian signed 16-bit samples) as a WAV file.
///
/// [pcm] must contain whole samples for [channels]; a trailing partial sample is
/// dropped rather than written as a malformed last frame.
Uint8List encodePcm16Wav(
  Uint8List pcm, {
  required int sampleRate,
  int channels = 1,
}) {
  if (sampleRate <= 0) {
    throw ArgumentError.value(sampleRate, 'sampleRate', 'must be positive');
  }
  if (channels <= 0) {
    throw ArgumentError.value(channels, 'channels', 'must be positive');
  }
  const bitsPerSample = 16;
  final blockAlign = channels * (bitsPerSample ~/ 8);
  final usableBytes = pcm.length - (pcm.length % blockAlign);
  final bytes = Uint8List(_riffHeaderBytes + usableBytes);
  final view = ByteData.sublistView(bytes);

  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes[offset + i] = text.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + usableBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little); // fmt chunk size
  view.setUint16(20, _audioFormatPcm, Endian.little);
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * blockAlign, Endian.little); // byte rate
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, usableBytes, Endian.little);
  bytes.setRange(_riffHeaderBytes, _riffHeaderBytes + usableBytes, pcm);
  return bytes;
}

/// A decoded 16-bit PCM WAV file.
final class WavData {
  const WavData({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.pcm,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// Raw little-endian samples, header stripped.
  final Uint8List pcm;

  int get bytesPerFrame => channels * (bitsPerSample ~/ 8);

  int get frameCount => pcm.length ~/ bytesPerFrame;

  double get durationSeconds => frameCount / sampleRate;

  /// True when the file is exactly what the recognizer expects.
  bool get isRecognizerFormat =>
      sampleRate == 16000 && channels == 1 && bitsPerSample == 16;

  String get description =>
      '$sampleRate Hz, $channels channel${channels == 1 ? '' : 's'}, '
      '$bitsPerSample-bit PCM';
}

/// Parses a PCM WAV file, throwing [FormatException] for anything unsupported.
WavData decodePcm16Wav(Uint8List bytes) {
  if (bytes.length < 12) {
    throw const FormatException('file is shorter than a RIFF header');
  }
  final view = ByteData.sublistView(bytes);
  String ascii(int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));
  if (ascii(0) != 'RIFF' || ascii(8) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }

  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  int? audioFormat;
  Uint8List? data;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = ascii(offset);
    final chunkSize = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (body + chunkSize > bytes.length) {
      throw FormatException('chunk $chunkId is truncated');
    }
    switch (chunkId) {
      case 'fmt ':
        if (chunkSize < 16) {
          throw const FormatException('fmt chunk is too small');
        }
        audioFormat = view.getUint16(body, Endian.little);
        channels = view.getUint16(body + 2, Endian.little);
        sampleRate = view.getUint32(body + 4, Endian.little);
        bitsPerSample = view.getUint16(body + 14, Endian.little);
      case 'data':
        data = bytes.sublist(body, body + chunkSize);
    }
    // Chunks are word aligned.
    offset = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
  }

  if (audioFormat == null || data == null) {
    throw const FormatException('missing fmt or data chunk');
  }
  if (audioFormat != _audioFormatPcm) {
    throw FormatException('unsupported audio format $audioFormat (need PCM)');
  }
  return WavData(
    sampleRate: sampleRate!,
    channels: channels!,
    bitsPerSample: bitsPerSample!,
    pcm: data,
  );
}
