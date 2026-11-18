/// Whether a wake-word engine could run on this platform right now.
///
/// This describes *capability*, never "enabled": the app ships with the
/// detector unwired, so the assistant never listens in the background.
enum WakeWordCapability {
  /// No detector is configured. This is the shipped state.
  notConfigured,

  /// The platform has no supported always-on capture path.
  unsupportedPlatform,

  /// The user or OS denied microphone/background permission.
  permissionDenied,

  /// A detector could be prepared, but it is still not started automatically.
  available,
}

/// Result of preparing a [WakeWordDetector].
final class WakeWordAvailability {
  const WakeWordAvailability({
    required this.capability,
    required this.message,
  });

  final WakeWordCapability capability;

  /// User-facing explanation; must not claim the detector is running.
  final String message;

  bool get isReady => capability == WakeWordCapability.available;
}

/// Events a wake-word detector may emit once it is explicitly started.
sealed class WakeWordEvent {
  const WakeWordEvent();
}

/// The configured phrase was recognized. No transcript exists yet: a real
/// session must still be started by the user (or by an explicit opt-in policy).
final class WakeWordDetected extends WakeWordEvent {
  const WakeWordDetected({required this.phrase});

  final String phrase;
}

/// The detector stopped or failed. Carries no audio and no transcript.
final class WakeWordFailed extends WakeWordEvent {
  const WakeWordFailed({required this.message});

  final String message;
}

/// Port for an always-on wake-word engine.
///
/// Walsey intentionally ships **no implementation** of this port. It exists so
/// a future local detector can be added without changing the user-facing
/// workflow:
///
/// * hold-to-talk stays the only way to start recognition today;
/// * a detector may only be started by an explicit user action, never at app
///   start;
/// * audio is processed on the device and never uploaded;
/// * a detection is a *request* to open the normal single session, not a
///   command and not an execution.
///
/// Platform constraints (background microphone use, foreground services,
/// battery optimisation) are documented in `docs/wake_word.md`.
abstract interface class WakeWordDetector {
  /// Stable engine name for diagnostics.
  String get engineName;

  /// Events from the running detector. Empty until [start] is called.
  Stream<WakeWordEvent> get events;

  /// Checks permissions and model availability without listening.
  Future<WakeWordAvailability> prepare();

  /// Starts listening for the wake phrase. Must be an explicit action.
  Future<void> start();

  /// Stops listening and releases the audio source.
  Future<void> stop();

  Future<void> dispose();
}
