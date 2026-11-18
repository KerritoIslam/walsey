import 'dart:async';
import 'dart:typed_data';

import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'audio/audio_capture.dart';
import 'audio/pcm16.dart';
import 'diagnostics/session_diagnostics.dart';
import 'engine/speech_engine.dart';
import 'model/model_catalog.dart';
import 'model/model_store.dart';

/// Everything [EngineSpeechRecognizer] needs to know about one concrete
/// engine: how to spawn it, which model belongs to a language and how its
/// failures read in the UI.
///
/// Keeping this as data (not subclass overrides) means the recognizer's
/// carefully pinned session logic — permission handling, session tokens,
/// tail-preserving stop, redaction-safe diagnostics — is written once and
/// every engine gets it unchanged.
final class SpeechEngineBinding {
  const SpeechEngineBinding({
    required this.name,
    required this.spawn,
    required this.platformSupported,
    required this.modelFor,
    required this.nativeLibraryHint,
    this.downloadableModels = const [],
  });

  /// Human-readable engine name used in user-facing failure messages.
  final String name;

  /// Creates the engine. Must throw when the native library is unavailable;
  /// the recognizer then reports `nativeLibraryUnavailable` with
  /// [nativeLibraryHint].
  final Future<SpeechEngine> Function() spawn;

  /// Whether this engine ships native code for the running OS.
  final bool Function() platformSupported;

  /// The downloadable model this engine uses for [language], or `null` when
  /// the engine cannot recognize that language at all.
  final SpeechModel? Function(SpeechLanguage language) modelFor;

  /// Platform-specific hint shown when [spawn] fails.
  final String nativeLibraryHint;

  /// Models the setup dialog should offer for this engine. The primary
  /// engine's model comes first; fallback-engine models may follow for
  /// comparison and rollback.
  final List<SpeechModel> downloadableModels;
}

/// [SpeechRecognizer] that captures 16 kHz mono PCM with `record` and feeds
/// it to a native engine through [SpeechEngine], as described by a
/// [SpeechEngineBinding].
///
/// One code path serves Android and Windows: the engine owns its native
/// library, the recorder only produces PCM. A session is started exclusively
/// by [start] (never on connect, never in a timer), the microphone is closed
/// in [stop], [cancel] and [dispose], and the model is loaded once and
/// reused.
///
/// This class never parses commands and never imports the LED packages.
class EngineSpeechRecognizer implements SpeechRecognizer {
  EngineSpeechRecognizer({
    required SpeechEngineBinding binding,
    ModelStore? modelStore,
    SpeechEngine? engine,
    AudioCapture? audioCapture,
    SpeechLanguage language = SpeechLanguage.defaultLanguage,
    SessionDiagnostics? diagnostics,
    List<String>? grammar,
    this.sampleRate = 16000,
    this.captureStopTimeout = const Duration(seconds: 3),
    bool? platformSupported,
  }) : _binding = binding,
       _modelStore = modelStore ?? ModelStore.platform(),
       _engine = engine,
       _audioCapture = audioCapture ?? RecordAudioCapture(),
       _diagnostics = diagnostics,
       _grammar = grammar,
       _platformSupported =
           platformSupported ?? binding.platformSupported(),
       _language = language;

  final SpeechEngineBinding _binding;
  final ModelStore _modelStore;
  final AudioCapture _audioCapture;
  final bool _platformSupported;
  final int sampleRate;

  /// How long [stop] waits for the platform recorder to finish shutting down.
  /// A recorder that never acknowledges the stop is reported as a visible
  /// failure instead of being silently treated as stopped.
  final Duration captureStopTimeout;

  /// The engine this recognizer drives, e.g. for UI labels.
  String get engineName => _binding.name;

  /// The downloadable model this engine uses for [language], or `null` when
  /// the engine cannot recognize that language at all.
  SpeechModel? modelFor(SpeechLanguage language) =>
      _binding.modelFor(language);

  /// Models the setup dialog should offer for this engine.
  List<SpeechModel> get downloadableModels => _binding.downloadableModels;

  /// Optional measurement instrument. `null` in production paths that do not
  /// need it; it never influences recognition.
  final SessionDiagnostics? _diagnostics;

  /// When set, the engine decodes only these phrases (engines with
  /// constrained grammars only; Whisper ignores it and decodes freely).
  final List<String>? _grammar;

  SpeechEngine? _engine;
  SpeechLanguage _language;

  final StreamController<SpeechRecognitionEvent> _events =
      StreamController<SpeechRecognitionEvent>.broadcast();
  StreamSubscription<SpeechEngineEvent>? _engineEvents;
  StreamSubscription<Uint8List>? _audioSubscription;

  /// Completes when the platform audio stream ends, so [stop] can wait for the
  /// platform's last queued chunk instead of dropping the final word.
  Completer<void>? _audioDone;

  Future<SpeechAvailability>? _pendingInitialization;
  String? _pendingInitializationLanguage;
  String? _loadedModelPath;

  bool _sessionActive = false;
  bool _cancelRequested = false;
  bool _disposed = false;

  /// Set by [stop] while the session is still shutting down. [start] re-checks
  /// it after every await, so a release that arrives while the recorder or the
  /// engine is still opening aborts the start instead of opening the
  /// microphone after the user let go.
  bool _stopRequested = false;

  /// True once `beginSession` returned for the current take. Needed because
  /// [stop] cannot call `finish` on an engine that never began a session.
  bool _engineSessionBegun = false;

  /// Set by [_stopAudio] when the recorder refused to stop (or timed out).
  /// [stop] turns it into a visible failure; it is never swallowed.
  Object? _captureStopFailure;

  /// Only true once a session actually touched the recorder plugin. Keeping it
  /// false lets unit/widget tests construct the recognizer (and dispose it)
  /// without a registered microphone plugin.
  bool _captureTouched = false;

  /// Set to true the moment the first audio chunk arrives. Ensures
  /// [SpeechSessionStarted] is emitted exactly once per session and not before
  /// the platform microphone is genuinely delivering samples.
  ///
  /// Background: on Windows the `record` plugin needs a few hundred
  /// milliseconds to open the WASAPI capture device. Emitting
  /// [SpeechSessionStarted] immediately after `startStream()` returns caused
  /// the UI to show "Listening…" while the microphone was still initialising,
  /// silently discarding anything said in that window. Emitting it on the
  /// first chunk makes the status honest.
  bool _sessionStartedEmitted = false;

  int _sessionToken = 0;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<SpeechAvailability> initialize({String? languageId}) {
    final language = _resolveLanguage(languageId);
    final pending = _pendingInitialization;
    if (pending != null && _pendingInitializationLanguage == language.id) {
      return pending;
    }
    final future = _initializeFor(language);
    _pendingInitialization = future;
    _pendingInitializationLanguage = language.id;
    return future.whenComplete(() {
      if (identical(_pendingInitialization, future)) {
        _pendingInitialization = null;
        _pendingInitializationLanguage = null;
      }
    });
  }

  Future<SpeechAvailability> _initializeFor(SpeechLanguage language) async {
    if (!_platformSupported) {
      return SpeechUnavailable(
        kind: SpeechFailureKind.unsupportedPlatform,
        message:
            '${_binding.name} is not wired for this operating system yet. '
            'Speech recognition currently supports Android and Windows; '
            'typed commands still work.',
      );
    }
    final model = _binding.modelFor(language);
    if (model == null) {
      return SpeechUnavailable(
        kind: SpeechFailureKind.unsupportedLanguage,
        message: '${language.label}: ${language.detail}',
      );
    }

    final String? path;
    try {
      path = await _modelStore.installedModelPath(model);
    } on Object catch (error) {
      return SpeechUnavailable(
        kind: SpeechFailureKind.initializationFailed,
        message: 'Could not inspect the model folder: $error',
      );
    }
    if (path == null) {
      return SpeechModelRequired(
        message:
            '${model.languageLabel} needs the ${model.id} model '
            '(about ${model.archiveSizeMegabytes} MB). Open the language '
            'model setup and download it once. Nothing is downloaded '
            'automatically.',
      );
    }

    final existingEngine = _engine;
    if (existingEngine != null && _loadedModelPath == path) {
      return const SpeechReady();
    }

    final SpeechEngine engine;
    if (existingEngine != null) {
      engine = existingEngine;
    } else {
      try {
        engine = await _binding.spawn();
      } on Object catch (error) {
        return SpeechUnavailable(
          kind: SpeechFailureKind.nativeLibraryUnavailable,
          message: '${_binding.nativeLibraryHint} Details: $error',
        );
      }
      _engine = engine;
    }
    _engineEvents ??= engine.events.listen(_onEngineEvent);

    try {
      await engine.loadModel(path);
    } on Object catch (error) {
      return SpeechUnavailable(
        kind: SpeechFailureKind.modelInvalid,
        message:
            '${_binding.name} rejected the ${model.id} model. Delete it in '
            'the model setup and install it again. Details: $error',
      );
    }
    _loadedModelPath = path;
    return const SpeechReady();
  }

  @override
  Future<void> start({String? languageId}) async {
    if (_disposed) {
      throw StateError('The recognizer has been disposed.');
    }
    if (_sessionActive) {
      throw StateError('A recognition session is already active.');
    }
    final language = _resolveLanguage(languageId);
    _language = language;
    final token = ++_sessionToken;
    _sessionActive = true;
    _cancelRequested = false;
    _stopRequested = false;
    _engineSessionBegun = false;
    _captureStopFailure = null;
    // Reset per session, not only when the stream is attached: a [stop] that
    // arrives while this start is still awaiting must not see the previous
    // take's "audio arrived" flag.
    _sessionStartedEmitted = false;

    final availability = await initialize(languageId: language.id);
    if (_abandoned(token)) {
      return;
    }
    switch (availability) {
      case SpeechReady():
        break;
      case SpeechModelRequired(:final message):
        await _failSession(token, SpeechFailureKind.modelNotInstalled, message);
        return;
      case SpeechUnavailable(:final kind, :final message):
        await _failSession(token, kind, message);
        return;
    }

    final bool granted;
    try {
      _captureTouched = true;
      granted = await _audioCapture.hasPermission();
    } on Object catch (error) {
      await _failSession(
        token,
        SpeechFailureKind.microphoneUnavailable,
        'Could not query microphone permission: $error',
      );
      return;
    }
    if (!granted) {
      await _failSession(
        token,
        SpeechFailureKind.permissionDenied,
        'Microphone permission was denied. Grant it in the system settings '
        'and try again. Typed commands keep working without it.',
      );
      return;
    }
    if (_abandoned(token)) {
      return;
    }

    final engine = _engine;
    if (engine == null) {
      await _failSession(
        token,
        SpeechFailureKind.initializationFailed,
        'The speech engine was not initialized.',
      );
      return;
    }
    try {
      await engine.beginSession(sampleRate: sampleRate, grammar: _grammar);
    } on Object catch (error) {
      await _failSession(
        token,
        SpeechFailureKind.recognitionFailed,
        '${_binding.name} could not start a recognizer: $error',
      );
      return;
    }
    _engineSessionBegun = true;
    if (_abandoned(token)) {
      await _resetEngineQuietly();
      return;
    }

    final Stream<Uint8List> audio;
    try {
      audio = await _audioCapture.startStream(sampleRate: sampleRate);
    } on Object catch (error) {
      unawaited(engine.reset());
      await _failSession(
        token,
        SpeechFailureKind.microphoneUnavailable,
        'Could not start recording: $error',
      );
      return;
    }
    if (_abandoned(token)) {
      // The user released while the recorder was opening. The recorder may
      // already be capturing, so close it here instead of leaving it running.
      await _stopAudio();
      _sessionActive = false;
      await _resetEngineQuietly();
      return;
    }

    _diagnostics?.beginSession(sampleRate: sampleRate);
    _sessionStartedEmitted = false;
    final pcmAssembler = Pcm16Assembler();
    final audioDone = Completer<void>();
    _audioDone = audioDone;
    _audioSubscription = audio.listen(
      (chunk) {
        if (_sessionActive && !_cancelRequested) {
          final pcm = pcmAssembler.add(chunk);
          if (pcm.isEmpty) {
            return;
          }
          _diagnostics?.addChunk(pcm);
          engine.accept(pcm);
          // Emit SpeechSessionStarted on the first chunk that actually
          // contains audio samples. This delays the "Listening…" status until
          // the microphone is genuinely delivering data, which on Windows
          // happens some hundreds of milliseconds after startStream()
          // returns.
          if (!_sessionStartedEmitted) {
            _sessionStartedEmitted = true;
            _emit(const SpeechSessionStarted());
          }
        }
      },
      onError: (Object error, StackTrace _) {
        if (!audioDone.isCompleted) {
          audioDone.complete();
        }
        if (!_sessionActive || token != _sessionToken) {
          return;
        }
        _sessionActive = false;
        unawaited(_stopAudio());
        _emit(
          SpeechSessionFailed(
            kind: SpeechFailureKind.recognitionFailed,
            message: 'The microphone stream failed: $error',
          ),
        );
      },
      onDone: () {
        try {
          pcmAssembler.finish();
        } on FormatException catch (error) {
          if (_sessionActive && token == _sessionToken) {
            _sessionActive = false;
            _emit(
              SpeechSessionFailed(
                kind: SpeechFailureKind.recognitionFailed,
                message: 'The microphone stream was truncated: $error',
              ),
            );
          }
        }
        if (!audioDone.isCompleted) {
          audioDone.complete();
        }
      },
    );
    // SpeechSessionStarted is now emitted on the first audio chunk (above).
    // If the stream ends immediately with no chunks (capture error that fires
    // onDone before onData), we never emit it, which is correct: the session
    // will fail via onError or produce SpeechNoSpeechDetected from finish().
  }

  @override
  Future<void> stop() async {
    if (!_sessionActive) {
      return;
    }
    final token = _sessionToken;
    // A release can arrive while `start()` is still opening the permission,
    // the engine or the recorder. Remember it and make the in-flight start
    // abort instead of opening the microphone after the user let go.
    _stopRequested = true;
    final hadAudio = _sessionStartedEmitted;
    final engineBegun = _engineSessionBegun;
    _diagnostics?.closeCapture();
    // Deliberately keep `_sessionActive` true while the recorder shuts down:
    // chunks the platform has already produced still reach the engine, so the
    // last word is not cut off by our own stop logic.
    await _stopAudio();
    _sessionActive = false;
    final captureFailure = _captureStopFailure;
    _captureStopFailure = null;
    final engine = _engine;
    if (engine == null) {
      if (!_disposed && token == _sessionToken) {
        _emit(const SpeechNoSpeechDetected());
      }
      return;
    }
    if (captureFailure != null) {
      // The recorder may still be capturing. Never report this as a clean take
      // and never hide the failure behind a transcript.
      await _resetEngineQuietly();
      if (!_disposed && token == _sessionToken) {
        _emit(
          SpeechSessionFailed(
            kind: SpeechFailureKind.microphoneUnavailable,
            message:
                'The microphone could not be stopped '
                '(${_describeCaptureFailure(captureFailure)}). No transcript '
                'was produced. Close the app or unplug the device if '
                'recording continues.',
          ),
        );
      }
      return;
    }
    if (!engineBegun || !hadAudio) {
      // The release arrived before any audio existed. Asking the engine to
      // finish an empty session can invent a transcript or throw, so report
      // the honest outcome: nothing was recorded.
      await _resetEngineQuietly();
      if (!_disposed && token == _sessionToken) {
        _emit(const SpeechNoSpeechDetected());
      }
      return;
    }
    try {
      final text = await engine.finish();
      if (_disposed || token != _sessionToken || _cancelRequested) {
        return;
      }
      _diagnostics?.complete(transcript: text);
      _emit(
        text == null
            ? const SpeechNoSpeechDetected()
            : SpeechFinalTranscript(text),
      );
    } on Object catch (error) {
      _diagnostics?.complete(transcript: null);
      if (!_disposed && token == _sessionToken && !_cancelRequested) {
        _emit(
          SpeechSessionFailed(
            kind: SpeechFailureKind.recognitionFailed,
            message: '${_binding.name} could not finish the session: $error',
          ),
        );
      }
    }
  }

  @override
  Future<void> cancel() async {
    final hadSession = _sessionActive;
    _sessionToken++;
    _sessionActive = false;
    _cancelRequested = true;
    await _stopAudio();
    _diagnostics?.cancel();
    final engine = _engine;
    if (engine != null) {
      try {
        await engine.reset();
      } on Object {
        // Cancelling must not throw; the recognizer may already be gone.
      }
    }
    if (hadSession) {
      _emit(const SpeechSessionCancelled());
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _sessionToken++;
    _sessionActive = false;
    _cancelRequested = true;
    await _stopAudio();
    await _engineEvents?.cancel();
    _engineEvents = null;
    if (_captureTouched) {
      try {
        await _audioCapture.dispose();
      } on Object {
        // The plugin may already be detached during app shutdown.
      }
    }
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      try {
        await engine.dispose();
      } on Object {
        // Releasing native memory is best-effort; never block disposal.
      }
    }
    _loadedModelPath = null;
    await _events.close();
  }

  void _onEngineEvent(SpeechEngineEvent event) {
    if (_disposed || !_sessionActive || _cancelRequested) {
      return;
    }
    switch (event) {
      case SpeechEnginePartial(:final text):
        _diagnostics?.notePartial();
        _emit(SpeechPartialTranscript(text));
      case SpeechEngineSegment():
        // Vosk repeats every segment in its final result and Whisper decodes
        // once at finish, so the UI only needs that.
        break;
      case SpeechEngineError(:final message):
        _sessionActive = false;
        unawaited(_stopAudio());
        _emit(
          SpeechSessionFailed(
            kind: SpeechFailureKind.recognitionFailed,
            message: message,
          ),
        );
    }
  }

  Future<void> _failSession(
    int token,
    SpeechFailureKind kind,
    String message,
  ) async {
    if (_disposed || token != _sessionToken) {
      return;
    }
    _sessionActive = false;
    _diagnostics?.closeCapture();
    await _stopAudio();
    _emit(SpeechSessionFailed(kind: kind, message: message));
  }

  Future<void> _stopAudio() async {
    final subscription = _audioSubscription;
    final done = _audioDone;
    _audioSubscription = null;
    _audioDone = null;

    // Stop the recorder first, then detach. Cancelling the subscription before
    // the platform stops can discard a chunk that was already captured.
    if (_captureTouched) {
      try {
        await _audioCapture.stop().timeout(captureStopTimeout);
      } on TimeoutException {
        _captureStopFailure = TimeoutException(
          'the recorder did not acknowledge the stop within '
          '${captureStopTimeout.inMilliseconds} ms',
        );
      } on Object catch (error) {
        // Keep this for [stop] to surface: swallowing it could report a
        // still-recording microphone as a clean take.
        _captureStopFailure = error;
      }
    }
    if (subscription == null) {
      return;
    }
    // `record` closes the stream after its last buffer; a bounded wait keeps a
    // misbehaving plugin from hanging the session.
    await done?.future.timeout(
      const Duration(milliseconds: 250),
      onTimeout: () {},
    );
    await subscription.cancel();
  }

  bool _abandoned(int token) =>
      _disposed || token != _sessionToken || _stopRequested;

  Future<void> _resetEngineQuietly() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.reset();
    } on Object {
      // The engine may already be gone; cleanup must not throw.
    }
  }

  static String _describeCaptureFailure(Object error) => switch (error) {
        TimeoutException(:final message) when message != null => message,
        TimeoutException(:final message) => message ?? 'timed out',
        _ => '$error',
      };

  void _emit(SpeechRecognitionEvent event) {
    if (_events.isClosed) {
      return;
    }
    _events.add(event);
  }

  SpeechLanguage _resolveLanguage(String? languageId) {
    if (languageId == null || languageId == _language.id) {
      return _language;
    }
    return SpeechLanguage.byId(languageId) ?? SpeechLanguage.defaultLanguage;
  }
}
