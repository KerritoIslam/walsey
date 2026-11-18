import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

import '../../connection/led_connection_service.dart';
import '../../design/hold_to_talk_button.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/activity_log.dart';
import '../../state/app_settings.dart';
import '../../voice/voice_plan_executor.dart';
import '../../voice/voice_response_speaker.dart';
import '../../voice/voice_session_controller.dart';
import '../../voice/android_wake_service.dart';

enum _VoiceEngine { whisper, vosk }

class AssistantPage extends StatefulWidget {
  const AssistantPage({
    super.key,
    required this.service,
    required this.connected,
    required this.compact,
    this.activity,
    this.executor,
    this.settings,
    this.recognizer,
    this.wakeLoop,
    this.androidWakeService,
  });

  final LedConnectionService service;
  final bool connected;
  final bool compact;
  final ActivityLog? activity;

  /// Optional executor override for tests. Production builds the real one over
  /// [service], so a plan can only touch the existing connection/command API.
  final CommandExecutor? executor;

  /// Optional settings source for opt-in spoken responses. Absent in widget
  /// tests and in any build without preferences: TTS then stays disabled.
  final AppSettingsService? settings;

  /// Optional recognizer override for tests.
  ///
  /// Production builds the real Whisper (or Vosk) recognizer; tests inject an
  /// in-memory one so the hold-to-talk gesture, page navigation and app
  /// lifecycle path can be driven without a microphone or a model.
  final SpeechRecognizer? recognizer;

  /// Optional opt-in hands-free pipeline. `null` when no wake model/backend is
  /// installed; the page then states that honestly instead of showing a fake
  /// "listening" control.
  final WakeCommandSource? wakeLoop;

  final AndroidWakeService? androidWakeService;

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage>
    with WidgetsBindingObserver {
  final _diagnostics = SessionDiagnostics();
  final _modelStore = ModelStore.platform();
  final _suggestions = const [
    'Turn the lights on',
    'Set the color to blue',
    'Set brightness to 50 percent',
    'Scan for devices and turn the first one on',
    'Connect to the first device and set the color to green',
    'Disconnect from the current device',
  ];

  late SpeechRecognizer _recognizer;
  late VoiceSessionController _session;
  late final VoiceResponseSpeaker _speaker = VoiceResponseSpeaker(
    engine: FlutterTtsEngine(),
  );
  _VoiceEngine _engine = _VoiceEngine.whisper;
  Timer? _elapsedTimer;
  Stopwatch? _takeClock;
  SpeechModel? _model;
  bool? _modelInstalled;
  String? _modelError;
  final _typedController = TextEditingController();
  final List<_HistoryItem> _history = [];

  /// Expiring target memory for pronoun follow-ups. It never stores LED state.
  final VoiceConversation _conversation = VoiceConversation();

  VoicePlanResult? _seenPlan;
  VoicePlanExecution? _seenExecution;
  String? _loggedTranscript;
  VoiceSessionPhase _lastPhase = VoiceSessionPhase.idle;
  bool _typedPending = false;
  bool _deactivating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.settings?.listenable.addListener(_applySpokenSetting);
    _applySpokenSetting();
    _createSession();
  }

  void _applySpokenSetting() {
    _speaker.enabled = widget.settings?.value.spokenResponses ?? false;
  }

  /// Records the user's consent. Turning consent off always stops a running
  /// listener; turning it on never starts one (that stays an explicit press).
  Future<void> _setWakeConsent(bool enabled) async {
    await widget.settings?.setWakeWordEnabled(enabled);
    if (!enabled) await _session.stopWakeListening();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _startWakeListening() async {
    if (!(widget.settings?.value.wakeWordEnabled ?? false)) return;
    final started = await _session.startWakeListening();
    if (!mounted) return;
    if (started) {
      widget.activity?.add(
        kind: ActivityKind.voice,
        title: 'Hands-free listening started',
        detail: 'The microphone stays open until you stop listening.',
      );
    }
    setState(() {});
  }

  Future<void> _stopWakeListening() async {
    await _session.stopWakeListening();
    if (!mounted) return;
    widget.activity?.add(
      kind: ActivityKind.voice,
      title: 'Hands-free listening stopped',
      detail: 'The microphone was released.',
    );
    setState(() {});
  }

  void _createSession() {
    _recognizer = widget.recognizer ??
        (_engine == _VoiceEngine.whisper
            ? WhisperSpeechRecognizer.platform(diagnostics: _diagnostics)
            : VoskSpeechRecognizer.platform(diagnostics: _diagnostics));
    _session = VoiceSessionController(
      recognizer: _recognizer,
      interpreter: VoicePlanParser(conversation: _conversation),
      executor: widget.executor ?? VoicePlanExecutor(service: widget.service),
      speaker: _speaker,
      wakeCommandLoop: widget.wakeLoop,
      androidWakeService: widget.androidWakeService,
      onError: _logVoiceError,
      onLog: widget.service.log,
    )..addListener(_onChanged);
    _syncTakeClock();
    _refreshModel();
    // Warm the engine/model for hands-free use, but never start listening:
    // only the explicit "Start listening" button does that.
    if (widget.wakeLoop != null) {
      unawaited(_session.prewarmWakeWord().then((_) => _onChanged()));
    }
  }

  void _logVoiceError(Object error, StackTrace stackTrace) {
    developer.log(
      'Voice assistant startup/recognition failure',
      name: 'WalseyApp',
      error: error,
      stackTrace: stackTrace,
    );
  }

  @override
  void didUpdateWidget(AssistantPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A changed connection makes the remembered target unsafe. The next
    // pronoun request then stays a plain single step instead of guessing.
    if (oldWidget.connected && !widget.connected) {
      _conversation.invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving the app must never leave the microphone (or a running plan)
    // open. Cancelling is deliberate: a background interruption is not a
    // finished take.
    if (state != AppLifecycleState.resumed && _session.phase.isBusy) {
      unawaited(_session.cancel());
    }
    // Hands-free listening may continue in the background only on Android,
    // where WakeWordForegroundService shows the mandatory notification. On
    // every other platform background capture is not supported, so stop it
    // and say so instead of pretending to listen.
    if (state != AppLifecycleState.resumed &&
        _session.wakeListening &&
        !(widget.androidWakeService?.isSupportedPlatform ?? false)) {
      unawaited(_session.stopWakeListening());
    }
  }

  @override
  void deactivate() {
    // Releasing / navigation-away disposes the page, but cancel here too so a
    // gesture that is still down cannot keep the session alive during teardown.
    // `_deactivating` keeps the synchronous cancel notification from calling
    // `setState` on an element that is already being deactivated.
    if (_session.phase.isBusy) {
      _deactivating = true;
      unawaited(_session.cancel());
    }
    super.deactivate();
  }

  @override
  void activate() {
    _deactivating = false;
    super.activate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _elapsedTimer?.cancel();
    _session.removeListener(_onChanged);
    _session.dispose();
    widget.settings?.listenable.removeListener(_applySpokenSetting);
    unawaited(_speaker.dispose());
    _diagnostics.dispose();
    _typedController.dispose();
    super.dispose();
  }

  void _syncTakeClock() {
    if (_session.phase == VoiceSessionPhase.recording && _takeClock == null) {
      _takeClock = Stopwatch()..start();
      _elapsedTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => mounted ? setState(() {}) : null,
      );
    } else if (_session.phase != VoiceSessionPhase.recording &&
        _takeClock != null) {
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
      _takeClock = null;
    }
  }

  void _onChanged() {
    if (!mounted || _deactivating) return;
    _syncTakeClock();

    if (_session.phase == VoiceSessionPhase.cancelled &&
        _lastPhase != VoiceSessionPhase.cancelled) {
      _conversation.invalidate();
    }

    // One real transcript -> one history row and one latency log line.
    final transcript = _session.finalText;
    if (transcript != null && transcript != _loggedTranscript) {
      _loggedTranscript = transcript;
      final latency = _session.latency;
      if (latency != null && latency.hasData) {
        widget.service.log('VOICE LATENCY: ${latency.logLine}');
      }
    }

    final plan = _session.planResult;
    if (plan != null && !identical(plan, _seenPlan)) {
      _seenPlan = plan;
      // A refused/ambiguous sentence makes the previous device target unsafe.
      if (plan is VoicePlanFailure) _conversation.invalidate();
      final typed = _typedPending;
      final item = _HistoryItem(
        transcript: transcript ?? plan.sourceText,
        interpretation: switch (plan) {
          VoicePlanReady(:final plan) => plan.summary.join(' → '),
          VoicePlanFailure(:final explanation) => explanation,
        },
        typed: typed,
        execution: typed
            ? 'Interpreted only — typed commands are never executed.'
            : null,
      );
      setState(() => _history.insert(0, item));
      widget.activity?.add(
        kind: ActivityKind.voice,
        title: typed ? 'Typed command interpreted' : 'Heard "$transcript"',
        detail: item.interpretation,
      );
    }

    final execution = _session.execution;
    if (execution != null && !identical(execution, _seenExecution)) {
      _seenExecution = execution;
      if (execution.success) _rememberConversationTarget();
      if (_history.isNotEmpty) {
        final item = _history.first;
        item.execution = execution.message;
        item.success = execution.success;
      }
      widget.activity?.add(
        kind: ActivityKind.voice,
        title: execution.success
            ? (execution.wroteNothing
                ? 'Voice plan finished — nothing was sent'
                : 'Voice plan executed')
            : 'Voice plan not executed',
        detail: execution.message,
        success: execution.success,
      );
    }

    setState(() {});
    _typedPending = false;
    _lastPhase = _session.phase;
  }

  /// Records the device a successful plan actually targeted, so a later
  /// pronoun follow-up ("make them blue") can propose a reconnect.
  ///
  /// It records only an intent and a name — never LED state — and it skips a
  /// plan that did not reach a lighting step (for example a status query).
  void _rememberConversationTarget() {
    final plan = _seenPlan;
    if (plan is! VoicePlanReady) return;
    VoiceIntent? intent;
    for (final step in plan.plan.steps.reversed) {
      intent = switch (step) {
        SetPowerStep(:final on) =>
          on ? VoiceIntent.powerOn : VoiceIntent.powerOff,
        SetColorStep() => VoiceIntent.setColor,
        SetBrightnessStep() => VoiceIntent.setBrightness,
        ApplyEffectStep() => VoiceIntent.applyEffect,
        _ => null,
      };
      if (intent != null) break;
    }
    if (intent == null) return;
    final device = widget.service.current.selected?.name ??
        widget.service.lastConnectedDevice?.name;
    if (device == null) return;
    _conversation.record(intent: intent, deviceName: device);
  }

  /// Typed input uses the same interpreter but is never executed.
  void _analyzeTyped(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_session.phase.isBusy) return;
    setState(() {
      _typedPending = true;
      _seenPlan = null;
      _seenExecution = null;
      _loggedTranscript = null;
    });
    _session.interpretTyped(trimmed);
    if (!mounted) return;
    setState(() => _typedPending = false);
  }

  Future<void> _refreshModel() async {
    final recognizer = _recognizer;
    _model = recognizer is EngineSpeechRecognizer
        ? recognizer.modelFor(_session.speech.language)
        : null;
    final model = _model;
    if (model == null) {
      if (mounted) {
        setState(() {
          _modelInstalled = false;
          _modelError = null;
        });
      }
      return;
    }
    try {
      final installed = await _modelStore.isInstalled(model);
      if (mounted) {
        setState(() {
          _modelInstalled = installed;
          _modelError = null;
        });
      }
    } on Object catch (error, stackTrace) {
      _logVoiceError(error, stackTrace);
      if (mounted) {
        setState(() {
          _modelInstalled = false;
          _modelError = 'Could not inspect the model folder: $error';
        });
      }
    }
  }

  Future<void> _switchEngine(_VoiceEngine? engine) async {
    if (engine == null || engine == _engine || _session.phase.isBusy) return;
    _session.removeListener(_onChanged);
    _session.dispose();
    _engine = engine;
    _seenPlan = null;
    _seenExecution = null;
    _createSession();
    setState(() {});
  }

  Future<void> _openModels() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ModelDialog(store: _modelStore),
    );
    await _refreshModel();
  }

  String _elapsedLabel() {
    final elapsed = _takeClock?.elapsed ?? Duration.zero;
    return '${elapsed.inMinutes.toString().padLeft(2, '0')}:'
        '${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final phase = _session.phase;
    final planResult = _session.planResult;
    final execution = _session.execution;
    final modelLabel = _model == null
        ? 'No model for this engine/language'
        : _modelInstalled == true
            ? 'Model ready · ${_model!.id}'
            : 'Model missing · ${_model!.id}';

    return WPageBody(
      compact: widget.compact,
      children: [
        WPageHeader(
          title: 'Assistant',
          compact: widget.compact,
          caption: 'Hold to talk · offline recognition · plans execute step by '
              'step, and only when a real controller is available.',
          actions: [
            WBadge(
              label: _engine == _VoiceEngine.whisper ? 'Whisper' : 'Vosk',
              tone: WBadgeTone.planned,
            ),
            if (widget.compact)
              IconButton(
                tooltip: 'Offline models',
                onPressed: _openModels,
                icon: const Icon(Icons.download),
              ),
          ],
        ),
        WCard(
          padding: const EdgeInsets.symmetric(
            horizontal: WalseySpacing.huge,
            vertical: WalseySpacing.giant,
          ),
          child: Column(
            children: [
              WBadge(
                label: phase.label,
                tone: switch (phase) {
                  VoiceSessionPhase.recording ||
                  VoiceSessionPhase.pressing ||
                  VoiceSessionPhase.processing ||
                  VoiceSessionPhase.interpreting ||
                  VoiceSessionPhase.executing =>
                    WBadgeTone.connecting,
                  VoiceSessionPhase.success => WBadgeTone.online,
                  VoiceSessionPhase.answered => WBadgeTone.planned,
                  VoiceSessionPhase.failure ||
                  VoiceSessionPhase.notExecuted =>
                    WBadgeTone.error,
                  _ => WBadgeTone.offline,
                },
              ),
              const SizedBox(height: WalseySpacing.xxl),
              HoldToTalkButton(
                phase: phase,
                enabled: _session.canStart,
                onPressStart: () => unawaited(_session.press()),
                onPressEnd: () => unawaited(_session.release()),
                onPressCancel: () => unawaited(_session.cancel()),
                label: 'Hold to talk',
                hint: 'Release to decode. One session at a time.',
              ),
              if (phase == VoiceSessionPhase.recording) ...[
                const SizedBox(height: WalseySpacing.sm),
                Text(_elapsedLabel(), style: WalseyType.display.copyWith(
                  fontSize: 26,
                  letterSpacing: 1,
                )),
              ],
              if (_session.canCancel) ...[
                const SizedBox(height: WalseySpacing.md),
                TextButton(
                  onPressed: () => unawaited(_session.cancel()),
                  child: const Text('Cancel without sending'),
                ),
              ],
            ],
          ),
        ),
        if (_session.message != null && !phase.isBusy)
          WInfoBanner(
            tone: switch (phase) {
              VoiceSessionPhase.success => WInfoTone.success,
              VoiceSessionPhase.answered ||
              VoiceSessionPhase.planned =>
                WInfoTone.info,
              _ => WInfoTone.error,
            },
            title: switch (phase) {
              VoiceSessionPhase.success => 'Execution result',
              VoiceSessionPhase.answered => 'Answer — nothing sent',
              VoiceSessionPhase.planned => 'Plan only',
              VoiceSessionPhase.cancelled => 'Cancelled',
              _ => 'Not executed',
            },
            message: _session.message!,
          ),
        if (_session.finalText != null)
          WCard(
            label: 'Recognized transcript',
            child: SelectableText(
              _session.finalText!,
              style: WalseyType.body.copyWith(fontSize: 16),
            ),
          ),
        if (planResult != null)
          _PlanCard(
            result: planResult,
            steps: _session.steps,
            execution: execution,
            executed: phase == VoiceSessionPhase.success,
            failed: phase == VoiceSessionPhase.failure && execution != null,
          ),
        if (_session.latency?.hasData ?? false)
          _LatencyCard(latency: _session.latency!),
        if (!widget.connected)
          const WInfoBanner(
            tone: WInfoTone.warning,
            title: 'No controller connected',
            message: 'Recognition and planning work offline. A plan that needs '
                'a device can scan/connect only after you allow Bluetooth, and '
                'lighting steps are written only to a supported LEDDMX '
                'controller.',
          ),
        _WakeWordCard(
          availability: _session.wakeWordAvailability,
          configured: _session.wakeWordConfigured,
          consent: widget.settings?.value.wakeWordEnabled ?? false,
          listening: _session.wakeListening,
          starting: _session.wakeStarting,
          capturing: _session.wakeCapturing,
          status: _session.wakeStatus,
          busy: phase.isBusy,
          onConsentChanged: widget.settings == null ? null : _setWakeConsent,
          onStart: _startWakeListening,
          onStop: _stopWakeListening,
        ),
        _EngineCard(
          engine: _engine,
          busy: phase.isBusy,
          modelLabel: modelLabel,
          modelError: _modelError,
          onEngineChanged: _switchEngine,
          onManageModels: _openModels,
        ),
        _TypedCard(
          controller: _typedController,
          suggestions: _suggestions,
          enabled: !phase.isBusy,
          onInterpret: _analyzeTyped,
        ),
        _HistoryCard(history: _history),
        const Text(
          'Whisper decodes the complete utterance after you release, so no '
          'live transcript is shown. Recognition, interpretation and execution '
          'are separate outcomes: a recognized sentence may still be rejected, '
          'and a BLE write is never proof that the LEDs changed.',
          style: WalseyType.caption,
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.result,
    required this.steps,
    required this.execution,
    required this.executed,
    required this.failed,
  });

  final VoicePlanResult result;
  final List<VoicePlanStepProgress> steps;
  final VoicePlanExecution? execution;
  final bool executed;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final tone = failed
        ? WBadgeTone.error
        : executed
            ? WBadgeTone.online
            : WBadgeTone.planned;
    final label = failed
        ? 'Execution failed'
        : executed
            ? 'Executed'
            : 'Planned — not executed';
    return WCard(
      label: 'Action plan',
      trailing: WBadge(label: label, tone: tone),
      child: switch (result) {
        VoicePlanFailure(:final explanation) => Text(
            explanation,
            style: WalseyType.body,
          ),
        VoicePlanReady(:final plan) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < plan.steps.length; index++)
                _PlanStepRow(
                  label: plan.steps[index].summary,
                  progress: index < steps.length ? steps[index] : null,
                  run: steps.isNotEmpty,
                  showDivider: index != plan.steps.length - 1,
                ),
              if (execution != null) ...[
                const SizedBox(height: WalseySpacing.md),
                Text(execution!.message, style: WalseyType.caption),
              ],
            ],
          ),
      },
    );
  }
}

class _PlanStepRow extends StatelessWidget {
  const _PlanStepRow({
    required this.label,
    required this.progress,
    required this.run,
    required this.showDivider,
  });

  final String label;
  final VoicePlanStepProgress? progress;
  final bool run;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final status = progress?.status ??
        (run ? VoicePlanStepStatus.pending : null);
    final color = switch (status) {
      VoicePlanStepStatus.done => WalseyColors.successText,
      VoicePlanStepStatus.skipped => WalseyColors.textMuted,
      VoicePlanStepStatus.failed => WalseyColors.errorText,
      VoicePlanStepStatus.running => WalseyColors.accentCyan,
      VoicePlanStepStatus.pending || null => WalseyColors.textSecondary,
    };
    final icon = switch (status) {
      VoicePlanStepStatus.done => Icons.check_circle_outline,
      VoicePlanStepStatus.skipped => Icons.remove_circle_outline,
      VoicePlanStepStatus.failed => Icons.error_outline,
      VoicePlanStepStatus.running => Icons.sync,
      VoicePlanStepStatus.pending || null => Icons.radio_button_unchecked,
    };
    final caption = progress?.detail ??
        (run ? 'Waiting for the previous step' : 'Not run');
    return WListRow(
      title: label,
      caption: caption,
      showDivider: showDivider,
      leading: Icon(icon, size: 18, color: color),
      trailing: WBadge(
        label: switch (status) {
          VoicePlanStepStatus.done => 'Done',
          VoicePlanStepStatus.skipped => 'Skipped',
          VoicePlanStepStatus.failed => 'Failed',
          VoicePlanStepStatus.running => 'Running',
          VoicePlanStepStatus.pending || null => 'Pending',
        },
        tone: switch (status) {
          VoicePlanStepStatus.done => WBadgeTone.online,
          VoicePlanStepStatus.skipped => WBadgeTone.offline,
          VoicePlanStepStatus.failed => WBadgeTone.error,
          VoicePlanStepStatus.running => WBadgeTone.connecting,
          VoicePlanStepStatus.pending || null => WBadgeTone.planned,
        },
      ),
    );
  }
}

class _LatencyCard extends StatelessWidget {
  const _LatencyCard({required this.latency});

  final VoiceLatency latency;

  @override
  Widget build(BuildContext context) => WCard(
        label: 'Measured latency (this session)',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in latency.rows)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: WalseySpacing.xxs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label, style: WalseyType.caption),
                    ),
                    Text(
                      value,
                      style: WalseyType.mono.copyWith(
                        color: WalseyColors.text,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: WalseySpacing.sm),
            const Text(
              'Measured on this device, not estimated. Whisper decodes the '
              'buffered take after release.',
              style: WalseyType.caption,
            ),
          ],
        ),
      );
}

class _WakeWordCard extends StatelessWidget {
  const _WakeWordCard({
    required this.availability,
    required this.configured,
    required this.consent,
    required this.listening,
    required this.starting,
    required this.capturing,
    required this.status,
    required this.busy,
    required this.onConsentChanged,
    required this.onStart,
    required this.onStop,
  });

  final WakeWordAvailability availability;
  final bool configured;
  final bool consent;
  final bool listening;
  final bool starting;
  final bool capturing;
  final String? status;
  final bool busy;
  final ValueChanged<bool>? onConsentChanged;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final active = listening || starting;
    final badge = active
        ? WBadge(
            label: capturing ? 'Capturing' : (starting ? 'Starting' : 'Listening'),
            tone: WBadgeTone.connecting,
          )
        : WBadge(
            label: configured ? 'Off' : 'Not installed',
            tone: WBadgeTone.offline,
          );

    return WCard(
      label: 'Hands-free ("Walsey")',
      trailing: badge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            configured
                ? 'Say "Walsey" and then a command. Recognition stays offline; '
                    'a short pre-roll buffer keeps the first words after the '
                    'wake phrase. Hold-to-talk and typed input keep working, '
                    'and every command still goes through the same parser and '
                    'the same BLE write path. Nothing is sent until a plan is '
                    'valid.'
                : availability.message,
            style: WalseyType.caption,
          ),
          if (configured) ...[
            const SizedBox(height: WalseySpacing.sm),
            WToggleRow(
              title: 'Allow hands-free listening',
              caption: 'Consent only — listening starts from the button below, '
                  'never at launch.',
              value: consent,
              onChanged: onConsentChanged,
            ),
            const SizedBox(height: WalseySpacing.xs),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: !consent || busy || starting
                      ? null
                      : (active ? null : onStart),
                  child: Text(starting ? 'Starting…' : 'Start listening'),
                ),
                const SizedBox(width: WalseySpacing.sm),
                OutlinedButton(
                  onPressed: active ? onStop : null,
                  child: const Text('Stop listening'),
                ),
              ],
            ),
            if (status != null) ...[
              const SizedBox(height: WalseySpacing.xs),
              Text(status!, style: WalseyType.caption),
            ],
            const SizedBox(height: WalseySpacing.xs),
            Text(
              'Android keeps listening in the background only through the '
              'visible microphone notification. Other platforms stop listening '
              'when the app leaves the foreground. If the language model is '
              'missing, the first command after a detection reports that '
              'honestly instead of executing anything.',
              style: WalseyType.caption,
            ),
          ],
        ],
      ),
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({
    required this.engine,
    required this.busy,
    required this.modelLabel,
    required this.modelError,
    required this.onEngineChanged,
    required this.onManageModels,
  });

  final _VoiceEngine engine;
  final bool busy;
  final String modelLabel;
  final String? modelError;
  final ValueChanged<_VoiceEngine?> onEngineChanged;
  final VoidCallback onManageModels;

  @override
  Widget build(BuildContext context) => WCard(
        label: 'Offline engine',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<_VoiceEngine>(
              segments: const [
                ButtonSegment(
                  value: _VoiceEngine.whisper,
                  label: Text('Whisper'),
                  icon: Icon(Icons.graphic_eq, size: 16),
                ),
                ButtonSegment(
                  value: _VoiceEngine.vosk,
                  label: Text('Vosk fallback'),
                  icon: Icon(Icons.swap_horiz, size: 16),
                ),
              ],
              selected: {engine},
              onSelectionChanged: busy
                  ? null
                  : (selection) => onEngineChanged(
                        selection.isEmpty ? null : selection.first,
                      ),
            ),
            const SizedBox(height: WalseySpacing.lg),
            Text(
              modelError ?? modelLabel,
              style: WalseyType.caption.copyWith(
                color: modelError == null
                    ? WalseyColors.textMuted
                    : WalseyColors.errorText,
              ),
            ),
            const SizedBox(height: WalseySpacing.sm),
            const Text(
              'Recognition is offline once a model is installed. Downloads only '
              'start from the model manager, never at startup.',
              style: WalseyType.caption,
            ),
            const SizedBox(height: WalseySpacing.lg),
            OutlinedButton.icon(
              onPressed: onManageModels,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Manage offline models'),
            ),
          ],
        ),
      );
}

class _TypedCard extends StatelessWidget {
  const _TypedCard({
    required this.controller,
    required this.suggestions,
    required this.enabled,
    required this.onInterpret,
  });

  final TextEditingController controller;
  final List<String> suggestions;
  final bool enabled;
  final ValueChanged<String> onInterpret;

  @override
  Widget build(BuildContext context) => WCard(
        label: 'Type instead',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    enabled: enabled,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Command sentence',
                      hintText: 'Set the color to blue',
                    ),
                    onSubmitted: onInterpret,
                  ),
                ),
                const SizedBox(width: WalseySpacing.sm),
                FilledButton.tonal(
                  onPressed:
                      enabled ? () => onInterpret(controller.text) : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: WalseyColors.surfaceRaised,
                    foregroundColor: WalseyColors.text,
                  ),
                  child: const Text('Interpret'),
                ),
              ],
            ),
            const SizedBox(height: WalseySpacing.lg),
            Wrap(
              spacing: WalseySpacing.sm,
              runSpacing: WalseySpacing.sm,
              children: [
                for (final suggestion in suggestions)
                  ActionChip(
                    label: Text(suggestion),
                    onPressed: enabled
                        ? () {
                            controller.text = suggestion;
                            onInterpret(suggestion);
                          }
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: WalseySpacing.md),
            const Text(
              'Typed commands use the same interpreter for inspection and are '
              'never executed. Use hold-to-talk for the execution path.',
              style: WalseyType.caption,
            ),
          ],
        ),
      );
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.history});

  final List<_HistoryItem> history;

  @override
  Widget build(BuildContext context) => WCard(
        label: 'Session history',
        child: history.isEmpty
            ? const Text(
                'No sessions yet. Recognitions, plans and their execution '
                'results appear here for this app session.',
                style: WalseyType.caption,
              )
            : Column(
                children: [
                  for (var index = 0; index < history.length; index++)
                    WListRow(
                      title: history[index].transcript,
                      caption: history[index].execution ??
                          history[index].interpretation,
                      showDivider: index != history.length - 1,
                      leading: Icon(
                        history[index].typed ? Icons.keyboard : Icons.mic_none,
                        size: 18,
                        color: history[index].success == null
                            ? WalseyColors.textMuted
                            : history[index].success!
                                ? WalseyColors.successText
                                : WalseyColors.errorText,
                      ),
                      trailing: WBadge(
                        label: history[index].typed
                            ? 'Typed'
                            : history[index].success == true
                                ? 'Executed'
                                : history[index].success == false
                                    ? 'Failed'
                                    : 'Planned',
                        tone: history[index].typed
                            ? WBadgeTone.offline
                            : history[index].success == true
                                ? WBadgeTone.online
                                : history[index].success == false
                                    ? WBadgeTone.error
                                    : WBadgeTone.planned,
                      ),
                    ),
                ],
              ),
      );
}

class _HistoryItem {
  _HistoryItem({
    required this.transcript,
    required this.interpretation,
    required this.typed,
    this.execution,
  });

  final String transcript;
  final String interpretation;
  final bool typed;
  String? execution;
  bool? success;
}

class _ModelDialog extends StatefulWidget {
  const _ModelDialog({required this.store});
  final ModelStore store;

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  final _installed = <String, bool>{};
  String? _busy;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final model in SpeechModel.all) {
      try {
        _installed[model.id] = await widget.store.isInstalled(model);
      } on Object catch (error) {
        _installed[model.id] = false;
        _error = 'Could not inspect installed models: $error';
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _install(SpeechModel model) async {
    setState(() {
      _busy = model.id;
      _error = null;
    });
    try {
      await widget.store.install(model);
      if (mounted) setState(() => _installed[model.id] = true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Offline models'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Downloads happen only when you press Install.',
                  style: WalseyType.caption,
                ),
                const SizedBox(height: WalseySpacing.sm),
                for (final model in SpeechModel.all)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(model.id),
                    subtitle: Text(
                      '${model.languageLabel} • '
                      '${model.archiveSizeMegabytes} MB',
                    ),
                    trailing: _busy == model.id
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : TextButton(
                            onPressed: _busy == null &&
                                    _installed[model.id] != true
                                ? () => _install(model)
                                : null,
                            child: Text(
                              _installed[model.id] == true
                                  ? 'Installed'
                                  : 'Install',
                            ),
                          ),
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: const TextStyle(color: WalseyColors.errorText),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
}
