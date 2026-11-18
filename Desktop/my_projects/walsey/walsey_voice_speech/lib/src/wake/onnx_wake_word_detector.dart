import 'dart:async';
import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:walsey_voice_core/walsey_voice_core.dart';

import '../audio/audio_capture_port.dart';
import 'wake_word_start_exception.dart';

/// One frame-scoring backend for [OnnxWakeWordDetector].
///
/// The detector owns capture, framing, thresholds and state; a backend only
/// turns one fixed-size PCM frame into a confidence. That seam is what lets the
/// framing/threshold logic be tested without onnxruntime, and what would let a
/// different lightweight model (not only ONNX) be dropped in.
///
/// A real openWakeWord backend loads its melspectrogram, embedding and wake
/// models and keeps the streaming state between [score] calls. None ships with
/// this repository: a custom "Walsey" model has to be trained first (see
/// `docs/wake_word.md`), so the production detector reports
/// [WakeWordCapability.notConfigured] until one is installed.
abstract interface class WakeWordScorer {
  /// Stable backend name for diagnostics.
  String get name;

  /// Samples per frame. openWakeWord uses 1280 samples (80 ms at 16 kHz).
  int get frameSamples;

  /// Loads the model files from [modelPath]. Called once per start.
  Future<void> load(String modelPath);

  /// Confidence in `0..1` for one frame of 16-bit mono PCM at 16 kHz.
  Future<double> score(Int16List frame);

  /// Clears streaming state between utterances.
  Future<void> reset();

  Future<void> dispose();
}

/// Streaming wake detector for a frame-scoring ONNX-style model.
///
/// This is the second wake approach the project benchmarked. Unlike the Vosk
/// phonetic proxy it does not ask a general recognizer to spell an invented
/// word: the model is trained on the phrase itself, which is the only approach
/// likely to reach a usable false-activation rate.
///
/// Honest status: the detector is implemented and tested against a fake
/// scorer, but **no "Walsey" model is trained or bundled**, so it cannot be
/// enabled in the app yet. That is reported through [prepare], never hidden
/// behind a fake button.
final class OnnxWakeWordDetector implements WakeWordDetector {
  OnnxWakeWordDetector({
    required WakeWordScorer scorer,
    required AudioCapture capture,
    required this.modelPath,
    this.threshold = 0.5,
    this.requiredConsecutiveFrames = 1,
    this.duplicateWindow = const Duration(seconds: 2),
    this.sampleRate = 16000,
    bool? platformSupported,
    bool Function()? modelPresent,
  })  : _scorer = scorer,
        _capture = capture,
        _platformSupported = platformSupported,
        _modelPresent = modelPresent;

  final WakeWordScorer _scorer;
  final AudioCapture _capture;

  /// Directory or file the backend loads. Only its presence is checked by
  /// [prepare]; the contents are the backend's responsibility.
  final String modelPath;

  /// Score at or above which a frame counts as a hit.
  final double threshold;

  /// Consecutive hits required before emitting. >1 reduces sporadic false
  /// positives at the cost of ~frameSamples × (n-1) detection latency.
  final int requiredConsecutiveFrames;

  /// Minimum gap between emitted detections.
  final Duration duplicateWindow;

  final int sampleRate;
  final bool? _platformSupported;
  final bool Function()? _modelPresent;

  final StreamController<WakeWordEvent> _events =
      StreamController<WakeWordEvent>.broadcast();
  StreamSubscription<Uint8List>? _audioSubscription;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  Future<void> _queue = Future<void>.value();

  bool _running = false;
  bool _disposed = false;
  bool _modelLoaded = false;
  int _consecutive = 0;
  DateTime? _lastDetection;

  /// Optional diagnostic tap (score per frame). Never used to fake a detection.
  void Function(double score)? onScore;

  /// Optional raw-audio tap: every captured chunk, in order, including the
  /// chunk in which a detection fires.
  ///
  /// The wake-command handover uses it to keep a pre-roll ring buffer, so the
  /// first words spoken immediately after "Walsey" are not lost while the
  /// session changes. It observes audio only; it can never trigger a detection.
  void Function(Uint8List chunk)? onAudio;

  @override
  String get engineName => 'onnx-${_scorer.name}';

  @override
  Stream<WakeWordEvent> get events => _events.stream;

  bool get isRunning => _running;

  int get _frameBytes => _scorer.frameSamples * 2;

  @override
  Future<WakeWordAvailability> prepare() async {
    if (_disposed) {
      return const WakeWordAvailability(
        capability: WakeWordCapability.notConfigured,
        message: 'The wake detector was disposed.',
      );
    }
    if (!(_platformSupported ?? true)) {
      return const WakeWordAvailability(
        capability: WakeWordCapability.unsupportedPlatform,
        message: 'Wake-word listening is not available on this platform.',
      );
    }
    bool permission;
    try {
      permission = await _capture.hasPermission();
    } on Object {
      permission = false;
    }
    if (!permission) {
      return const WakeWordAvailability(
        capability: WakeWordCapability.permissionDenied,
        message: 'Microphone permission is required to listen for "Walsey".',
      );
    }
    final present = _modelPresent?.call() ?? _pathExists();
    if (!present) {
      return WakeWordAvailability(
        capability: WakeWordCapability.notConfigured,
        message: 'No wake-word model is installed. A "Walsey" model must be '
            'trained and installed explicitly; nothing is listening. '
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
    if (!_modelLoaded) {
      await _scorer.load(modelPath);
      _modelLoaded = true;
    }
    await _scorer.reset();
    _consecutive = 0;
    _pending.clear();
    final stream = await _capture.startStream(sampleRate: sampleRate);
    _running = true;
    _audioSubscription = stream.listen(
      _onAudio,
      onError: (Object error) => _fail('microphone capture failed: $error'),
      onDone: () {
        if (_running) _fail('microphone capture stopped unexpectedly.');
      },
    );
  }

  @override
  Future<void> stop() async {
    await _teardown(keepScorer: true);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _teardown(keepScorer: false);
    await _capture.dispose();
    if (!_events.isClosed) await _events.close();
  }

  void _onAudio(Uint8List chunk) {
    if (!_running || _events.isClosed) return;
    onAudio?.call(chunk);
    _pending.add(chunk);
    // Score frames one at a time; a slow backend must not be re-entered.
    _queue = _queue.then((_) => _drainFrames()).catchError((Object error) {
      _fail('wake-word scoring failed: $error');
    });
  }

  Future<void> _drainFrames() async {
    while (_running && _pending.length >= _frameBytes) {
      final bytes = _pending.takeBytes();
      if (bytes.length < _frameBytes) {
        _pending.add(bytes);
        return;
      }
      var offset = 0;
      while (_running && bytes.length - offset >= _frameBytes) {
        final frameBytes = Uint8List.sublistView(
          bytes,
          offset,
          offset + _frameBytes,
        );
        offset += _frameBytes;
        final frame = Int16List.view(
          frameBytes.buffer,
          frameBytes.offsetInBytes,
          frameBytes.length ~/ 2,
        );
        final score = await _scorer.score(frame);
        onScore?.call(score);
        if (!_running) return;
        if (score >= threshold) {
          _consecutive++;
          if (_consecutive >= requiredConsecutiveFrames) {
            _consecutive = 0;
            _emitDetection();
          }
        } else {
          _consecutive = 0;
        }
      }
      if (bytes.length - offset > 0) {
        _pending.add(Uint8List.sublistView(bytes, offset));
      }
    }
  }

  void _emitDetection() {
    final now = DateTime.now();
    final last = _lastDetection;
    if (last != null && now.difference(last) < duplicateWindow) return;
    _lastDetection = now;
    _events.add(const WakeWordDetected(phrase: 'walsey'));
    unawaited(_scorer.reset());
  }

  Future<void> _teardown({required bool keepScorer}) async {
    _running = false;
    final audio = _audioSubscription;
    _audioSubscription = null;
    await audio?.cancel();
    try {
      await _capture.stop();
    } on Object {
      // Releasing a closed microphone must not mask the original failure.
    }
    _pending.clear();
    _consecutive = 0;
    try {
      if (keepScorer) {
        await _scorer.reset();
      } else {
        await _scorer.dispose();
      }
    } on Object {
      // Best effort on shutdown.
    }
  }

  void _fail(String message) {
    if (_events.isClosed) return;
    _events.add(WakeWordFailed(message: message));
    unawaited(_teardown(keepScorer: true));
  }

  bool _pathExists() {
    try {
      return File(modelPath).existsSync() || Directory(modelPath).existsSync();
    } on Object {
      return false;
    }
  }
}
