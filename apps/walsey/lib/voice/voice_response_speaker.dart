import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Platform text-to-speech seam.
///
/// Kept behind an interface so the response policy can be tested without a
/// plugin channel, an audio device or a platform voice.
abstract interface class TtsEngine {
  Future<void> speak(String text);

  Future<void> stop();

  Future<void> dispose();
}

/// [TtsEngine] backed by `flutter_tts`.
///
/// Configuration happens lazily on the first utterance: language, a slightly
/// slower-than-default rate and awaited completion. No voice, pitch or engine
/// is downloaded; this uses whatever the OS already provides.
final class FlutterTtsEngine implements TtsEngine {
  FlutterTtsEngine({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _configured = false;
  bool _disposed = false;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.5);
      await _tts.awaitSpeakCompletion(true);
    } on Object {
      // The platform may not implement every setter. Speaking can still work;
      // if it does not, VoiceResponseSpeaker treats it as best-effort.
    }
  }

  @override
  Future<void> speak(String text) async {
    if (_disposed) return;
    await _configure();
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _tts.stop();
    } on Object {
      // Stopping a silent engine is a no-op.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }
}

/// Optional spoken responses for a voice session.
///
/// Off by default. When enabled the assistant speaks a short outcome, never the
/// full diagnostic message, and the microphone is silenced first so the app
/// cannot transcribe its own voice (echo suppression). TTS failures are
/// swallowed: a missing platform voice must never block recognition or
/// execution.
final class VoiceResponseSpeaker {
  factory VoiceResponseSpeaker({
    required TtsEngine engine,
    bool enabled = false,
  }) =>
      VoiceResponseSpeaker._(engine, enabled);

  VoiceResponseSpeaker._(this._engine, this._enabled);

  final TtsEngine _engine;
  bool _enabled;
  bool _disposed = false;

  bool get enabled => _enabled;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      // Turning responses off must also stop anything already speaking.
      _engine.stop().catchError((Object _) {});
    }
  }

  /// Speaks [text] if responses are enabled. Never throws.
  Future<void> announce(String? text) async {
    if (!_enabled || _disposed) return;
    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    try {
      await _engine.speak(trimmed);
    } on Object catch (error) {
      debugPrint('[WalseyApp] spoken response failed: $error');
    }
  }

  /// Stops any in-progress speech before a microphone session opens.
  ///
  /// Called on pointer down so the take cannot capture a previous response.
  Future<void> silence() async {
    if (!_enabled || _disposed) return;
    try {
      await _engine.stop();
    } on Object {
      // Best effort.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _engine.dispose();
  }
}
