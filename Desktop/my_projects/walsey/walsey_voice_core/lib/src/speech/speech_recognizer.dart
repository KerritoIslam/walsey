import 'speech_event.dart';

/// Whether speech recognition can start right now.
///
/// `initialize()` returns one of these instead of throwing, because "the model
/// is not installed yet" is an expected, recoverable state that the UI must be
/// able to explain, not an exceptional crash.
sealed class SpeechAvailability {
  const SpeechAvailability();
}

/// The engine loaded and a model is ready. A session can start.
final class SpeechReady extends SpeechAvailability {
  const SpeechReady();
}

/// The engine is usable but no language model is installed. The UI offers an
/// explicit install action; nothing is downloaded automatically.
final class SpeechModelRequired extends SpeechAvailability {
  const SpeechModelRequired({required this.message});

  final String message;
}

/// Recognition cannot run here. [kind] tells the UI which remedy to show.
final class SpeechUnavailable extends SpeechAvailability {
  const SpeechUnavailable({required this.kind, required this.message});

  final SpeechFailureKind kind;
  final String message;
}

/// Replaceable speech-to-text port used by the Walsey assistant.
///
/// Contract for implementations:
/// - only capture audio while [start] is active; never listen continuously;
/// - emit [SpeechPartialTranscript] zero or more times, then exactly one of
///   [SpeechFinalTranscript], [SpeechNoSpeechDetected], [SpeechSessionCancelled]
///   or [SpeechSessionFailed] per session;
/// - never parse commands, never call BLE, never execute anything;
/// - release the microphone in [stop], [cancel] and [dispose].
///
/// `start`/`stop` must return promptly; they may not block the UI until the
/// whole utterance has been recognized.
abstract interface class SpeechRecognizer {
  /// Session events. The stream is broadcast and survives across sessions;
  /// callers filter by their own session token.
  Stream<SpeechRecognitionEvent> get events;

  /// Loads the engine and reports whether a session can start.
  ///
  /// Idempotent: calling it again must not reload an already loaded model.
  Future<SpeechAvailability> initialize({String? languageId});

  /// Starts a push-to-talk session.
  ///
  /// Throws [StateError] if a session is already active.
  Future<void> start({String? languageId});

  /// Ends the current session, flushing the final recognition result.
  Future<void> stop();

  /// Ends the current session and discards its audio/transcript.
  Future<void> cancel();

  /// Releases the microphone, engine handles and model memory.
  Future<void> dispose();
}
