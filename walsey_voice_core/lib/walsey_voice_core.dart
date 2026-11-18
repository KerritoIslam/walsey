/// Pure Dart voice-command understanding for Walsey.
///
/// Stage 1: deterministic text -> validated intent.
/// Stage 2: the `SpeechRecognizer` port and its session events. Still no
/// microphone code, no engine dependency, no Flutter and no command execution:
/// adapters live in `walsey_voice_speech`.
library;

export 'src/context/voice_conversation.dart';
export 'src/domain/errors.dart';
export 'src/domain/voice_intent.dart';
export 'src/domain/voice_parameters.dart';
export 'src/domain/voice_result.dart';
export 'src/parser/normalization.dart';
export 'src/parser/voice_command_parser.dart';
export 'src/plan/command_interpreter.dart';
export 'src/plan/voice_plan.dart';
export 'src/plan/voice_plan_parser.dart';
export 'src/registry/command_registry.dart';
export 'src/speech/speech_event.dart';
export 'src/speech/speech_recognizer.dart';
export 'src/wake/wake_word_detector.dart';
