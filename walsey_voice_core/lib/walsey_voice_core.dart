/// Pure Dart voice-command understanding for Walsey.
///
/// Stage 1: deterministic text -> validated intent.
/// Stage 2: the `SpeechRecognizer` port and its session events. Still no
/// microphone code, no engine dependency, no Flutter and no command execution:
/// adapters live in `walsey_voice_speech`.
library;

export 'src/domain/errors.dart';
export 'src/domain/voice_intent.dart';
export 'src/domain/voice_parameters.dart';
export 'src/domain/voice_result.dart';
export 'src/parser/normalization.dart';
export 'src/parser/voice_command_parser.dart';
export 'src/registry/command_registry.dart';
export 'src/speech/speech_event.dart';
export 'src/speech/speech_recognizer.dart';
