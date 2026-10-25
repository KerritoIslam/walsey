import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'model/model_catalog.dart';

/// Where the current interpretation came from.
enum InterpretationSource {
  typed,
  speech;

  String get label => switch (this) {
    InterpretationSource.typed => 'Typed command',
    InterpretationSource.speech => 'Recognized speech',
  };
}

/// Push-to-talk states shown by the UI.
///
/// Recognition outcomes and parsing outcomes are deliberately separate: a
/// session can end `empty`, `cancelled` or `error` without ever reaching the
/// parser, and a parsed sentence can fail validation while the session itself
/// succeeded.
enum PushToTalkStatus {
  idle,
  initializing,
  listening,
  recognizing,
  result,
  empty,
  cancelled,
  error;

  String get label => switch (this) {
    PushToTalkStatus.idle => 'Ready',
    PushToTalkStatus.initializing => 'Initializing…',
    PushToTalkStatus.listening => 'Listening…',
    PushToTalkStatus.recognizing => 'Recognizing…',
    PushToTalkStatus.result => 'Recognized',
    PushToTalkStatus.empty => 'No speech detected',
    PushToTalkStatus.cancelled => 'Cancelled',
    PushToTalkStatus.error => 'Error',
  };

  bool get isActive =>
      this == PushToTalkStatus.initializing ||
      this == PushToTalkStatus.listening ||
      this == PushToTalkStatus.recognizing;
}

/// Orchestrates one push-to-talk session at a time and routes the recognized
/// text through the existing Stage 1 parser.
///
/// Responsibilities are intentionally narrow: this class owns session state,
/// partial/final text, parser invocation and retry/cancel. It does not record
/// audio, does not load models, does not touch BLE and has no execution path.
///
/// Typed input goes through [analyzeTyped], which calls the same
/// [VoiceCommandParser] instance as speech, so both entry points share
/// normalization, validation and failure reporting.
class PushToTalkController extends ChangeNotifier {
  PushToTalkController({
    required SpeechRecognizer recognizer,
    VoiceCommandParser? parser,
    SpeechLanguage language = SpeechLanguage.defaultLanguage,
    this.recognitionTimeout = const Duration(seconds: 10),
  }) : _recognizer = recognizer,
       _parser = parser ?? VoiceCommandParser(),
       _language = language {
    _eventSubscription = _recognizer.events.listen(_onRecognitionEvent);
  }

  final SpeechRecognizer _recognizer;
  final VoiceCommandParser _parser;

  /// How long [PushToTalkStatus.recognizing] may last before the session is
  /// declared failed. Prevents a dead engine from leaving the UI stuck.
  final Duration recognitionTimeout;

  StreamSubscription<SpeechRecognitionEvent>? _eventSubscription;
  Timer? _timeoutTimer;

  PushToTalkStatus _status = PushToTalkStatus.idle;
  SpeechLanguage _language;
  String? _partialText;
  String? _finalText;
  VoiceResult? _interpretation;
  InterpretationSource? _interpretationSource;
  SpeechFailureKind? _failureKind;
  String? _errorMessage;
  String? _notice;
  bool _disposed = false;
  int _sessionGeneration = 0;

  /// Current session state.
  PushToTalkStatus get status => _status;

  /// Language selected in the UI.
  SpeechLanguage get language => _language;

  /// Latest unstable transcript of the running session.
  String? get partialText => _partialText;

  /// Final transcript of the last speech session. `null` for typed input and
  /// after clear/cancel, so an old transcript can never be mistaken for a new
  /// session's output.
  String? get finalText => _finalText;

  /// Parser output for the most recent input, speech or typed.
  VoiceResult? get interpretation => _interpretation;

  /// Which input produced [interpretation].
  InterpretationSource? get interpretationSource => _interpretationSource;

  /// Engine failure category, when [status] is [PushToTalkStatus.error].
  SpeechFailureKind? get failureKind => _failureKind;

  /// Plain-language failure text.
  String? get errorMessage => _errorMessage;

  /// Non-fatal information (for example "no model installed").
  String? get notice => _notice;

  /// Whether the mic button should start a session.
  bool get canStart => !_status.isActive && _language.isSupported;

  /// Whether a running session can be cancelled.
  bool get canCancel =>
      _status == PushToTalkStatus.listening ||
      _status == PushToTalkStatus.recognizing ||
      _status == PushToTalkStatus.initializing;

  /// Whether a previous attempt can be retried.
  bool get canRetry =>
      _language.isSupported &&
      (_status == PushToTalkStatus.error ||
          _status == PushToTalkStatus.empty ||
          _status == PushToTalkStatus.cancelled);

  /// Starts a session, or stops the running one. Returns immediately after the
  /// state change; results arrive through notifications/events.
  Future<void> toggle() async {
    if (_status.isActive) {
      if (_status == PushToTalkStatus.listening) {
        await stopListening();
      }
      return;
    }
    await startListening();
  }

  /// Starts a new session. Ignored while another session is active, which makes
  /// accidental double taps and double sessions harmless.
  Future<void> startListening() async {
    if (_disposed || _status.isActive) {
      return;
    }
    final generation = ++_sessionGeneration;
    _clearSessionData();
    _status = PushToTalkStatus.initializing;
    _notice = null;
    notifyListeners();

    final SpeechAvailability availability;
    try {
      availability = await _recognizer.initialize(languageId: _language.id);
    } on Object catch (error) {
      _fail(
        generation,
        SpeechFailureKind.initializationFailed,
        'Could not initialize speech recognition: $error',
      );
      return;
    }
    if (!_isCurrent(generation)) {
      return;
    }
    switch (availability) {
      case SpeechReady():
        break;
      case SpeechModelRequired(:final message):
        _fail(generation, SpeechFailureKind.modelNotInstalled, message);
        return;
      case SpeechUnavailable(:final kind, :final message):
        _fail(generation, kind, message);
        return;
    }
    try {
      await _recognizer.start(languageId: _language.id);
    } on StateError catch (error) {
      _fail(generation, SpeechFailureKind.alreadyRunning, error.message);
      return;
    } on Object catch (error) {
      _fail(
        generation,
        SpeechFailureKind.recognitionFailed,
        'Could not start the speech session: $error',
      );
      return;
    }
    if (!_isCurrent(generation)) {
      return;
    }
    // The recognizer emits SpeechSessionStarted; this fallback only covers an
    // adapter that returns without emitting it.
    if (_status == PushToTalkStatus.initializing) {
      _status = PushToTalkStatus.listening;
      notifyListeners();
    }
  }

  /// Ends the running session and waits for the final transcript event.
  Future<void> stopListening() async {
    if (_disposed || _status != PushToTalkStatus.listening) {
      return;
    }
    final generation = _sessionGeneration;
    _status = PushToTalkStatus.recognizing;
    notifyListeners();
    _armTimeout(generation);
    try {
      await _recognizer.stop();
    } on Object catch (error) {
      _fail(
        generation,
        SpeechFailureKind.recognitionFailed,
        'Could not stop the speech session: $error',
      );
    }
  }

  /// Discards the running session. No transcript is published.
  Future<void> cancel() async {
    if (_disposed || !canCancel) {
      return;
    }
    _sessionGeneration++;
    _timeoutTimer?.cancel();
    _status = PushToTalkStatus.cancelled;
    _partialText = null;
    _finalText = null;
    _failureKind = null;
    _errorMessage = null;
    notifyListeners();
    try {
      await _recognizer.cancel();
    } on Object {
      // The state is already "cancelled"; a cleanup error is not user-facing.
    }
  }

  /// Starts a new session after an error, empty result or cancellation.
  Future<void> retry() async {
    if (!canRetry) {
      return;
    }
    await startListening();
  }

  /// Parses typed text with the same parser used for speech.
  ///
  /// Returns `false` when a speech session is active, so typed analysis can
  /// never race with a live recognition result.
  bool analyzeTyped(String text) {
    if (_status.isActive) {
      return false;
    }
    _clearSessionData(keepStatus: true);
    _status = PushToTalkStatus.idle;
    _interpretation = _parser.parse(text);
    _interpretationSource = InterpretationSource.typed;
    notifyListeners();
    return true;
  }

  /// Clears the transcript, the interpretation and any error.
  void clear() {
    if (_status.isActive) {
      return;
    }
    _sessionGeneration++;
    _clearSessionData(keepStatus: true);
    _status = PushToTalkStatus.idle;
    notifyListeners();
  }

  /// Changes the recognition language.
  ///
  /// Refused while a session is active so a running engine cannot be
  /// re-targeted mid-utterance. Unsupported languages (Algerian Darija) are
  /// selectable on purpose: the UI explains why the microphone is disabled.
  bool selectLanguage(SpeechLanguage language) {
    if (_status.isActive) {
      return false;
    }
    if (language.id == _language.id) {
      return true;
    }
    _language = language;
    _sessionGeneration++;
    _clearSessionData(keepStatus: true);
    _status = PushToTalkStatus.idle;
    _notice = language.isSupported
        ? null
        : '${language.label}: ${language.detail}';
    notifyListeners();
    return true;
  }

  /// Parses recognized text and publishes the result. Exposed for tests and
  /// for a future "re-analyze transcript" action.
  VoiceResult parse(String text) => _parser.parse(text);

  @override
  void dispose() {
    _disposed = true;
    _sessionGeneration++;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    unawaited(_eventSubscription?.cancel());
    _eventSubscription = null;
    unawaited(_recognizer.dispose());
    super.dispose();
  }

  void _onRecognitionEvent(SpeechRecognitionEvent event) {
    if (_disposed) {
      return;
    }
    switch (event) {
      case SpeechSessionStarted():
        if (_status == PushToTalkStatus.initializing) {
          _status = PushToTalkStatus.listening;
          notifyListeners();
        }
      case SpeechPartialTranscript(:final text):
        if (_status == PushToTalkStatus.listening) {
          _partialText = text;
          notifyListeners();
        }
      case SpeechFinalTranscript(:final text):
        if (_status != PushToTalkStatus.listening &&
            _status != PushToTalkStatus.recognizing) {
          return;
        }
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        _partialText = null;
        _finalText = text;
        _interpretation = _parser.parse(text);
        _interpretationSource = InterpretationSource.speech;
        _failureKind = null;
        _errorMessage = null;
        _status = PushToTalkStatus.result;
        notifyListeners();
      case SpeechNoSpeechDetected():
        if (!_status.isActive) {
          return;
        }
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        _partialText = null;
        _finalText = null;
        _interpretation = null;
        _interpretationSource = null;
        _status = PushToTalkStatus.empty;
        notifyListeners();
      case SpeechSessionCancelled():
        _timeoutTimer?.cancel();
        _timeoutTimer = null;
        if (_status == PushToTalkStatus.cancelled) {
          return;
        }
        _partialText = null;
        _finalText = null;
        _status = PushToTalkStatus.cancelled;
        notifyListeners();
      case SpeechSessionFailed(:final kind, :final message):
        _fail(_sessionGeneration, kind, message);
    }
  }

  void _armTimeout(int generation) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(recognitionTimeout, () {
      if (!_isCurrent(generation) || _status != PushToTalkStatus.recognizing) {
        return;
      }
      _fail(
        generation,
        SpeechFailureKind.recognitionFailed,
        'The recognizer did not return a final result within '
        '${recognitionTimeout.inSeconds} seconds.',
      );
    });
  }

  void _fail(int generation, SpeechFailureKind kind, String message) {
    if (!_isCurrent(generation)) {
      return;
    }
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _status = PushToTalkStatus.error;
    _failureKind = kind;
    _errorMessage = message;
    _partialText = null;
    notifyListeners();
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _sessionGeneration;

  void _clearSessionData({bool keepStatus = false}) {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _partialText = null;
    _finalText = null;
    _interpretation = null;
    _interpretationSource = null;
    _failureKind = null;
    _errorMessage = null;
    if (!keepStatus) {
      _status = PushToTalkStatus.idle;
    }
  }
}
