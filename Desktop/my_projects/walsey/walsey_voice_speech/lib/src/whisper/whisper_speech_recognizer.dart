import 'package:walsey_voice_core/walsey_voice_core.dart';

import '../diagnostics/session_diagnostics.dart';
import '../model/model_catalog.dart';
import '../speech_recognizer.dart';
import 'whisper_speech_engine.dart';

/// [SpeechRecognizer] for the Whisper (whisper.cpp) engine — the primary
/// Stage 2 recognition engine.
///
/// All session logic lives in [EngineSpeechRecognizer]; this class only
/// supplies the Whisper binding. Whisper is batch-decoding: no partial
/// transcripts arrive while the user speaks, the whole utterance is decoded
/// when the session stops. English (US) is the only language with a Whisper
/// model in this build; the Vosk fallback keeps the other catalogue entries.
class WhisperSpeechRecognizer extends EngineSpeechRecognizer {
  WhisperSpeechRecognizer({
    super.modelStore,
    super.engine,
    super.audioCapture,
    super.language = SpeechLanguage.defaultLanguage,
    super.diagnostics,
    super.sampleRate = 16000,
    super.captureStopTimeout,
    super.platformSupported,
  }) : super(
          binding: SpeechEngineBinding(
            name: 'Whisper',
            spawn: WhisperSpeechEngine.spawn,
            platformSupported: () => WhisperSpeechEngine.isSupportedPlatform,
            modelFor: (language) => language.whisperModel,
            nativeLibraryHint:
                'The native whisper.cpp libraries could not be loaded. '
                'Android builds ship them in the APK; Windows needs '
                'whisper.dll and the ggml*.dll files next to the executable '
                '(see tools/fetch_whisper_windows.ps1).',
            downloadableModels: SpeechModel.all,
          ),
        );

  /// Convenience constructor for the app.
  factory WhisperSpeechRecognizer.platform({
    SessionDiagnostics? diagnostics,
  }) => WhisperSpeechRecognizer(diagnostics: diagnostics);
}
