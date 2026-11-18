import 'dart:async';
import 'dart:typed_data';

/// Microphone capture seam.
///
/// Kept in its own file, free of Flutter and plugin imports, so pure-Dart tools
/// (the accuracy harnesses) can depend on the interface without pulling
/// `package:flutter` into a `dart run` process. The plugin-backed
/// implementation lives in `audio_capture.dart`.
abstract interface class AudioCapture {
  /// Queries (and on Android requests) microphone permission.
  Future<bool> hasPermission();

  /// Opens the microphone and returns 16-bit little-endian mono PCM chunks.
  Future<Stream<Uint8List>> startStream({required int sampleRate});

  /// Closes the microphone. Safe to call when capture is not running.
  Future<void> stop();

  /// Releases plugin resources.
  Future<void> dispose();
}
