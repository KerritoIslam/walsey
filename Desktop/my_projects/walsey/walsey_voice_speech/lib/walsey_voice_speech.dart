/// Stage 2 offline speech recognition for Walsey.
///
/// The pure-Dart port (`SpeechRecognizer`, session events) lives in
/// `walsey_voice_core`. This package supplies the replaceable Vosk adapter,
/// microphone capture, explicit model management and the push-to-talk workflow
/// controller used by the testing UI.
///
/// No cloud fallback, no paid service, no command execution and no BLE import:
/// recognized text is parsed by the same Stage 1 parser as typed text.
library;

export 'src/audio/audio_capture.dart';
export 'src/diagnostics/audio_stats.dart';
export 'src/diagnostics/session_diagnostics.dart';
export 'src/diagnostics/wav.dart';
export 'src/model/model_catalog.dart';
export 'src/model/model_store.dart';
export 'src/push_to_talk_controller.dart';
export 'src/vosk/speech_engine.dart';
export 'src/vosk/vosk_result.dart';
export 'src/vosk/vosk_speech_engine.dart';
export 'src/vosk_speech_recognizer.dart';
