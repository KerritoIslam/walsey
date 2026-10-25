import 'dart:typed_data';

/// Updates produced by a speech engine while a session is open.
sealed class SpeechEngineEvent {
  const SpeechEngineEvent();
}

/// Unstable in-progress text. Replaced by later updates.
final class SpeechEnginePartial extends SpeechEngineEvent {
  const SpeechEnginePartial(this.text);

  final String text;
}

/// Text of a completed segment inside the current utterance.
final class SpeechEngineSegment extends SpeechEngineEvent {
  const SpeechEngineSegment(this.text);

  final String text;
}

/// The engine failed while consuming audio.
final class SpeechEngineError extends SpeechEngineEvent {
  const SpeechEngineError(this.message);

  final String message;
}

/// Low-level, engine-shaped interface used by [VoskSpeechRecognizer].
///
/// Kept separate from the voice-core `SpeechRecognizer` port so the recognizer
/// can be unit-tested with an in-memory engine: no microphone, no native
/// library and no isolate are needed for that.
///
/// Implementations must serialise their own calls; the recognizer never feeds
/// audio concurrently with [finish] or [reset].
abstract interface class SpeechEngine {
  /// Updates emitted while audio is being fed.
  Stream<SpeechEngineEvent> get events;

  /// Loads the acoustic model at [modelPath], replacing any previous model.
  Future<void> loadModel(String modelPath);

  /// Creates a fresh recognizer for one utterance.
  ///
  /// [grammar] restricts decoding to the given phrases when the engine and the
  /// loaded model support constrained grammars. `null` means unconstrained.
  Future<void> beginSession({required int sampleRate, List<String>? grammar});

  /// Feeds 16-bit little-endian mono PCM at the session sample rate.
  void accept(Uint8List pcm);

  /// Closes the utterance and returns its transcript, or `null` when the
  /// engine recognized no text.
  Future<String?> finish();

  /// Drops the current utterance without producing a transcript.
  Future<void> reset();

  /// Frees the recognizer, the model and any background isolate.
  Future<void> dispose();
}
