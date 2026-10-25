/// Events emitted by a speech recognizer during a push-to-talk session.
///
/// The voice core deliberately knows nothing about microphones, Vosk, platform
/// channels or isolate plumbing: it only describes what a recognition session
/// can report. Adapters translate engine callbacks into these events; the
/// testing UI and (later) the assistant workflow consume them.
///
/// A recognizer never parses LED intents and never talks to BLE. Turning text
/// into a command stays the job of `VoiceCommandParser`.
sealed class SpeechRecognitionEvent {
  const SpeechRecognitionEvent();
}

/// The microphone is open and audio is being captured.
final class SpeechSessionStarted extends SpeechRecognitionEvent {
  const SpeechSessionStarted();
}

/// Unstable text recognized so far. May arrive zero or more times per session
/// and must not be treated as a final result.
final class SpeechPartialTranscript extends SpeechRecognitionEvent {
  const SpeechPartialTranscript(this.text);

  final String text;
}

/// A non-empty final transcript for the current session.
final class SpeechFinalTranscript extends SpeechRecognitionEvent {
  const SpeechFinalTranscript(this.text);

  final String text;
}

/// The session ended without usable text: silence, noise, or an engine that
/// detected no speech. Deliberately distinct from a final empty string so the
/// UI cannot silently keep showing a previous transcript.
final class SpeechNoSpeechDetected extends SpeechRecognitionEvent {
  const SpeechNoSpeechDetected();
}

/// The user cancelled the session. No transcript is expected afterwards.
final class SpeechSessionCancelled extends SpeechRecognitionEvent {
  const SpeechSessionCancelled();
}

/// The session could not produce text. [kind] is stable enough for the UI to
/// choose a specific remedy (request permission, install a model, retry).
final class SpeechSessionFailed extends SpeechRecognitionEvent {
  const SpeechSessionFailed({required this.kind, required this.message});

  final SpeechFailureKind kind;

  /// Plain-language reason shown to the user. Never contains raw audio, model
  /// contents or credentials.
  final String message;
}

/// Why a recognition attempt could not produce text.
///
/// Kept separate from `VoiceFailureKind` on purpose: "no speech detected" is a
/// recognition outcome, "unsupported command" is a parsing outcome, and
/// "brightness must be 0..100" is a validation outcome. Mixing them would let
/// the UI blame the parser for a microphone problem.
enum SpeechFailureKind {
  /// The operating system (or the user) refused microphone access.
  permissionDenied,

  /// No usable audio input device, or the device disappeared mid-session.
  microphoneUnavailable,

  /// The engine is installed but its language model is not.
  modelNotInstalled,

  /// A model file exists but is incomplete or unreadable.
  modelInvalid,

  /// The native engine library could not be loaded on this platform.
  nativeLibraryUnavailable,

  /// This platform has no adapter yet.
  unsupportedPlatform,

  /// The recognizer has no model for the requested language.
  unsupportedLanguage,

  /// Model/engine initialization failed for another reason.
  initializationFailed,

  /// The engine reported an error while recognizing.
  recognitionFailed,

  /// A session was requested while another one was already running.
  alreadyRunning;

  String get label => switch (this) {
        SpeechFailureKind.permissionDenied => 'Microphone permission denied',
        SpeechFailureKind.microphoneUnavailable => 'Microphone unavailable',
        SpeechFailureKind.modelNotInstalled => 'Language model missing',
        SpeechFailureKind.modelInvalid => 'Language model invalid',
        SpeechFailureKind.nativeLibraryUnavailable =>
          'Speech engine library missing',
        SpeechFailureKind.unsupportedPlatform => 'Platform not supported',
        SpeechFailureKind.unsupportedLanguage => 'Language not supported',
        SpeechFailureKind.initializationFailed => 'Initialization failed',
        SpeechFailureKind.recognitionFailed => 'Recognition failed',
        SpeechFailureKind.alreadyRunning => 'A session is already running',
      };
}
