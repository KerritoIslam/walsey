import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/voice/voice_plan_executor.dart';
import 'package:walsey/voice/voice_session_controller.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// In-memory recognizer: no microphone, no model, no platform channel.
final class _FakeRecognizer implements SpeechRecognizer {
  final StreamController<SpeechRecognitionEvent> _events =
      StreamController<SpeechRecognitionEvent>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<SpeechAvailability> initialize({String? languageId}) async =>
      const SpeechReady();

  @override
  Future<void> start({String? languageId}) async {
    startCalls++;
    emit(const SpeechSessionStarted());
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }

  void emit(SpeechRecognitionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// Records the plan it was given, like the real executor's seam.
final class _FakeExecutor implements CommandExecutor {
  final List<VoicePlan> plans = [];

  @override
  void Function(List<VoicePlanStepProgress> steps)? onProgress;

  @override
  void cancel() {}

  @override
  Future<VoicePlanExecution> execute(VoicePlan plan) async {
    plans.add(plan);
    return VoicePlanExecution(
      success: true,
      message: 'Plan completed. ${plan.steps.length} step(s).',
      steps: const [],
    );
  }
}

/// In-memory hands-free source: no microphone, no model, no scoring.
final class _FakeWakeSource implements WakeCommandSource {
  final StreamController<WakeCommandEvent> _events =
      StreamController<WakeCommandEvent>.broadcast();

  final List<String> log = [];
  WakeWordAvailability availability = const WakeWordAvailability(
    capability: WakeWordCapability.available,
    message: 'Fake wake source ready.',
  );
  Object? startError;
  int startCalls = 0;
  int stopCalls = 0;
  int prewarmCalls = 0;
  int disposeCalls = 0;
  bool _capturing = false;

  @override
  Stream<WakeCommandEvent> get events => _events.stream;

  @override
  bool get isCapturing => _capturing;

  @override
  Future<WakeWordAvailability> prewarm() async {
    prewarmCalls++;
    log.add('prewarm');
    return availability;
  }

  @override
  Future<void> start() async {
    startCalls++;
    log.add('start');
    final error = startError;
    if (error != null) throw error;
    _events.add(const WakeListening());
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    log.add('stop');
    _capturing = false;
    if (!_events.isClosed) _events.add(const WakeStopped());
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (!_events.isClosed) await _events.close();
  }

  void emit(WakeCommandEvent event) {
    _capturing = event is WakeCapturing;
    if (!_events.isClosed) _events.add(event);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _FakeRecognizer recognizer;
  late _FakeExecutor executor;
  late _FakeWakeSource wake;
  late VoiceSessionController controller;
  late List<String> logs;

  void build({_FakeWakeSource? source}) {
    logs = [];
    controller = VoiceSessionController(
      recognizer: recognizer,
      interpreter: VoicePlanParser(),
      executor: executor,
      wakeCommandLoop: source,
      onLog: logs.add,
    );
  }

  setUp(() {
    recognizer = _FakeRecognizer();
    executor = _FakeExecutor();
    wake = _FakeWakeSource();
    build(source: wake);
  });

  tearDown(() {
    controller.dispose();
    recognizer.dispose();
  });

  test('prewarm never starts the microphone', () async {
    final availability = await controller.prewarmWakeWord();

    expect(availability.capability, WakeWordCapability.available);
    expect(wake.prewarmCalls, 1);
    expect(wake.startCalls, 0);
    expect(controller.wakeListening, isFalse);
  });

  test('listening starts only from the explicit call', () async {
    expect(controller.wakeListening, isFalse);

    final started = await controller.startWakeListening();
    await _settle();

    expect(started, isTrue);
    expect(wake.startCalls, 1);
    expect(controller.wakeListening, isTrue);
    expect(controller.wakeStatus, contains('Listening'));
    expect(logs.any((l) => l.startsWith('WAKE WORD:')), isTrue);
  });

  test('stopping releases the microphone', () async {
    await controller.startWakeListening();
    await _settle();

    await controller.stopWakeListening();
    await _settle();

    expect(wake.stopCalls, 1);
    expect(controller.wakeListening, isFalse);
    expect(controller.wakeStatus, contains('off'));
  });

  test('a hold stops hands-free listening before the recorder opens', () async {
    await controller.startWakeListening();
    await _settle();
    expect(wake.startCalls, 1);

    await controller.press();
    await _settle();

    expect(wake.stopCalls, greaterThanOrEqualTo(1));
    expect(controller.wakeListening, isFalse);
    expect(recognizer.startCalls, 1);
    expect(controller.phase, VoiceSessionPhase.recording);

    await controller.release();
  });

  test('a wake transcript uses the same parser and executor', () async {
    await controller.startWakeListening();
    await _settle();

    wake.emit(const WakeDetected());
    wake.emit(const WakeCapturing());
    wake.emit(const WakeTranscript('turn the lights on'));
    await _settle();

    expect(executor.plans, hasLength(1));
    expect(
      executor.plans.single.steps.whereType<SetPowerStep>(),
      hasLength(1),
    );
    expect(
      logs.any((l) => l.contains('VOICE RECOGNIZED') && l.contains('hands-free')),
      isTrue,
    );
    expect(controller.phase, VoiceSessionPhase.success);
  });

  test('hands-free listening resumes after a hold-to-talk take', () async {
    await controller.startWakeListening();
    await _settle();
    expect(wake.startCalls, 1);

    await controller.press();
    await _settle();
    await controller.release();
    recognizer.emit(const SpeechFinalTranscript('turn the lights on'));
    await _settle();
    await _settle();

    expect(controller.phase, VoiceSessionPhase.success);
    expect(wake.startCalls, 2, reason: 'listening resumes after the take');
    expect(controller.wakeListening, isTrue);
  });

  test('a wake transcript that fails to parse never executes', () async {
    await controller.startWakeListening();
    await _settle();

    wake.emit(const WakeTranscript('the weather is nice today'));
    await _settle();

    expect(executor.plans, isEmpty);
    expect(controller.phase, VoiceSessionPhase.failure);
  });

  test('an empty hands-free take is reported, not executed', () async {
    await controller.startWakeListening();
    await _settle();

    wake.emit(const WakeEmpty('No audio was captured after the wake word.'));
    await _settle();

    expect(executor.plans, isEmpty);
    expect(controller.wakeStatus, contains('No audio'));
    expect(logs.any((l) => l.contains('none (hands-free)')), isTrue);
  });

  test('a wake failure clears listening and does not auto-restart', () async {
    await controller.startWakeListening();
    await _settle();

    wake.emit(const WakeFailed('The detector stopped.'));
    await _settle();

    expect(controller.wakeListening, isFalse);
    expect(wake.startCalls, 1);
    expect(controller.phase, isNot(VoiceSessionPhase.executing));
  });

  test('a failed start is reported honestly', () async {
    wake.startError = StateError('no model');

    final started = await controller.startWakeListening();
    await _settle();

    expect(started, isFalse);
    expect(controller.wakeListening, isFalse);
    expect(controller.wakeStatus, contains('could not start'));
    expect(wake.startCalls, 1);
  });

  test('without a source the feature is honestly unavailable', () async {
    controller.dispose();
    build();

    final started = await controller.startWakeListening();

    expect(started, isFalse);
    expect(controller.wakeWordConfigured, isFalse);
    expect(controller.wakeStatus, contains('not available'));
  });
}
