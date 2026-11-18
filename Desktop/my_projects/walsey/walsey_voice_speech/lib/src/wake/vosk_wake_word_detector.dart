import 'dart:async';
import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:walsey_voice_core/walsey_voice_core.dart';

import '../audio/audio_capture_port.dart';
import '../engine/speech_engine.dart';
import '../vosk/vosk_speech_engine.dart';
import 'phonetic_wake_matcher.dart';
import 'wake_word_start_exception.dart';

/// Streaming wake-phrase detector built on the existing Vosk engine.
///
/// This is **not** a keyword-spotting model. The pinned `libvosk` builds do
/// not export `vosk_recognizer_set_key_phrases`, so the detector runs Vosk's
/// normal unconstrained decoder over a rolling audio stream and applies
/// [PhoneticWakeMatcher] to the *partial* transcripts. That trade-off is
/// deliberate and measured by `bin/wake_accuracy.dart`:
///
/// * no new native dependency, no new model download (reuses the Vosk fallback
///   model), works on Windows and Android;
/// * false activations are decided by the matcher plus a leading-word rule, not
///   assumed — see the benchmark output before enabling it;
/// * it costs more CPU than a dedicated KWS model because Vosk keeps decoding
///   the whole stream.
///
/// Safety properties:
///
/// * nothing listens until [start] is called;
/// * a detection emits [WakeWordDetected] and never a command or an execution;
/// * the recognizer is reset immediately after a detection, so the following
///   command is captured by the normal single-session recognizer;
/// * the same phrase within [duplicateWindow] is emitted once.
final class VoskWakeWordDetector implements WakeWordDetector {
  VoskWakeWordDetector({
    required SpeechEngine engine,
    required AudioCapture capture,
    required this.modelPath,
    PhoneticWakeMatcher matcher = const PhoneticWakeMatcher(),
    this.sampleRate = 16000,
    this.requireLeadingPhrase = true,
    this.duplicateWindow = const Duration(seconds: 2),
    bool? platformSupported,
    bool Function()? modelPresent,
    this.onTranscript,
  })  : _engine = engine,
        _capture = capture,
        _matcher = matcher,
        _platformSupported = platformSupported,
        _modelPresent = modelPresent;

  final SpeechEngine _engine;
  final AudioCapture _capture;
  final PhoneticWakeMatcher _matcher;

  /// Directory of the Vosk model used for the streaming decode. The same model
  /// the fallback recognizer uses; installing it is an explicit user action.
  final String modelPath;

  final int sampleRate;

  /// When true (default), the phrase must be the first recognised word of the
  /// hypothesis (an optional "hey/ok/okay" is allowed). This keeps "I told him
  /// about Walsey" from waking the assistant.
  final bool requireLeadingPhrase;

  /// Minimum gap between two emitted detections of the same phrase.
  final Duration duplicateWindow;

  /// Optional diagnostic tap: receives the raw partial/segment text exactly as
  /// the engine produced it. Used by the accuracy harness; never used to
  /// rewrite a transcript.
  final void Function(String text)? onTranscript;

  /// `null` means "ask [VoskWakeWordDetector.isSupportedPlatform]".
  final bool? _platformSupported;
  final bool Function()? _modelPresent;

  final StreamController<WakeWordEvent> _events =
      StreamController<WakeWordEvent>.broadcast();
  StreamSubscription<SpeechEngineEvent>? _engineSubscription;
  StreamSubscription<Uint8List>? _audioSubscription;

  bool _running = false;
  bool _disposed = false;
  bool _modelLoaded = false;
  DateTime? _lastDetection;

  /// Whether the bundled native Vosk library exists for this OS.
  static bool get isSupportedPlatform => VoskSpeechEngine.isSupportedPlatform;

  @override
  String get engineName => 'vosk-phonetic';

  @override
  Stream<WakeWordEvent> get events => _events.stream;

  bool get isRunning => _running;

  @override
  Future<WakeWordAvailability> prepare() async {
    if (_disposed) {
      return const WakeWordAvailability(
        capability: WakeWordCapability.notConfigured,
        message: 'The wake detector was disposed.',
      );
    }
    final supported = _platformSupported ?? isSupportedPlatform;
    if (!supported) {
      return const WakeWordAvailability(
        capability: WakeWordCapability.unsupportedPlatform,
        message: 'Wake-word listening is not available on this platform.',
      );
    }
    bool hasPermission;
    try {
      hasPermission = await _capture.hasPermission();
    } on Object {
      hasPermission = false;
    }
    if (!hasPermission) {
      return const WakeWordAvailability(
        capability: WakeWordCapability.permissionDenied,
        message: 'Microphone permission is required to listen for "Walsey".',
      );
    }
    final present = _modelPresent?.call() ?? _modelDirectoryExists();
    if (!present) {
      return WakeWordAvailability(
        capability: WakeWordCapability.notConfigured,
        message: 'Install the offline speech model to listen for "Walsey". '
            'Checked: $modelPath',
      );
    }
    return const WakeWordAvailability(
      capability: WakeWordCapability.available,
      message: 'Ready. Nothing is listening until you start it.',
    );
  }

  @override
  Future<void> start() async {
    if (_disposed) {
      throw const WakeWordStartException('the detector was disposed');
    }
    if (_running) return;
    final availability = await prepare();
    if (!availability.isReady) {
      throw WakeWordStartException(availability.message);
    }

    // Subscribe before the microphone opens so the first chunks cannot be
    // decoded without a listener.
    _engineSubscription = _engine.events.listen(
      _onEngineEvent,
      onError: (Object error) => _fail('the speech engine failed: $error'),
    );

    try {
      if (!_modelLoaded) {
        await _engine.loadModel(modelPath);
        _modelLoaded = true;
      }
      await _engine.beginSession(sampleRate: sampleRate);
      final stream = await _capture.startStream(sampleRate: sampleRate);
      _running = true;
      _audioSubscription = stream.listen(
        _engine.accept,
        onError: (Object error) => _fail('microphone capture failed: $error'),
        onDone: () {
          if (_running) {
            _fail('microphone capture stopped unexpectedly.');
          }
        },
      );
    } on Object catch (error) {
      await _teardown(keepEngine: true);
      throw WakeWordStartException('could not start listening: $error');
    }
  }

  @override
  Future<void> stop() async {
    if (!_running) {
      // Still release a capture that was opened before a failure.
      await _teardown(keepEngine: true);
      return;
    }
    await _teardown(keepEngine: true);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _teardown(keepEngine: false);
    await _capture.dispose();
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  Future<void> _teardown({required bool keepEngine}) async {
    _running = false;
    final audio = _audioSubscription;
    _audioSubscription = null;
    await audio?.cancel();
    try {
      await _capture.stop();
    } on Object {
      // Releasing an already-closed microphone must not mask the real error.
    }
    final engineEvents = _engineSubscription;
    _engineSubscription = null;
    await engineEvents?.cancel();
    try {
      if (keepEngine) {
        await _engine.reset();
      } else {
        await _engine.dispose();
      }
    } on Object {
      // Shutdown is best-effort; the caller already decided to stop.
    }
  }

  void _onEngineEvent(SpeechEngineEvent event) {
    if (!_running || _events.isClosed) return;
    if (event is SpeechEngineError) {
      _fail(event.message);
      return;
    }
    final text = switch (event) {
      SpeechEnginePartial(:final text) => text,
      SpeechEngineSegment(:final text) => text,
      _ => null,
    };
    if (text == null || text.isEmpty) return;
    onTranscript?.call(text);

    final words = PhoneticWakeMatcher.splitWords(text);
    final match = _matcher.findInWords(words);
    if (match == null) return;
    if (requireLeadingPhrase && match.startWord != 0) return;

    final now = DateTime.now();
    final last = _lastDetection;
    if (last != null && now.difference(last) < duplicateWindow) return;
    _lastDetection = now;

    _events.add(WakeWordDetected(phrase: match.matchedText));
    // Clear the decoder so the command spoken after the trigger is not glued
    // to the wake phrase. The normal recognizer opens its own session.
    unawaited(_restartRecognition());
  }

  Future<void> _restartRecognition() async {
    if (!_running) return;
    try {
      await _engine.reset();
      if (_running) {
        await _engine.beginSession(sampleRate: sampleRate);
      }
    } on Object catch (error) {
      _fail('could not continue listening after a detection: $error');
    }
  }

  void _fail(String message) {
    if (_events.isClosed) return;
    _events.add(WakeWordFailed(message: message));
    unawaited(_teardown(keepEngine: true));
  }

  bool _modelDirectoryExists() {
    try {
      return Directory(modelPath).existsSync();
    } on Object {
      return false;
    }
  }
}
