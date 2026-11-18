import 'dart:async';
import 'dart:typed_data';

import 'package:walsey_voice_core/walsey_voice_core.dart';

import '../audio/voice_activity.dart';
import 'buffered_speech_recognizer.dart';
import 'onnx_wake_word_detector.dart';

/// One observed step of the hands-free pipeline.
sealed class WakeCommandEvent {
  const WakeCommandEvent();
}

/// The detector is running and the microphone is delivering audio.
final class WakeListening extends WakeCommandEvent {
  const WakeListening();
}

/// "Walsey" was detected; the command that follows is being captured.
final class WakeDetected extends WakeCommandEvent {
  const WakeDetected();
}

/// Enough voiced audio arrived to know a command is being spoken.
final class WakeCapturing extends WakeCommandEvent {
  const WakeCapturing();
}

/// The captured command was transcribed. [text] is the raw engine output.
final class WakeTranscript extends WakeCommandEvent {
  const WakeTranscript(this.text);

  final String text;
}

/// Nothing usable was captured (silence, timeout or an empty decode).
final class WakeEmpty extends WakeCommandEvent {
  const WakeEmpty(this.message);

  final String message;
}

/// The pipeline stopped or could not continue. [recoverable] is false when the
/// listener must be started again explicitly.
final class WakeFailed extends WakeCommandEvent {
  const WakeFailed(this.message, {this.recoverable = false});

  final String message;
  final bool recoverable;
}

/// The listener stopped on request.
final class WakeStopped extends WakeCommandEvent {
  const WakeStopped();
}

/// The seam the app coordinates hands-free listening through.
///
/// [WakeWordCommandLoop] is the shipped implementation. The interface exists so
/// the app's session controller can be tested with an in-memory source (no
/// microphone, no model) and so a different lightweight detector pipeline can
/// replace the loop without touching the UI.
abstract interface class WakeCommandSource {
  /// Detector, capture and transcript events.
  Stream<WakeCommandEvent> get events;

  /// True while a detected command is being captured/decoded.
  bool get isCapturing;

  /// Starts the detector. The caller must have explicit user consent.
  Future<void> start();

  /// Stops capture and releases the microphone.
  Future<void> stop();

  /// Loads models/engines without opening the microphone.
  Future<WakeWordAvailability> prewarm();

  Future<void> dispose();
}

/// Turns "Walsey" detections into captured command audio and transcripts.
///
/// Responsibilities:
/// * keep a rolling pre-roll buffer so the words spoken immediately after the
///   wake phrase are not lost;
/// * run [VoiceActivityDetector] from the detection point so the command ends
///   on silence instead of on a button release;
/// * stop the detector before decoding, so only one microphone consumer exists
///   at a time;
/// * hand the transcript to the caller, which still has to parse, validate and
///   execute it through the normal (unchanged) pipeline.
///
/// It never parses text, never executes anything and never fabricates a
/// transcript: an empty buffer produces [WakeEmpty].
final class WakeWordCommandLoop implements WakeCommandSource {
  WakeWordCommandLoop({
    required OnnxWakeWordDetector detector,
    required BufferedRecognizer recognizer,
    this.preRoll = const Duration(milliseconds: 1500),
    this.commandTimeout = const Duration(seconds: 8),
    this.autoResume = true,
    this.sampleRate = 16000,
    VoiceActivityConfig vadConfig = const VoiceActivityConfig(),
  })  : _detector = detector,
        _recognizer = recognizer,
        _vad = VoiceActivityDetector(sampleRate: sampleRate, config: vadConfig),
        _vadConfig = vadConfig;

  final OnnxWakeWordDetector _detector;
  final BufferedRecognizer _recognizer;
  final VoiceActivityDetector _vad;
  final VoiceActivityConfig _vadConfig;

  /// Audio kept from before the wake detection.
  final Duration preRoll;

  /// How long after a detection the command may take to start / total budget.
  final Duration commandTimeout;

  /// Whether to restart the detector after a completed take. A single restart
  /// after success is not a retry loop; a failure never resumes automatically.
  final bool autoResume;

  final int sampleRate;

  final StreamController<WakeCommandEvent> _events =
      StreamController<WakeCommandEvent>.broadcast();

  final List<Uint8List> _ring = [];
  int _ringBytes = 0;
  final BytesBuilder _capture = BytesBuilder(copy: false);
  int _captureBytes = 0;

  StreamSubscription<WakeWordEvent>? _detectorEvents;

  _LoopState _state = _LoopState.idle;
  bool _disposed = false;
  bool _stopRequested = false;

  Timer? _speechStartTimer;
  Timer? _hardTimer;
  bool _speechSeen = false;

  /// Serialises finalisation so two events (silence end plus timeout) can never
  /// decode the same capture twice.
  Future<void>? _finishFuture;

  @override
  Stream<WakeCommandEvent> get events => _events.stream;

  bool get isRunning =>
      _state == _LoopState.listening || _state == _LoopState.capturing;

  @override
  bool get isCapturing => _state == _LoopState.capturing;

  /// Loads the wake model and the recognition engine **without** opening the
  /// microphone.
  ///
  /// Called when the Assistant page opens so the first hands-free command is
  /// not slowed down by a cold engine. It never starts listening: only
  /// [start] does that, and only after the user asked for it. Returns the
  /// detector availability so the UI can explain a missing model honestly.
  @override
  Future<WakeWordAvailability> prewarm() async {
    if (_disposed) {
      throw StateError('The wake command loop has been disposed.');
    }
    final availability = await _detector.prepare();
    if (availability.capability != WakeWordCapability.available) {
      return availability;
    }
    final recognizer = _recognizer;
    if (recognizer is BufferedSpeechRecognizer) {
      await recognizer.prepare();
    }
    return availability;
  }

  int get _preRollBytes => (sampleRate * preRoll.inMilliseconds / 1000).round() * 2;

  int get _maxCaptureBytes {
    final seconds =
        _vadConfig.maxSpeechDuration.inMilliseconds + preRoll.inMilliseconds;
    return (sampleRate * seconds / 1000).round() * 2 + sampleRate;
  }

  /// Starts the detector. The caller must already have an explicit opt-in and
  /// a prepared detector; failures are surfaced, never swallowed.
  @override
  Future<void> start() async {
    if (_disposed) {
      throw StateError('The wake command loop has been disposed.');
    }
    if (_state != _LoopState.idle) return;
    _stopRequested = false;
    _ring.clear();
    _ringBytes = 0;
    _detector.onAudio = _onAudio;
    _detectorEvents ??= _detector.events.listen(_onDetectorEvent);
    try {
      await _detector.start();
    } on Object {
      _state = _LoopState.idle;
      rethrow;
    }
    if (_stopRequested) {
      await _detector.stop();
      _emit(const WakeStopped());
      return;
    }
    _state = _LoopState.listening;
    _emit(const WakeListening());
  }

  /// Stops capture. Safe while idle, listening, capturing or finalising.
  @override
  Future<void> stop() async {
    if (_disposed) return;
    _stopRequested = true;
    _cancelTimers();
    _detector.onAudio = null;
    try {
      await _detector.stop();
    } on Object {
      // Releasing the microphone must not mask the caller's own error.
    }
    if (_state != _LoopState.idle) {
      _state = _LoopState.idle;
      _emit(const WakeStopped());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopRequested = true;
    _cancelTimers();
    _detector.onAudio = null;
    await _detectorEvents?.cancel();
    _detectorEvents = null;
    _ring.clear();
    _ringBytes = 0;
    _capture.clear();
    if (!_events.isClosed) await _events.close();
  }

  // ---------------------------------------------------------------------------
  // Capture
  // ---------------------------------------------------------------------------

  void _onAudio(Uint8List chunk) {
    if (_disposed || chunk.isEmpty) return;
    if (_state == _LoopState.listening) {
      _appendRing(chunk);
      return;
    }
    if (_state != _LoopState.capturing) return;
    _appendRing(chunk);
    _capture.add(chunk);
    _captureBytes += chunk.length;

    final events = _vad.add(chunk);
    for (final event in events) {
      switch (event.type) {
        case VoiceActivityEventType.speechStart:
          if (!_speechSeen) {
            _speechSeen = true;
            _speechStartTimer?.cancel();
            _speechStartTimer = null;
            _emit(const WakeCapturing());
          }
        case VoiceActivityEventType.speechEnd:
        case VoiceActivityEventType.maxSpeechReached:
          unawaited(_finish());
      }
    }
    if (_captureBytes >= _maxCaptureBytes) {
      unawaited(_finish());
    }
  }

  void _appendRing(Uint8List chunk) {
    _ring.add(chunk);
    _ringBytes += chunk.length;
    final limit = _preRollBytes;
    while (_ringBytes > limit && _ring.length > 1) {
      _ringBytes -= _ring.removeAt(0).length;
    }
  }

  void _onDetectorEvent(WakeWordEvent event) {
    if (_disposed) return;
    switch (event) {
      case WakeWordDetected():
        if (_state != _LoopState.listening) return;
        _beginCapture();
      case WakeWordFailed(:final message):
        _cancelTimers();
        _state = _LoopState.idle;
        _detector.onAudio = null;
        _emit(WakeFailed(message));
    }
  }

  void _beginCapture() {
    _state = _LoopState.capturing;
    _speechSeen = false;
    _capture.clear();
    _captureBytes = 0;
    for (final chunk in _ring) {
      _capture.add(chunk);
      _captureBytes += chunk.length;
    }
    _vad.reset();
    _emit(const WakeDetected());

    // No speech started shortly after the wake word: stop and go back.
    _speechStartTimer = Timer(commandTimeout, () {
      if (_disposed || _state != _LoopState.capturing) return;
      unawaited(_finish(
        emptyMessage: 'No command followed the wake word within '
            '${commandTimeout.inSeconds} seconds.',
      ));
    });
    // Absolute cap, even if the VAD never reports speech.
    _hardTimer = Timer(
      commandTimeout + _vadConfig.maxSpeechDuration,
      () {
        if (_disposed || _state != _LoopState.capturing) return;
        unawaited(_finish());
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Finalisation
  // ---------------------------------------------------------------------------

  Future<void> _finish({String? emptyMessage}) {
    final existing = _finishFuture;
    if (existing != null) return existing;
    final future = _finishOnce(emptyMessage: emptyMessage);
    _finishFuture = future;
    return future.whenComplete(() => _finishFuture = null);
  }

  Future<void> _finishOnce({String? emptyMessage}) async {
    if (_disposed) return;
    final wasCapturing = _state == _LoopState.capturing;
    final speechSeen = _speechSeen;
    _cancelTimers();
    _state = _LoopState.finalizing;
    final pcm = wasCapturing ? _capture.takeBytes() : Uint8List(0);
    _captureBytes = 0;
    _vad.reset();

    // Only one microphone consumer at a time: stop the detector before decode.
    _detector.onAudio = null;
    try {
      await _detector.stop();
    } on Object {
      // The decode below is still the honest next step; a stop error is
      // reported only if the decode also fails.
    }
    if (_disposed) return;

    // The capture buffer always contains the pre-roll (which includes the wake
    // phrase). If no speech was ever detected after the wake word, decoding it
    // would transcribe "Walsey" itself as if it were a command, so refuse.
    if (pcm.isEmpty || (emptyMessage != null && !speechSeen)) {
      _emit(WakeEmpty(emptyMessage ?? 'No audio was captured after the wake '
          'word.'));
      await _resumeIfAllowed();
      return;
    }

    try {
      final text = await _recognizer.recognize(pcm);
      if (_disposed) return;
      final trimmed = text?.trim() ?? '';
      if (trimmed.isEmpty) {
        _emit(WakeEmpty(emptyMessage ??
            'The command audio produced no transcript; nothing was executed.'));
      } else {
        _emit(WakeTranscript(trimmed));
      }
    } on Object catch (error) {
      _emit(WakeFailed('The command could not be transcribed: $error'));
      _state = _LoopState.idle;
      return;
    }
    await _resumeIfAllowed();
  }

  Future<void> _resumeIfAllowed() async {
    if (_disposed || _stopRequested || !autoResume) {
      _state = _LoopState.idle;
      return;
    }
    _ring.clear();
    _ringBytes = 0;
    try {
      _detector.onAudio = _onAudio;
      await _detector.start();
      if (_disposed || _stopRequested) {
        await _detector.stop();
        return;
      }
      _state = _LoopState.listening;
      _emit(const WakeListening());
    } on Object catch (error) {
      _state = _LoopState.idle;
      _emit(WakeFailed('Listening could not resume: $error'));
    }
  }

  void _cancelTimers() {
    _speechStartTimer?.cancel();
    _speechStartTimer = null;
    _hardTimer?.cancel();
    _hardTimer = null;
  }

  void _emit(WakeCommandEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

enum _LoopState { idle, listening, capturing, finalizing }
