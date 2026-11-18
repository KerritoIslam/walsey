import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'diagnostics/session_diagnostics.dart';
import 'model/model_catalog.dart';
import 'vosk/vosk_speech_engine.dart';
import 'speech_recognizer.dart';

/// [SpeechRecognizer] for the Vosk fallback engine.
///
/// All session logic lives in [EngineSpeechRecognizer]; this class only
/// supplies the Vosk binding (engine factory, model resolution, failure
/// texts). Vosk is no longer the primary engine — Whisper is — but it stays
/// installable and selectable for comparison and rollback.
class VoskSpeechRecognizer extends EngineSpeechRecognizer {
  VoskSpeechRecognizer({
    super.modelStore,
    super.engine,
    super.audioCapture,
    super.language = SpeechLanguage.defaultLanguage,
    super.diagnostics,
    super.grammar,
    super.sampleRate = 16000,
    super.captureStopTimeout,
    super.platformSupported,
  }) : super(
          binding: SpeechEngineBinding(
            name: 'Vosk',
            spawn: VoskSpeechEngine.spawn,
            platformSupported: () => VoskSpeechEngine.isSupportedPlatform,
            modelFor: (language) => language.model,
            nativeLibraryHint:
                'The native Vosk library could not be loaded. Android builds '
                'ship it in the APK; Windows needs libvosk.dll next to the '
                'executable (see tools/fetch_vosk_windows.ps1).',
            downloadableModels: const [
              SpeechModel.englishUs,
              SpeechModel.french,
              SpeechModel.arabic,
            ],
          ),
        );

  /// Convenience constructor for the app.
  factory VoskSpeechRecognizer.platform({SessionDiagnostics? diagnostics}) =>
      VoskSpeechRecognizer(diagnostics: diagnostics);
}
