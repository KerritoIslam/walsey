import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'audio_capture_port.dart';

export 'audio_capture_port.dart';

/// [AudioCapture] backed by the `record` plugin.
///
/// `pcm16bits` is the only encoder used: Vosk needs raw little-endian samples,
/// and this avoids a second capture pipeline or a WAV decode step. Both Android
/// and Windows implement it; the sample rate is configured explicitly so the
/// engine's expected 16 kHz cannot drift with the OS default.
class RecordAudioCapture implements AudioCapture {
  RecordAudioCapture({
    AudioRecorder? recorder,
    this.device,
    this.autoGain = true,
    this.noiseSuppress = true,
    this.echoCancel = false,
  }) : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;
  final InputDevice? device;
  final bool autoGain;
  final bool noiseSuppress;
  final bool echoCancel;

  /// Returns the available audio input devices on this platform.
  Future<List<InputDevice>> listInputDevices() => _recorder.listInputDevices();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> startStream({required int sampleRate}) {
    return _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        device: device,
        echoCancel: echoCancel,
        noiseSuppress: noiseSuppress,
        autoGain: autoGain,
      ),
    );
  }

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> dispose() => _recorder.dispose();
}
