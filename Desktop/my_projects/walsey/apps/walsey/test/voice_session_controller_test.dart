import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/voice/voice_plan_executor.dart';
import 'package:walsey/voice/voice_response_speaker.dart';
import 'package:walsey/voice/voice_session_controller.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

/// In-memory recognizer: no microphone, no model, no platform channel.
class FakeRecognizer implements SpeechRecognizer {
  final StreamController<SpeechRecognitionEvent> _events =
      StreamController<SpeechRecognitionEvent>.broadcast();

  SpeechAvailability availability = const SpeechReady();
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  /// When set, [start] waits for it before reporting that the session started,
  /// which models a slow permission/model/recorder open.
  Completer<void>? startGate;

  /// When set, [stop] waits for it before returning. Completing it models a
  /// recorder that acknowledges the stop; leaving it pending models a hung one.
  Completer<void>? stopGate;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<SpeechAvailability> initialize({String? languageId}) async =>
      availability;

  @override
  Future<void> start({String? languageId}) async {
    startCalls++;
    final gate = startGate;
    if (gate != null) await gate.future;
    emit(const SpeechSessionStarted());
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final gate = stopGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }

  void emit(SpeechRecognitionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// Records the plan it was given and returns a real-shaped result.
final class FakeExecutor implements CommandExecutor {
  FakeExecutor({
    this.success = true,
    this.message = 'Plan completed. 1 BLE write succeeded; the LED response is '
        'not confirmed by the protocol.',
    this.delay = Duration.zero,
    this.wroteNothing = false,
  });

  bool success;
  String message;
  Duration delay;

  /// Mirrors the real executor's flag for a plan that wrote no frames.
  bool wroteNothing;

  final List<VoicePlan> plans = [];
  int cancelCalls = 0;
  bool _cancelled = false;

  @override
  void Function(List<VoicePlanStepProgress> steps)? onProgress;

  @override
  void cancel() {
    cancelCalls++;
    _cancelled = true;
  }

  @override
  Future<VoicePlanExecution> execute(VoicePlan plan) async {
    plans.add(plan);
    final steps = [
      for (var index = 0; index < plan.steps.length; index++)
        VoicePlanStepProgress(
          index: index,
          label: plan.steps[index].summary,
          status: VoicePlanStepStatus.pending,
        ),
    ];
    onProgress?.call(List.of(steps));
    if (steps.isNotEmpty) {
      steps[0] = steps[0].copyWith(
        status: VoicePlanStepStatus.running,
      );
      onProgress?.call(List.of(steps));
    }
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (_cancelled) {
      if (steps.isNotEmpty) {
        steps[0] = steps[0].copyWith(status: VoicePlanStepStatus.failed);
      }
      onProgress?.call(List.of(steps));
      return VoicePlanExecution(
        success: false,
        message: 'The plan was cancelled before step 2.',
        steps: List.unmodifiable(steps),
      );
    }
    if (steps.isNotEmpty && success) {
      steps[0] = steps[0].copyWith(
        status: VoicePlanStepStatus.done,
        detail: 'BLE write completed; the LED response is not confirmed.',
      );
    } else if (steps.isNotEmpty) {
      steps[0] = steps[0].copyWith(
        status: VoicePlanStepStatus.failed,
        detail: message,
      );
    }
    onProgress?.call(List.of(steps));
    return VoicePlanExecution(
      success: success,
      message: message,
      steps: List.unmodifiable(steps),
      wroteNothing: wroteNothing,
    );
  }
}

/// TTS engine whose [stop] can be held open: the pointer can go up while the
/// previous spoken response is still being silenced, which is the exact window
/// in which a real take used to be lost.
final class GatedTts implements TtsEngine {
  GatedTts({this.stopGate});

  final Completer<void>? stopGate;
  int speakCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> speak(String text) async => speakCalls++;

  @override
  Future<void> stop() async {
    stopCalls++;
    final gate = stopGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> dispose() async => disposeCalls++;
}

final class FakeWakeWordDetector implements WakeWordDetector {
  int prepareCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  @override
  String get engineName => 'fake';

  @override
  Stream<WakeWordEvent> get events => const Stream<WakeWordEvent>.empty();

  @override
  Future<WakeWordAvailability> prepare() async {
    prepareCalls++;
    return const WakeWordAvailability(
      capability: WakeWordCapability.available,
      message: 'Prepared but never started.',
    );
  }

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

void main() {
  late FakeRecognizer recognizer;
  late FakeExecutor executor;
  late VoiceSessionController controller;
  late List<String> logs;

  void build({
    FakeWakeWordDetector? wakeWord,
    VoiceResponseSpeaker? speaker,
    Duration holdWatchdogDelay = const Duration(seconds: 2),
    Duration maxHoldDuration = const Duration(seconds: 60),
  }) {
    controller = VoiceSessionController(
      recognizer: recognizer,
      interpreter: VoicePlanParser(),
      executor: executor,
      wakeWordDetector: wakeWord,
      speaker: speaker,
      holdWatchdogDelay: holdWatchdogDelay,
      maxHoldDuration: maxHoldDuration,
      onLog: logs.add,
    );
  }

  setUp(() {
    recognizer = FakeRecognizer();
    executor = FakeExecutor();
    logs = <String>[];
    build();
  });

  /// Disposes the current controller and starts a fresh one with its own
  /// recognizer/executor (disposal closes a fake recognizer's event stream).
  void rebuild({
    VoiceResponseSpeaker? speaker,
    Duration holdWatchdogDelay = const Duration(seconds: 2),
    Duration maxHoldDuration = const Duration(seconds: 60),
  }) {
    controller.dispose();
    recognizer = FakeRecognizer();
    executor = FakeExecutor();
    build(
      speaker: speaker,
      holdWatchdogDelay: holdWatchdogDelay,
      maxHoldDuration: maxHoldDuration,
    );
  }

  tearDown(() {
    controller.dispose();
  });

  /// Press, release and deliver a final transcript, then let the pipeline run.
  Future<void> speak(String transcript) async {
    await controller.press();
    await pumpEventQueue();
    await controller.release();
    expect(controller.phase, VoiceSessionPhase.processing);
    recognizer.emit(SpeechFinalTranscript(transcript));
    await pumpEventQueue();
    await pumpEventQueue();
  }

  test('press starts exactly one session; a second press is ignored', () async {
    await controller.press();
    await controller.press();
    await pumpEventQueue();

    expect(recognizer.startCalls, 1);
    expect(controller.phase, VoiceSessionPhase.recording);
    expect(controller.isPressed, isTrue);
  });

  test('release stops the take and executes a valid single command', () async {
    await speak('turn the lights on');

    expect(recognizer.stopCalls, 1);
    expect(executor.plans, hasLength(1));
    expect(executor.plans.single.steps.single, isA<SetPowerStep>());
    expect(controller.phase, VoiceSessionPhase.success);
    expect(controller.steps.single.status, VoicePlanStepStatus.done);
    expect(controller.message, contains('not confirmed'));
  });

  test('a compound sentence becomes an ordered plan', () async {
    await speak('scan for devices and turn the first one on');

    expect(executor.plans, hasLength(1));
    expect(
      executor.plans.single.steps.map((step) => step.runtimeType),
      [
        ScanDevicesStep,
        SelectDeviceStep,
        ConnectDeviceStep,
        SetPowerStep,
      ],
    );
    expect(controller.phase, VoiceSessionPhase.success);
  });

  test('a status question is answered, never labelled executed', () async {
    executor.wroteNothing = true;
    executor.message = 'Nothing was sent. The controller protocol cannot report '
        'its current state, so the LED state is unknown.';

    await speak('are the lights on');

    expect(executor.plans, hasLength(1));
    expect(executor.plans.single.steps.single, isA<QueryStatusStep>());
    expect(controller.phase, VoiceSessionPhase.answered);
    expect(controller.phase.label, contains('nothing sent'));
    expect(controller.message, contains('Nothing was sent'));
    expect(controller.canStart, isTrue);
  });

  test('a parser failure never reaches the executor', () async {
    await speak('tell me a joke');

    expect(executor.plans, isEmpty);
    expect(controller.phase, VoiceSessionPhase.failure);
    expect(controller.message, contains('question'));
  });

  test('no speech is reported, not executed', () async {
    await controller.press();
    await pumpEventQueue();
    await controller.release();
    recognizer.emit(const SpeechNoSpeechDetected());
    await pumpEventQueue();

    expect(executor.plans, isEmpty);
    expect(controller.phase, VoiceSessionPhase.failure);
    expect(controller.message, contains('No speech'));
  });

  test('permission denial fails honestly and sends nothing', () async {
    recognizer.availability = const SpeechUnavailable(
      kind: SpeechFailureKind.permissionDenied,
      message: 'Microphone permission was denied.',
    );
    await controller.press();
    await pumpEventQueue();

    expect(controller.phase, VoiceSessionPhase.failure);
    expect(controller.message, contains('permission'));
    expect(executor.plans, isEmpty);
    expect(controller.canStart, isTrue);
  });

  test('release after a failed start does not start a second session', () async {
    recognizer.availability = const SpeechUnavailable(
      kind: SpeechFailureKind.microphoneUnavailable,
      message: 'No microphone.',
    );
    await controller.press();
    await pumpEventQueue();
    await controller.release();
    await pumpEventQueue();

    expect(recognizer.startCalls, 0);
    expect(executor.plans, isEmpty);
  });

  test('typed text is interpreted but never executed', () async {
    final result = controller.interpretTyped('turn the lights on');

    expect(result, isA<VoicePlanReady>());
    expect(executor.plans, isEmpty);
    expect(controller.phase, VoiceSessionPhase.planned);
  });

  test('typed compound text is planned, not run', () async {
    controller.interpretTyped('scan for devices and turn the first one on');

    expect(executor.plans, isEmpty);
    expect(controller.phase, VoiceSessionPhase.planned);
    expect(controller.planResult, isA<VoicePlanReady>());
  });

  test('cancelling a running plan wins over the late executor result',
      () async {
    executor.delay = const Duration(milliseconds: 40);
    await controller.press();
    await pumpEventQueue();
    await controller.release();
    recognizer.emit(const SpeechFinalTranscript('turn the lights on'));
    await pumpEventQueue();
    expect(controller.phase, VoiceSessionPhase.executing);

    await controller.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(executor.cancelCalls, 1);
    expect(controller.phase, VoiceSessionPhase.cancelled);
    expect(controller.message, contains('cancelled'));
  });

  test('a detector alone never starts and does not enable hands-free',
      () async {
    final detector = FakeWakeWordDetector();
    controller.dispose();
    recognizer = FakeRecognizer();
    executor = FakeExecutor();
    build(wakeWord: detector);

    await speak('turn the lights on');

    expect(detector.startCalls, 0);
    expect(detector.prepareCalls, 0);
    // Injecting the port is not enough: hands-free listening needs the full
    // wake pipeline (detector + buffered recognizer + pre-roll loop).
    expect(controller.wakeWordConfigured, isFalse);
    expect(
      controller.wakeWordAvailability.message,
      contains('wake-word model'),
    );
    expect(await controller.startWakeListening(), isFalse);
    expect(detector.startCalls, 0);
  });

  test('without a detector the wake-word path stays not configured', () {
    expect(controller.wakeWordConfigured, isFalse);
    expect(
      controller.wakeWordAvailability.capability,
      WakeWordCapability.notConfigured,
    );
  });

  test('diagnostics separate recognition, interpretation and execution',
      () async {
    await speak('turn the lights on');

    expect(controller.phase, VoiceSessionPhase.success);
    expect(
      logs.any(
        (line) =>
            line == 'VOICE RECOGNIZED: transcript="turn the lights on"',
      ),
      isTrue,
      reason: logs.join('\n'),
    );
    expect(
      logs.any(
        (line) =>
            line.contains('VOICE INTERPRETED: plan with 1 step') &&
            line.contains('Turn the LED on'),
      ),
      isTrue,
    );
    expect(
      logs.any((line) => line.contains('ACTION STARTED: executing 1 step')),
      isTrue,
    );
    expect(
      logs.any((line) => line.contains('PLAN RESULT: success')),
      isTrue,
    );
    // The fake executor performs no BLE write, so no write may be logged.
    expect(logs.any((line) => line.contains('BLE WRITE OK')), isFalse);
  });

  test('a rejected sentence is logged as interpretation only', () async {
    await speak('open the garage door');

    expect(controller.phase, VoiceSessionPhase.failure);
    expect(executor.plans, isEmpty);
    expect(
      logs.any(
        (line) =>
            line.contains('VOICE INTERPRETED: rejected') &&
            line.contains('nothing was executed'),
      ),
      isTrue,
      reason: logs.join('\n'),
    );
    expect(logs.any((line) => line.contains('ACTION STARTED')), isFalse);
    expect(logs.any((line) => line.contains('PLAN RESULT')), isFalse);
  });

  test('an empty take is logged as no recognition, never interpreted',
      () async {
    await controller.press();
    await pumpEventQueue();
    await controller.release();
    recognizer.emit(const SpeechNoSpeechDetected());
    await pumpEventQueue();

    expect(controller.phase, VoiceSessionPhase.failure);
    expect(executor.plans, isEmpty);
    expect(
      logs.any((line) => line.startsWith('VOICE RECOGNIZED: none')),
      isTrue,
      reason: logs.join('\n'),
    );
    expect(logs.any((line) => line.contains('VOICE INTERPRETED')), isFalse);
  });

  test('typed text is logged as interpreted, never as recognized', () {
    controller.interpretTyped('set the color to blue');

    expect(controller.phase, VoiceSessionPhase.planned);
    expect(
      logs.any(
        (line) => line.startsWith(
          'VOICE INTERPRETED (typed, not executed): plan with 1 step',
        ),
      ),
      isTrue,
    );
    expect(logs.any((line) => line.contains('VOICE RECOGNIZED')), isFalse);
    expect(executor.plans, isEmpty);
  });

  // ---------------------------------------------------------------------------
  // Release/start races and the hold watchdog (Priority 0)
  // ---------------------------------------------------------------------------

  group('release races the recognizer start', () {
    test('a release while the microphone opens still stops the take', () async {
      recognizer.startGate = Completer<void>();
      final pressFuture = controller.press();
      await pumpEventQueue();

      expect(recognizer.startCalls, 1);
      expect(controller.phase, VoiceSessionPhase.pressing);

      await controller.release();
      expect(
        recognizer.stopCalls,
        1,
        reason: 'the release must reach the recognizer, not be dropped',
      );

      recognizer.startGate!.complete();
      await pressFuture;
      await pumpEventQueue();

      expect(controller.isPressed, isFalse);
      expect(controller.phase, isNot(VoiceSessionPhase.recording));
      expect(controller.phase, isNot(VoiceSessionPhase.pressing));
      expect(executor.plans, isEmpty);
    });

    test('a release before the recognizer is asked keeps the mic closed',
        () async {
      final gate = Completer<void>();
      final speaker = VoiceResponseSpeaker(
        engine: GatedTts(stopGate: gate),
        enabled: true,
      );
      rebuild(speaker: speaker);

      final pressFuture = controller.press();
      await pumpEventQueue();
      expect(recognizer.startCalls, 0, reason: 'echo suppression is pending');

      await controller.release();
      gate.complete();
      await pressFuture;
      await pumpEventQueue();

      expect(
        recognizer.startCalls,
        0,
        reason: 'an aborted press must never open the microphone afterwards',
      );
      expect(recognizer.stopCalls, 0);
      expect(controller.phase, VoiceSessionPhase.cancelled);
      expect(
        logs.any((line) => line.contains('released before the microphone')),
        isTrue,
        reason: logs.join('\n'),
      );
    });

    test('a recorder that cannot be stopped is reported, never hidden',
        () async {
      await controller.press();
      await pumpEventQueue();
      await controller.release();

      recognizer.emit(
        const SpeechSessionFailed(
          kind: SpeechFailureKind.microphoneUnavailable,
          message: 'The microphone could not be stopped (recorder busy). '
              'No transcript was produced.',
        ),
      );
      await pumpEventQueue();

      expect(controller.phase, VoiceSessionPhase.failure);
      expect(controller.message, contains('could not be stopped'));
      expect(executor.plans, isEmpty);
    });

    test('repeated takes each ask for their own stop', () async {
      await speak('turn the lights on');
      await speak('turn the lights off');

      expect(recognizer.startCalls, 2);
      expect(recognizer.stopCalls, 2);
      expect(executor.plans, hasLength(2));
    });
  });

  group('hold watchdog', () {
    test('a hold whose release was never seen is stopped automatically',
        () async {
      rebuild(
        holdWatchdogDelay: const Duration(milliseconds: 10),
        maxHoldDuration: const Duration(milliseconds: 100),
      );

      await controller.press();
      await pumpEventQueue();
      expect(controller.phase, VoiceSessionPhase.recording);

      // Still genuinely held: the watchdog must not cut a live take short.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(recognizer.stopCalls, 0);

      // The pointer-up never reached the app.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await pumpEventQueue();

      expect(recognizer.stopCalls, 1);
      expect(controller.phase, VoiceSessionPhase.processing);
      expect(
        logs.any((line) => line.contains('maximum hold')),
        isTrue,
        reason: logs.join('\n'),
      );
    });

    test('a normal release wins long before the watchdog', () async {
      rebuild(
        holdWatchdogDelay: const Duration(milliseconds: 10),
        maxHoldDuration: const Duration(milliseconds: 100),
      );

      await controller.press();
      await pumpEventQueue();
      await controller.release();

      await Future<void>.delayed(const Duration(milliseconds: 150));
      await pumpEventQueue();

      expect(recognizer.stopCalls, 1, reason: 'stopped exactly once');
    });
  });
}
