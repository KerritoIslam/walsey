import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Microphone capture seam.
///
/// The recognizer only needs three things from the platform: permission, a
/// 16-bit PCM stream, and a way to stop releasing the device. Keeping that
/// behind an interface lets the recognition workflow be tested without a
/// microphone or a plugin channel.
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

/// [AudioCapture] backed by the `record` plugin.
///
/// `pcm16bits` is the only encoder used: Vosk needs raw little-endian samples,
/// and this avoids a second capture pipeline or a WAV decode step. Both Android
/// and Windows implement it; the sample rate is configured explicitly so the
/// engine's expected 16 kHz cannot drift with the OS default.
class RecordAudioCapture implements AudioCapture {
  RecordAudioCapture({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> startStream({required int sampleRate}) {
    return _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ),
    );
  }

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> dispose() => _recorder.dispose();
}
