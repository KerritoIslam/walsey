import 'dart:async';
import 'dart:typed_data';

import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'audio/audio_capture.dart';
import 'diagnostics/session_diagnostics.dart';
import 'model/model_catalog.dart';
import 'model/model_store.dart';
import 'vosk/speech_engine.dart';
import 'vosk/vosk_speech_engine.dart';

/// [SpeechRecognizer] that captures 16 kHz mono PCM with `record` and feeds it
/// to Vosk through [SpeechEngine].
///
/// One code path serves Android and Windows: the engine owns its native
/// library, the recorder only produces PCM. A session is started exclusively by
/// [start] (never on connect, never in a timer), the microphone is closed in
/// [stop], [cancel] and [dispose], and the model is loaded once and reused.
///
/// This class never parses commands and never imports the LED packages.
class VoskSpeechRecognizer implements SpeechRecognizer {
  VoskSpeechRecognizer({
    ModelStore? modelStore,
    SpeechEngine? engine,
    AudioCapture? audioCapture,
    SpeechLanguage language = SpeechLanguage.defaultLanguage,
    SessionDiagnostics? diagnostics,
    List<String>? grammar,
    this.sampleRate = 16000,
    bool? platformSupported,
  }) : _modelStore = modelStore ?? ModelStore.platform(),
       _engine = engine,
       _audioCapture = audioCapture ?? RecordAudioCapture(),
       _diagnostics = diagnostics,
       _grammar = grammar,
       _platformSupported =
           platformSupported ?? VoskSpeechEngine.isSupportedPlatform,
       _language = language;

  /// Convenience constructor for the app.
  factory VoskSpeechRecognizer.platform({SessionDiagnostics? diagnostics}) =>
      VoskSpeechRecognizer(diagnostics: diagnostics);

  final ModelStore _modelStore;
  final AudioCapture _audioCapture;
  final bool _platformSupported;
  final int sampleRate;

  /// Optional measurement instrument. `null` in production paths that do not
  /// need it; it never influences recognition.
  final SessionDiagnostics? _diagnostics;

  /// When set, the engine decodes only these phrases (Vosk constrained grammar).
  ///
  /// Only safe for models with a dynamic graph; the caller must check
  /// `VoskModelInfo.supportsGrammar` first.
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

  /// Only true once a session actually touched the recorder plugin. Keeping it
  /// false lets unit/widget tests construct the recognizer (and dispose it)
  /// without a registered microphone plugin.
  bool _captureTouched = false;

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
            'Vosk is not wired for this operating system yet. Speech '
            'recognition currently supports Android and Windows; typed '
            'commands still work.',
      );
    }
    final model = language.model;
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
        engine = await VoskSpeechEngine.spawn();
      } on Object catch (error) {
        return SpeechUnavailable(
          kind: SpeechFailureKind.nativeLibraryUnavailable,
          message:
              'The native Vosk library could not be loaded. Android builds '
              'ship it in the APK; Windows needs libvosk.dll next to the '
              'executable (see tools/fetch_vosk_windows.ps1). Details: $error',
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
            'Vosk rejected the ${model.id} model. Delete it in the model '
            'setup and install it again. Details: $error',
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

    final availability = await initialize(languageId: language.id);
    if (_disposed || token != _sessionToken) {
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
    if (token != _sessionToken) {
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
        'Vosk could not start a recognizer: $error',
      );
      return;
    }
    if (_disposed || token != _sessionToken) {
      unawaited(engine.reset());
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
    if (_disposed || token != _sessionToken) {
      await _stopAudio();
      unawaited(engine.reset());
      return;
    }

    _diagnostics?.beginSession(sampleRate: sampleRate);
    final audioDone = Completer<void>();
    _audioDone = audioDone;
    _audioSubscription = audio.listen(
      (chunk) {
        if (_sessionActive && !_cancelRequested) {
          // Measure the bytes exactly as the engine receives them.
          _diagnostics?.addChunk(chunk);
          engine.accept(chunk);
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
        if (!audioDone.isCompleted) {
          audioDone.complete();
        }
      },
    );
    _emit(const SpeechSessionStarted());
  }

  @override
  Future<void> stop() async {
    if (!_sessionActive) {
      return;
    }
    final token = _sessionToken;
    // Deliberately keep `_sessionActive` true while the recorder shuts down:
    // chunks the platform has already produced still reach Vosk, so the last
    // word is not cut off by our own stop logic.
    await _stopAudio();
    _sessionActive = false;
    _diagnostics?.closeCapture();
    final engine = _engine;
    if (engine == null) {
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
            message: 'Vosk could not finish the session: $error',
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
        // The final result repeats every segment, so the UI only needs that.
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
        await _audioCapture.stop();
      } on Object {
        // Stopping an already-stopped recorder is not an error worth showing.
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
