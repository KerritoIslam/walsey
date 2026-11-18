import 'dart:typed_data';

/// Converts 16-bit little-endian mono PCM into the float32 sample format
/// whisper.cpp expects (`s16 / 32768.0`, so a full-scale negative sample
/// maps to exactly −1.0).
///
/// A trailing odd byte would mean the capture pipeline delivered half a
/// sample; that is a pipeline bug, so it is rejected instead of silently
/// dropped. Pure function, unit-testable without any native library.
Float32List pcm16ToFloat32(Uint8List pcm) {
  if (pcm.length.isOdd) {
    throw FormatException(
      'PCM16 conversion got ${pcm.length} bytes; an odd length means the '
      'audio stream was truncated mid-sample.',
    );
  }
  final view = ByteData.sublistView(pcm);
  final samples = Float32List(pcm.length ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}
