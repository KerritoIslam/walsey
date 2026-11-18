import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

import 'voice_plan_executor.dart';
import 'voice_response_speaker.dart';
import 'android_wake_service.dart';

/// One honest, UI-ready phase of the voice workflow.
///
/// [planned], [answered] and [notExecuted] exist so the app can never blur "the
/// sentence was understood" with "the controller accepted something": nothing
/// was sent in any of those states.
enum VoiceSessionPhase {
  idle,
  pressing,
  recording,
  processing,
  interpreting,
  executing,
  success,
  answered,
  failure,
  cancelled,
  planned,
  notExecuted;

  bool get isBusy =>
      this == pressing ||
      this == recording ||
      this == processing ||
      this == interpreting ||
      this == executing;

  String get label => switch (this) {
        VoiceSessionPhase.idle => 'Ready',
        VoiceSessionPhase.pressing => 'Starting…',
        VoiceSessionPhase.recording => 'Recording',
        VoiceSessionPhase.processing => 'Transcribing…',
        VoiceSessionPhase.interpreting => 'Interpreting…',
        VoiceSessionPhase.executing => 'Executing plan…',
        VoiceSessionPhase.success => 'Executed',
        VoiceSessionPhase.answered => 'Answered — nothing sent',
        VoiceSessionPhase.failure => 'Not executed',
        VoiceSessionPhase.cancelled => 'Cancelled',
        VoiceSessionPhase.planned => 'Plan ready — not executed',
        VoiceSessionPhase.notExecuted => 'Not executed',
      };
}

/// Coordinates hold-to-talk, hands-free wake-word listening, interpretation
/// and plan execution.
///
/// This is the seam the UI talks to. Hold-to-talk is always available.
/// Hands-free listening is opt-in and starts only from an explicit user
/// action ([startWakeListening]); nothing here opens the microphone at launch.
///
/// Guarantees:
/// * one microphone consumer at a time — a hold stops hands-free listening
///   before the recorder opens, and a hold is refused while a wake capture is
///   being decoded;
/// * one speech session at a time — a second press while busy is ignored;
/// * release always ends the session, even if the pointer left the button;
/// * recognition, interpretation and execution stay separate phases;
/// * a parser failure never executes anything;
/// * a plan is executed only for recognized speech, never for typed text;
/// * a wake transcript goes through exactly the same interpreter/executor as a
///   hold-to-talk transcript — it is never parsed differently, and it is never
///   executed from a fabricated transcript.
class VoiceSessionController extends ChangeNotifier {
  VoiceSessionController({
    required SpeechRecognizer recognizer,
    required this.interpreter,
    this.executor,
    this.wakeWordDetector,
    this.wakeCommandLoop,
    this.androidWakeService,
    this.speaker,
    SpeechLanguage language = SpeechLanguage.defaultLanguage,
    Duration recognitionTimeout = const Duration(seconds: 20),
    this.holdWatchdogDelay = const Duration(seconds: 2),
    this.maxHoldDuration = const Duration(seconds: 60),
    this.onError,
    this.onLog,
  }) : _speech = PushToTalkController(
         recognizer: recognizer,
         language: language,
         recognitionTimeout: recognitionTimeout,
         onError: onError,
       ) {
    _wakeWordAvailability = wakeCommandLoop == null
        ? const WakeWordAvailability(
            capability: WakeWordCapability.notConfigured,
            message: 'Hands-free listening needs a trained "Walsey" wake-word '
                'model and an ONNX scoring backend, neither of which ships '
                'with this build. Hold the button to talk and type commands; '
                'Walsey never listens in the background.',
          )
        : const WakeWordAvailability(
            capability: WakeWordCapability.available,
            message: 'Hands-free listening is available but stopped. It starts '
                'only when you press Start listening.',
          );
    _speech.addListener(_onSpeechChanged);
  }

  /// Shared plan interpreter (pure, no execution).
  final CommandInterpreter interpreter;

  /// Real plan executor, or `null` when no BLE service is available.
  final CommandExecutor? executor;

  /// Present only when a build explicitly opts in. Never started at launch.
  final WakeWordDetector? wakeWordDetector;

  /// Hands-free pipeline ("Walsey" → captured command → transcript). Injected
  /// only by the Assistant page when the user enabled the feature.
  final WakeCommandSource? wakeCommandLoop;

  /// Android microphone foreground service that keeps the opt-in listener
  /// alive while the app is backgrounded. `null` on other platforms.
  final AndroidWakeService? androidWakeService;

  /// Optional spoken outcomes. Off unless the user enables them; the controller
  /// silences it before every take so a response can never be transcribed.
  final VoiceResponseSpeaker? speaker;

  /// Original startup/recognition exception for host diagnostics.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// How often an active hold is checked for a missing pointer-up.
  ///
  /// A press arms a watchdog; if the phase is still `pressing`/`recording`
  /// while the hold is no longer active, the take is stopped. This covers a
  /// release the app never saw (window lost the pointer capture, the OS
  /// swallowed it, or a parent gesture took the arena) without pretending the
  /// microphone is closed when it is not.
  final Duration holdWatchdogDelay;

  /// Hard cap on a single hold. A command never needs this long, and the
  /// microphone can never be left open indefinitely by a stuck pointer.
  final Duration maxHoldDuration;

  /// Diagnostic sink (the app passes `LedConnectionService.log`).
  ///
  /// Only real events are logged, with one prefix per pipeline stage so a
  /// transcript, an interpretation, a step start, a BLE write and a device
  /// reply can never be confused:
  /// `VOICE SESSION:`, `VOICE RECOGNIZED:`, `VOICE INTERPRETED:`,
  /// `ACTION STARTED:`, `PLAN RESULT:` (writes/replies are logged by the
  /// command service as `RESULT … BLE WRITE OK` / `PASSWORD REPLY:`).
  final void Function(String line)? onLog;

  final PushToTalkController _speech;
  late WakeWordAvailability _wakeWordAvailability;

  VoiceSessionPhase _phase = VoiceSessionPhase.idle;
  bool _pressed = false;
  String? _message;
  VoicePlanResult? _planResult;
  VoicePlanExecution? _execution;
  List<VoicePlanStepProgress> _steps = const [];
  String? _handledTranscript;
  int _pipeline = 0;
  bool _disposed = false;

  /// Identifies one press → release cycle in the diagnostic log.
  int _take = 0;

  /// Periodic liveness check for the active hold; `null` when no take is
  /// pressing/recording.
  Timer? _holdWatchdog;
  int _holdTicks = 0;

  /// User consent for hands-free listening. Only [startWakeListening] sets it
  /// true; a failure or an explicit stop clears it.
  bool _wakeWanted = false;

  /// True between a successful start and a stop/failure.
  bool _wakeListening = false;
  bool _wakeStarting = false;

  /// Honest, UI-ready hands-free status (never a fake "listening" state).
  String? _wakeStatus;

  StreamSubscription<WakeCommandEvent>? _wakeEvents;
  StreamSubscription<void>? _wakeStopRequests;

  /// Underlying speech session (status, transcript, latency).
  PushToTalkController get speech => _speech;

  VoiceSessionPhase get phase => _phase;

  /// True between pointer down and release, even before audio flows.
  bool get isPressed => _pressed;

  /// Honest, user-facing message for the current phase.
  String? get message => _message;

  /// Plan (or plan failure) for the most recent recognized/typed sentence.
  VoicePlanResult? get planResult => _planResult;

  /// The most recent execution, once a plan ran.
  VoicePlanExecution? get execution => _execution;

  /// Per-step progress of the running/finished plan.
  List<VoicePlanStepProgress> get steps => _steps;

  /// Measured latency of the last speech session.
  VoiceLatency? get latency => _speech.latency;

  String? get finalText => _speech.finalText;

  /// Wake-word state; describes capability, not an active session.
  WakeWordAvailability get wakeWordAvailability => _wakeWordAvailability;

  /// Whether hands-free listening is possible in this build.
  bool get wakeWordConfigured => wakeCommandLoop != null;

  /// True while the wake pipeline owns the microphone.
  bool get wakeListening => _wakeListening;

  /// True while a start request is in flight.
  bool get wakeStarting => _wakeStarting;

  /// True while a detected command is being captured/decoded.
  bool get wakeCapturing => wakeCommandLoop?.isCapturing ?? false;

  /// Honest hands-free status for the UI, or `null` when never started.
  String? get wakeStatus => _wakeStatus;

  /// Whether a new hold may start.
  bool get canStart =>
      !_disposed &&
      !_phase.isBusy &&
      !_speech.status.isActive &&
      !_wakeStarting &&
      !wakeCapturing;

  /// Whether the current session can be cancelled.
  bool get canCancel =>
      _phase == VoiceSessionPhase.recording ||
      _phase == VoiceSessionPhase.pressing ||
      _phase == VoiceSessionPhase.processing ||
      _phase == VoiceSessionPhase.interpreting ||
      _phase == VoiceSessionPhase.executing;

  /// Pointer down: starts a session immediately, but only one at a time.
  ///
  /// The visual "pressing" phase appears before the permission/model/recorder
  /// path completes, so a slow microphone open is visible, not silent.
  Future<void> press() async {
    if (!canStart) return;
    _pipeline++;
    _take++;
    _pressed = true;
    _phase = VoiceSessionPhase.pressing;
    _message = null;
    _planResult = null;
    _execution = null;
    _steps = const [];
    _handledTranscript = null;
    _log(
      'VOICE SESSION: hold started (take #$_take, attempt $_pipeline)',
    );
    notifyListeners();
    _startHoldWatchdog();

    // One microphone consumer at a time: hands-free listening must release the
    // microphone before the hold opens it. The user's consent is remembered so
    // listening can resume after the take.
    if (_wakeListening || _wakeStarting || wakeCapturing) {
      _log(
        'WAKE WORD: hold-to-talk started; stopping hands-free listening so only '
        'one microphone consumer exists',
      );
      await _stopWakeLoop(keepWanted: true);
    }
    if (_disposed) return;

    // Echo suppression: stop any previous spoken response before the
    // microphone opens, so the take cannot capture the assistant's own voice.
    await speaker?.silence();
    if (_disposed) return;
    if (!_pressed) {
      // The user let go while the previous response was still stopping. The
      // recognizer was never asked to start, so the microphone stays closed.
      _stopHoldWatchdog();
      _log(
        'VOICE SESSION: take #$_take — released before the microphone opened; '
        'nothing was recorded',
      );
      _setPhase(
        VoiceSessionPhase.cancelled,
        'Released before recording started. Nothing was recorded.',
        false,
      );
      return;
    }

    await _speech.startListening();
    if (_disposed) return;
    if (!_pressed) {
      // `release()` may have stopped the take while `startListening` was still
      // running. Finishing here is idempotent and guarantees the recorder is
      // closed even if the stop request raced the start.
      if (_speech.status == PushToTalkStatus.listening ||
          _speech.status == PushToTalkStatus.initializing) {
        _log(
          'VOICE SESSION: take #$_take — released while the recognizer was '
          'starting; stopping it now',
        );
        _setPhase(VoiceSessionPhase.processing);
        await _speech.stopListening();
      }
      return;
    }
    switch (_speech.status) {
      case PushToTalkStatus.listening:
        if (_pressed) _setPhase(VoiceSessionPhase.recording);
      case PushToTalkStatus.initializing:
        // startListening returns before audio flows; stay in "pressing" until
        // SpeechSessionStarted or a failure event.
        break;
      case PushToTalkStatus.error:
        _pressed = false;
        _setPhase(VoiceSessionPhase.failure, _speech.errorMessage);
      case PushToTalkStatus.empty ||
            PushToTalkStatus.result ||
            PushToTalkStatus.cancelled ||
            PushToTalkStatus.recognizing ||
            PushToTalkStatus.idle:
        break;
    }
  }

  /// Pointer up (or pointer cancel): ends the take and starts the pipeline.
  ///
  /// Safe to call even after the session already failed; it never starts a
  /// second session and never throws.
  Future<void> release() async {
    if (_disposed) return;
    final wasPressed = _pressed;
    _pressed = false;
    if (!wasPressed &&
        _phase != VoiceSessionPhase.recording &&
        _phase != VoiceSessionPhase.pressing) {
      return;
    }
    if (_phase == VoiceSessionPhase.processing ||
        _phase == VoiceSessionPhase.interpreting ||
        _phase == VoiceSessionPhase.executing) {
      return;
    }
    final status = _speech.status;
    if (status == PushToTalkStatus.idle) {
      // `press()` is still echoing-suppression/queued. It re-checks `_pressed`
      // after that await and will not open the microphone, so the release is
      // never lost here — there is simply nothing to stop yet.
      _log(
        'VOICE SESSION: take #$_take — released before the recognizer was '
        'asked to start',
      );
      return;
    }
    if (!status.isActive) {
      // The take already ended (failure, empty, or a previous stop). Nothing
      // is capturing, so this must not restart or re-report anything.
      return;
    }
    _log(
      'VOICE SESSION: take #$_take — released (status ${status.name}); '
      'stopping the microphone',
    );
    _setPhase(VoiceSessionPhase.processing);
    await _speech.stopListening();
  }

  /// Cancels the take or the running plan without publishing a result.
  Future<void> cancel() async {
    if (_disposed) return;
    _pipeline++;
    _pressed = false;
    _log(
      'VOICE SESSION: take #$_take — cancelled by the user; nothing further '
      'is executed',
    );
    executor?.cancel();
    if (_speech.status.isActive || _speech.canCancel) {
      await _speech.cancel();
    }
    _setPhase(VoiceSessionPhase.cancelled, 'The session was cancelled.');
  }

  /// Interprets typed text without ever executing it.
  VoicePlanResult interpretTyped(String text) {
    final trimmed = text.trim();
    _handledTranscript = null;
    _planResult = null;
    _execution = null;
    _steps = const [];
    if (trimmed.isEmpty) {
      final failure = VoicePlanFailure(
        sourceText: trimmed,
        kind: VoiceFailureKind.emptyInput,
        explanation: 'Type a command sentence first.',
      );
      _planResult = failure;
      _log('VOICE INTERPRETED (typed, not executed): rejected — empty input');
      _setPhase(VoiceSessionPhase.failure, failure.explanation, false);
      return failure;
    }
    final result = interpreter.interpret(trimmed);
    _planResult = result;
    switch (result) {
      case VoicePlanFailure(:final kind, :final explanation):
        _log(
          'VOICE INTERPRETED (typed, not executed): rejected '
          'kind=${kind.name} — $explanation',
        );
        _setPhase(VoiceSessionPhase.notExecuted, explanation, false);
      case VoicePlanReady(:final plan):
        _log(
          'VOICE INTERPRETED (typed, not executed): plan with '
          '${plan.steps.length} step${plan.steps.length == 1 ? '' : 's'} — '
          '${plan.summary.join(' → ')}',
        );
        _setPhase(
          VoiceSessionPhase.planned,
          'Interpreted only. Typed commands are never executed. Plan: '
          '${plan.summary.join(' → ')}',
          false,
        );
    }
    return result;
  }

  /// Clears the current result without touching the recognizer.
  void clear() {
    if (_phase.isBusy) return;
    _pipeline++;
    _planResult = null;
    _execution = null;
    _steps = const [];
    _handledTranscript = null;
    _speech.clear();
    _setPhase(VoiceSessionPhase.idle);
  }

  /// Starts hands-free listening. **Explicit user action only.**
  ///
  /// Order matters: the Android foreground service is started first so the
  /// process is never killed mid-listen, then the detector. Any failure stops
  /// whatever was started and is reported, never hidden behind a fake
  /// "listening" label.
  Future<bool> startWakeListening() async {
    final loop = wakeCommandLoop;
    if (_disposed || loop == null) {
      _wakeStatus = 'Hands-free listening is not available in this build.';
      notifyListeners();
      return false;
    }
    if (_wakeListening || _wakeStarting) {
      return _wakeListening;
    }
    if (_phase.isBusy || _speech.status.isActive) {
      _wakeStatus = 'Finish the current command first.';
      notifyListeners();
      return false;
    }
    _wakeStarting = true;
    _wakeWanted = true;
    _wakeStatus = 'Starting hands-free listening…';
    notifyListeners();
    _log('WAKE WORD: hands-free listening requested (explicit user action)');

    _wakeEvents ??= loop.events.listen(_onWakeEvent);
    if (androidWakeService != null) {
      _wakeStopRequests ??= androidWakeService!.stopRequests.listen((_) {
        _log('WAKE WORD: stop requested from the notification');
        unawaited(stopWakeListening());
      });
      try {
        final supported = await androidWakeService!.isSupported();
        if (supported) {
          await androidWakeService!.start();
        }
      } on Object catch (error) {
        _wakeStarting = false;
        _wakeWanted = false;
        _wakeStatus = '$error';
        _log('WAKE WORD: the microphone foreground service did not start — '
            '$error');
        notifyListeners();
        return false;
      }
    }

    try {
      await loop.start();
    } on Object catch (error) {
      _wakeStarting = false;
      _wakeWanted = false;
      _wakeStatus = 'Hands-free listening could not start: $error';
      _log('WAKE WORD: hands-free listening failed to start — $error');
      await androidWakeService?.stop();
      notifyListeners();
      return false;
    }
    if (_disposed) return false;
    if (!_wakeWanted) {
      // Stopped while the detector was opening.
      await _stopWakeLoop();
      return false;
    }
    _wakeStarting = false;
    _wakeListening = true;
    _wakeStatus = 'Listening for "Walsey". The microphone stays open until you '
        'stop listening.';
    _log('WAKE WORD: listening — the detector is running; hold-to-talk still '
        'works');
    notifyListeners();
    return true;
  }

  /// Stops hands-free listening and the Android foreground service.
  Future<void> stopWakeListening() async {
    _wakeWanted = false;
    await _stopWakeLoop();
    if (_disposed) return;
    _wakeStatus = 'Hands-free listening is off.';
    _log('WAKE WORD: listening stopped by the user');
    notifyListeners();
  }

  /// Loads the wake model and the recognition engine without opening the
  /// microphone. Safe to call on page open; never starts listening.
  Future<WakeWordAvailability> prewarmWakeWord() async {
    final loop = wakeCommandLoop;
    if (loop == null) return _wakeWordAvailability;
    try {
      _wakeWordAvailability = await loop.prewarm();
    } on Object catch (error) {
      _wakeWordAvailability = WakeWordAvailability(
        capability: WakeWordCapability.notConfigured,
        message: 'The wake-word pipeline could not warm up: $error',
      );
    }
    if (!_disposed) notifyListeners();
    return _wakeWordAvailability;
  }

  Future<void> _stopWakeLoop({bool keepWanted = false}) async {
    if (!keepWanted) _wakeWanted = false;
    final loop = wakeCommandLoop;
    _wakeStarting = false;
    if (loop != null) {
      try {
        await loop.stop();
      } on Object {
        // Releasing the microphone must not mask the caller's error.
      }
    }
    await androidWakeService?.stop();
    if (_wakeListening) {
      _wakeListening = false;
      _log('WAKE WORD: microphone released; hands-free listening is off');
    }
    _wakeListening = false;
    if (keepWanted && !_disposed) {
      _wakeStatus = 'Hands-free listening paused while the hold is active.';
    }
  }

  void _onWakeEvent(WakeCommandEvent event) {
    if (_disposed) return;
    switch (event) {
      case WakeListening():
        _wakeListening = true;
        _wakeStatus = 'Listening for "Walsey".';
        notifyListeners();
      case WakeDetected():
        _wakeStatus = 'Wake word heard — say your command.';
        _log('WAKE WORD: "Walsey" detected; capturing the command');
        // TTS echo protection: a spoken outcome must never be captured as the
        // command that follows the wake word.
        unawaited(speaker?.silence());
        notifyListeners();
      case WakeCapturing():
        _wakeStatus = 'Capturing the command…';
        notifyListeners();
      case WakeTranscript(:final text):
        _wakeListening = true;
        _wakeStatus = 'Command transcribed.';
        _pressed = false;
        _handledTranscript = text;
        _log('VOICE RECOGNIZED: transcript="$text" (hands-free)');
        unawaited(_interpretAndExecute(text));
      case WakeEmpty(:final message):
        _wakeStatus = message;
        _log('VOICE RECOGNIZED: none (hands-free) — $message');
        notifyListeners();
      case WakeFailed(:final message):
        _wakeListening = false;
        _wakeWanted = false;
        _wakeStatus = message;
        _log('WAKE WORD: failed — $message');
        unawaited(androidWakeService?.stop());
        notifyListeners();
      case WakeStopped():
        // The loop emits this only for a stop it was asked to perform. The
        // user's intent is tracked separately, so a hold that paused listening
        // can still resume afterwards.
        _wakeListening = false;
        if (!_wakeWanted) {
          _wakeStatus = 'Hands-free listening is off.';
          unawaited(androidWakeService?.stop());
        }
        notifyListeners();
    }
  }

  /// Restarts hands-free listening after a take, but only if the user had it
  /// running, no take is in progress and no failure occurred. Called after a
  /// spoken outcome finishes so the response cannot be captured.
  Future<void> _resumeWakeIfWanted() async {
    if (_disposed || !_wakeWanted || _wakeListening || _pressed) return;
    if (_phase.isBusy) return;
    await startWakeListening();
  }

  /// Prepares the injected detector port **without starting it**.
  ///
  /// Returns the inert [wakeWordAvailability] when no detector exists. Even a
  /// successful prepare leaves the detector stopped.
  Future<WakeWordAvailability> inspectWakeWord() async {
    final detector = wakeWordDetector;
    if (detector == null) return _wakeWordAvailability;
    try {
      _wakeWordAvailability = await detector.prepare();
    } on Object catch (error) {
      _wakeWordAvailability = WakeWordAvailability(
        capability: WakeWordCapability.permissionDenied,
        message: 'Wake word could not be prepared: $error',
      );
    }
    notifyListeners();
    return _wakeWordAvailability;
  }

  @override
  void dispose() {
    _disposed = true;
    _pipeline++;
    _wakeWanted = false;
    _stopHoldWatchdog();
    unawaited(_wakeEvents?.cancel());
    _wakeEvents = null;
    unawaited(_wakeStopRequests?.cancel());
    _wakeStopRequests = null;
    unawaited(wakeCommandLoop?.dispose());
    unawaited(androidWakeService?.stop());
    unawaited(androidWakeService?.dispose());
    executor?.onProgress = null;
    executor?.cancel();
    _speech.removeListener(_onSpeechChanged);
    _speech.dispose();
    unawaited(wakeWordDetector?.dispose());
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Pipeline
  // ---------------------------------------------------------------------------

  void _onSpeechChanged() {
    if (_disposed) return;
    switch (_speech.status) {
      case PushToTalkStatus.listening:
        if (!_pressed &&
            (_phase == VoiceSessionPhase.pressing ||
                _phase == VoiceSessionPhase.recording)) {
          // The recorder reported "listening" after the user already let go.
          // That ordering must never leave the microphone open.
          _log(
            'VOICE SESSION: take #$_take — the microphone opened after the '
            'release; stopping it',
          );
          _setPhase(VoiceSessionPhase.processing);
          unawaited(_speech.stopListening());
        } else if (_phase == VoiceSessionPhase.pressing) {
          _log(
            'VOICE SESSION: take #$_take — microphone open; recording',
          );
          _setPhase(VoiceSessionPhase.recording);
        }
      case PushToTalkStatus.initializing:
        break;
      case PushToTalkStatus.recognizing:
        if (_phase == VoiceSessionPhase.recording ||
            _phase == VoiceSessionPhase.pressing) {
          _log(
            'VOICE SESSION: take #$_take — microphone stopped; transcribing',
          );
          _setPhase(VoiceSessionPhase.processing);
        }
      case PushToTalkStatus.result:
        final text = _speech.finalText;
        if (text == null || text == _handledTranscript) {
          notifyListeners();
          return;
        }
        _handledTranscript = text;
        _pressed = false;
        _log('VOICE RECOGNIZED: transcript="$text"');
        unawaited(_interpretAndExecute(text));
      case PushToTalkStatus.empty:
        _pressed = false;
        _log(
          'VOICE RECOGNIZED: none (empty take) — nothing was interpreted '
          'or sent',
        );
        _setPhase(
          VoiceSessionPhase.failure,
          'No speech was detected. Nothing was interpreted or sent.',
        );
      case PushToTalkStatus.cancelled:
        _pressed = false;
        _log('VOICE RECOGNIZED: cancelled before a transcript existed');
        _setPhase(VoiceSessionPhase.cancelled, 'The session was cancelled.');
      case PushToTalkStatus.error:
        _pressed = false;
        _log(
          'VOICE RECOGNIZED: failed — '
          '${_speech.errorMessage ?? 'speech recognition failed'}',
        );
        _setPhase(
          VoiceSessionPhase.failure,
          _speech.errorMessage ?? 'Speech recognition failed.',
        );
      case PushToTalkStatus.idle:
        notifyListeners();
    }
  }

  Future<void> _interpretAndExecute(String text) async {
    final generation = ++_pipeline;
    _phase = VoiceSessionPhase.interpreting;
    _message = null;
    notifyListeners();

    final result = interpreter.interpret(text);
    _planResult = result;
    if (_disposed || generation != _pipeline) return;

    switch (result) {
      case VoicePlanFailure(:final kind, :final explanation):
        _log(
          'VOICE INTERPRETED: rejected kind=${kind.name} — $explanation; '
          'nothing was executed',
        );
        _setPhase(VoiceSessionPhase.failure, explanation);
        return;
      case VoicePlanReady(:final plan):
        _log(
          'VOICE INTERPRETED: plan with ${plan.steps.length} '
          'step${plan.steps.length == 1 ? '' : 's'} — '
          '${plan.summary.join(' → ')}',
        );
        final executor = this.executor;
        if (executor == null) {
          _log('ACTION NOT STARTED: no execution service is available');
          _setPhase(
            VoiceSessionPhase.planned,
            'Plan ready, but no execution service is available. Nothing was '
            'sent.',
          );
          return;
        }
        executor.onProgress = _onProgress;
        _phase = VoiceSessionPhase.executing;
        _message = 'Executing ${plan.steps.length} step'
            '${plan.steps.length == 1 ? '' : 's'}…';
        _log(
          'ACTION STARTED: executing ${plan.steps.length} '
          'step${plan.steps.length == 1 ? '' : 's'} over the existing '
          'connection service',
        );
        notifyListeners();
        final execution = await executor.execute(plan);
        executor.onProgress = null;
        if (_disposed || generation != _pipeline) return;
        _execution = execution;
        _log(
          'PLAN RESULT: ${execution.success ? 'success' : 'failed'} — '
          '${execution.message}',
        );
        _setPhase(
          execution.success
              ? (execution.wroteNothing && _asksForStatus(plan)
                  ? VoiceSessionPhase.answered
                  : VoiceSessionPhase.success)
              : VoiceSessionPhase.failure,
          execution.message,
        );
    }
  }

  /// Whether the plan's only purpose was to ask for device state.
  ///
  /// Such a plan legitimately finishes without a frame write, so it must not be
  /// presented as "Executed".
  static bool _asksForStatus(VoicePlan plan) =>
      plan.steps.any((step) => step is QueryStatusStep);

  void _onProgress(List<VoicePlanStepProgress> steps) {
    if (_disposed) return;
    _steps = steps;
    notifyListeners();
  }

  void _setPhase(
    VoiceSessionPhase phase, [
    String? message,
    bool speak = true,
  ]) {
    // A page can be disposed while a stop/cancel is still awaiting the
    // recognizer; never notify a disposed ChangeNotifier.
    if (_disposed) return;
    _phase = phase;
    _message = message;
    if (phase != VoiceSessionPhase.pressing &&
        phase != VoiceSessionPhase.recording) {
      _stopHoldWatchdog();
    }
    if (speak) {
      final summary = _spokenSummary(phase);
      if (summary != null) {
        final announcement = speaker?.announce(summary);
        if (announcement != null) {
          // Resume hands-free listening only after the spoken response ends, so
          // the assistant can never capture its own voice as a command.
          unawaited(announcement.whenComplete(_resumeWakeIfWanted));
        } else {
          unawaited(_resumeWakeIfWanted());
        }
      } else {
        unawaited(_resumeWakeIfWanted());
      }
    } else {
      unawaited(_resumeWakeIfWanted());
    }
    notifyListeners();
  }

  /// Short, fixed outcome text. Deliberately not the diagnostic [message]:
  /// speaking a long error is slow and can include user text.
  static String? _spokenSummary(VoiceSessionPhase phase) => switch (phase) {
        VoiceSessionPhase.success => 'Done.',
        VoiceSessionPhase.answered => 'The state is unknown. Nothing was sent.',
        VoiceSessionPhase.failure => 'Command not executed.',
        VoiceSessionPhase.cancelled => 'Cancelled.',
        VoiceSessionPhase.planned || VoiceSessionPhase.notExecuted =>
          'Plan ready. Nothing was sent.',
        _ => null,
      };

  void _log(String line) => onLog?.call(line);

  // ---------------------------------------------------------------------------
  // Hold watchdog
  // ---------------------------------------------------------------------------

  /// Number of watchdog ticks that add up to [maxHoldDuration].
  int get _holdTickLimit {
    final tick = holdWatchdogDelay.inMicroseconds;
    if (tick <= 0) return 1;
    final ticks = (maxHoldDuration.inMicroseconds / tick).ceil();
    return ticks < 1 ? 1 : ticks;
  }

  void _startHoldWatchdog() {
    _stopHoldWatchdog();
    _holdTicks = 0;
    _holdWatchdog = Timer.periodic(holdWatchdogDelay, (_) => _onHoldTick());
  }

  void _stopHoldWatchdog() {
    _holdWatchdog?.cancel();
    _holdWatchdog = null;
    _holdTicks = 0;
  }

  void _onHoldTick() {
    if (_disposed) {
      _stopHoldWatchdog();
      return;
    }
    if (_phase != VoiceSessionPhase.pressing &&
        _phase != VoiceSessionPhase.recording) {
      _stopHoldWatchdog();
      return;
    }
    _holdTicks++;
    if (_holdTicks >= _holdTickLimit) {
      _log(
        'VOICE SESSION: take #$_take — maximum hold reached '
        '(${maxHoldDuration.inSeconds}s); stopping the take',
      );
      unawaited(_forceStopTake());
      return;
    }
    if (!_pressed) {
      _log(
        'VOICE SESSION: take #$_take — the pointer release was never '
        'observed; stopping the take automatically',
      );
      unawaited(_forceStopTake());
    }
  }

  /// Stops the microphone for a take the app believes was never released.
  ///
  /// The phase only changes after the recognizer has actually been asked to
  /// stop, so this can never fake a closed microphone.
  Future<void> _forceStopTake() async {
    if (_disposed) return;
    _stopHoldWatchdog();
    _pressed = false;
    final status = _speech.status;
    if (status == PushToTalkStatus.listening ||
        status == PushToTalkStatus.initializing) {
      _setPhase(VoiceSessionPhase.processing);
      await _speech.stopListening();
      return;
    }
    if (!status.isActive &&
        (_phase == VoiceSessionPhase.pressing ||
            _phase == VoiceSessionPhase.recording)) {
      // The recognizer never reached a recording state; report the abandoned
      // hold honestly instead of leaving a busy phase behind.
      _setPhase(
        VoiceSessionPhase.cancelled,
        'The microphone session never started. Nothing was recorded.',
        false,
      );
    }
  }
}
