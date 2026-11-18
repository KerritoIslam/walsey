/// Stage 2 offline speech recognition for Walsey.
///
/// The pure-Dart port (`SpeechRecognizer`, session events) lives in
/// `walsey_voice_core`. This package supplies the replaceable engine
/// adapters — Whisper (whisper.cpp, primary) and Vosk (fallback) — plus
/// microphone capture, explicit model management and the push-to-talk
/// workflow controller used by the testing UI.
///
/// No cloud fallback, no paid service, no command execution and no BLE import:
/// recognized text is parsed by the same Stage 1 parser as typed text.
library;

export 'src/audio/audio_capture.dart';
export 'src/audio/pcm16.dart';
export 'src/audio/voice_activity.dart';
export 'src/diagnostics/audio_stats.dart';
export 'src/diagnostics/latency.dart';
export 'src/diagnostics/session_diagnostics.dart';
export 'src/diagnostics/wav.dart';
export 'src/engine/speech_engine.dart';
export 'src/model/model_catalog.dart';
export 'src/model/model_store.dart';
export 'src/push_to_talk_controller.dart';
export 'src/speech_recognizer.dart';
export 'src/vosk/vosk_result.dart';
export 'src/vosk/vosk_speech_engine.dart';
export 'src/wake/onnx_wake_word_detector.dart';
export 'src/wake/buffered_speech_recognizer.dart';
export 'src/wake/wake_word_command_loop.dart';
export 'src/wake/phonetic_wake_matcher.dart';
export 'src/wake/vosk_wake_word_detector.dart';
export 'src/wake/wake_word_start_exception.dart';
export 'src/whisper/whisper_bindings.dart';
export 'src/whisper/whisper_pcm.dart';
export 'src/whisper/whisper_result.dart';
export 'src/whisper/whisper_speech_engine.dart';
export 'src/whisper/whisper_speech_recognizer.dart';
export 'src/vosk_speech_recognizer.dart';
