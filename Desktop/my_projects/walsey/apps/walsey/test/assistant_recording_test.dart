import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/connection/led_connection_service.dart';
import 'package:walsey/design/hold_to_talk_button.dart';
import 'package:walsey/design/theme.dart';
import 'package:walsey/features/assistant/assistant_page.dart';
import 'package:walsey/voice/voice_plan_executor.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'fakes.dart';

/// In-memory recognizer for the Assistant page integration tests.
///
/// It records what the app asked it to do (start/stop/cancel) and can model a
/// slow recorder open, a recorder that refuses to stop, and a recorder that
/// never answers at all. No microphone, model or platform channel is touched.
final class WidgetRecognizer implements SpeechRecognizer {
  final StreamController<SpeechRecognitionEvent> _events =
      StreamController<SpeechRecognitionEvent>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;

  /// True while the fake "microphone" is open.
  bool recording = false;

  /// Holds [start] open, modelling the recorder/model open delay.
  Completer<void>? startGate;

  /// When true, [stop] reports a recorder that could not be shut down.
  bool failStop = false;

  /// When true, [stop] never returns (a hung recorder).
  bool hangStop = false;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<SpeechAvailability> initialize({String? languageId}) async =>
      const SpeechReady();

  @override
  Future<void> start({String? languageId}) async {
    // Mirrors the real recognizer: a stop that arrives while the microphone is
    // still opening aborts the start instead of opening it afterwards.
    final stopsAtStart = stopCalls;
    startCalls++;
    final gate = startGate;
    if (gate != null) await gate.future;
    if (stopCalls > stopsAtStart) return;
    recording = true;
    emit(const SpeechSessionStarted());
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (hangStop) return Completer<void>().future;
    recording = false;
    if (failStop) {
      emit(
        const SpeechSessionFailed(
          kind: SpeechFailureKind.microphoneUnavailable,
          message: 'The microphone could not be stopped (recorder busy). '
              'No transcript was produced.',
        ),
      );
      return;
    }
    emit(const SpeechNoSpeechDetected());
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    recording = false;
    emit(const SpeechSessionCancelled());
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    recording = false;
    await _events.close();
  }

  void emit(SpeechRecognitionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

final class NoopExecutor implements CommandExecutor {
  @override
  void Function(List<VoicePlanStepProgress> steps)? onProgress;

  @override
  void cancel() {}

  @override
  Future<VoicePlanExecution> execute(VoicePlan plan) async =>
      const VoicePlanExecution(
        success: false,
        message: 'No controller is connected; nothing was sent.',
        steps: [],
      );
}

void main() {
  late LedConnectionService service;
  late WidgetRecognizer recognizer;

  Future<void> pumpAssistant(WidgetTester tester, {WidgetRecognizer? rec}) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    recognizer = rec ?? WidgetRecognizer();
    await tester.runAsync(() async {
      service = LedConnectionService(central: FakeCentral());
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildWalseyTheme(),
        home: Scaffold(
          body: AssistantPage(
            service: service,
            connected: false,
            compact: false,
            recognizer: recognizer,
            executor: NoopExecutor(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Pumps microtasks and a few frames without settling: the hold animation
  /// repeats while a take is active, so `pumpAndSettle` would never return.
  /// 12 × 20 ms also lets the 180 ms label transition finish.
  Future<void> frames(WidgetTester tester) async {
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> tearDownPage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(service.dispose);
  }

  Future<TestGesture> holdDown(
    WidgetTester tester, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToTalkButton)),
      kind: kind,
    );
    await frames(tester);
    return gesture;
  }

  testWidgets('mouse press and release starts and stops one take',
      (tester) async {
    await pumpAssistant(tester);

    final gesture = await holdDown(tester, kind: PointerDeviceKind.mouse);
    expect(recognizer.startCalls, 1);
    expect(recognizer.recording, isTrue);
    expect(find.text('Recording — release to decode'), findsOneWidget);

    await gesture.up();
    await frames(tester);

    expect(recognizer.stopCalls, 1);
    expect(recognizer.recording, isFalse);
    expect(find.text('Recording — release to decode'), findsNothing);
    expect(find.text('Hold to talk'), findsOneWidget);

    await tearDownPage(tester);
  });

  testWidgets('touch press and release stops the same way', (tester) async {
    await pumpAssistant(tester);

    final gesture = await holdDown(tester);
    expect(recognizer.startCalls, 1);
    expect(recognizer.recording, isTrue);

    await gesture.up();
    await frames(tester);

    expect(recognizer.stopCalls, 1);
    expect(recognizer.recording, isFalse);

    await tearDownPage(tester);
  });

  testWidgets('dragging outside the button and releasing still stops',
      (tester) async {
    await pumpAssistant(tester);

    final gesture = await holdDown(tester);
    expect(recognizer.recording, isTrue);

    await gesture.moveTo(const Offset(20, 20));
    await frames(tester);
    await gesture.moveTo(const Offset(400, 60));
    await frames(tester);
    expect(
      recognizer.recording,
      isTrue,
      reason: 'leaving the button must not cancel or stop the take',
    );

    await gesture.up();
    await frames(tester);

    expect(recognizer.stopCalls, 1);
    expect(recognizer.recording, isFalse);

    await tearDownPage(tester);
  });

  testWidgets('a pointer cancel cancels instead of leaving it recording',
      (tester) async {
    await pumpAssistant(tester);

    final gesture = await holdDown(tester);
    expect(recognizer.recording, isTrue);

    await gesture.cancel();
    await frames(tester);

    expect(recognizer.cancelCalls, 1);
    expect(recognizer.recording, isFalse);
    expect(find.text('Cancelled'), findsWidgets);

    await tearDownPage(tester);
  });

  testWidgets('a rapid press and release never leaves the mic open',
      (tester) async {
    await pumpAssistant(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToTalkButton)),
    );
    await gesture.up();
    await frames(tester);

    expect(recognizer.recording, isFalse);
    expect(recognizer.startCalls, lessThanOrEqualTo(1));
    expect(recognizer.stopCalls, lessThanOrEqualTo(1));
    expect(find.text('Recording — release to decode'), findsNothing);
    // The next take is possible again: the session did not stay busy.
    expect(find.text('Hold to talk'), findsOneWidget);

    await tearDownPage(tester);
  });

  testWidgets('a release during the recorder open still stops the take',
      (tester) async {
    final gated = WidgetRecognizer()..startGate = Completer<void>();
    await pumpAssistant(tester, rec: gated);

    final gesture = await holdDown(tester);
    expect(gated.startCalls, 1);
    expect(find.text('Starting…'), findsWidgets);

    // The user lets go before the recorder finished opening.
    await gesture.up();
    await frames(tester);
    expect(
      gated.stopCalls,
      1,
      reason: 'the release must reach the recognizer even mid-start',
    );

    gated.startGate!.complete();
    await frames(tester);

    expect(gated.recording, isFalse);
    expect(find.text('Recording — release to decode'), findsNothing);

    await tearDownPage(tester);
  });

  testWidgets('repeated takes each stop their own recorder', (tester) async {
    await pumpAssistant(tester);

    for (var take = 1; take <= 2; take++) {
      final gesture = await holdDown(tester);
      expect(recognizer.startCalls, take);
      expect(recognizer.recording, isTrue);

      await gesture.up();
      await frames(tester);

      expect(recognizer.stopCalls, take);
      expect(recognizer.recording, isFalse);
      expect(find.text('Hold to talk'), findsOneWidget);
    }

    await tearDownPage(tester);
  });

  testWidgets('leaving the page while recording cancels the take',
      (tester) async {
    await pumpAssistant(tester);

    await holdDown(tester);
    expect(recognizer.recording, isTrue);

    // Navigation away disposes the Assistant page.
    await tearDownPage(tester);

    expect(recognizer.cancelCalls, greaterThanOrEqualTo(1));
    expect(recognizer.recording, isFalse);
    expect(recognizer.disposeCalls, 1);
  });

  testWidgets('an app lifecycle change while recording cancels the take',
      (tester) async {
    await pumpAssistant(tester);

    final gesture = await holdDown(tester);
    expect(recognizer.recording, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await frames(tester);

    expect(recognizer.cancelCalls, 1);
    expect(recognizer.recording, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await gesture.up();
    await frames(tester);
    await tearDownPage(tester);
  });

  testWidgets('a recorder that cannot stop shows a visible error',
      (tester) async {
    final failing = WidgetRecognizer()..failStop = true;
    await pumpAssistant(tester, rec: failing);

    final gesture = await holdDown(tester);
    await gesture.up();
    await frames(tester);

    expect(failing.recording, isFalse);
    expect(failing.stopCalls, 1);
    expect(find.textContaining('could not be stopped'), findsOneWidget);
    expect(find.text('Not executed'), findsWidgets);

    await tearDownPage(tester);
  });

  testWidgets('a recorder that never confirms the stop times out visibly',
      (tester) async {
    final hung = WidgetRecognizer()..hangStop = true;
    await pumpAssistant(tester, rec: hung);

    final gesture = await holdDown(tester);
    await gesture.up();
    await frames(tester);

    expect(hung.stopCalls, 1);
    // Still transcribing; the app has not pretended the take is done.
    expect(find.text('Transcribing…'), findsWidgets);

    // PushToTalkController's recognition timeout is 20 s by default.
    await tester.pump(const Duration(seconds: 21));
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.textContaining('did not return a final result'), findsOneWidget);

    await tearDownPage(tester);
  });

  testWidgets('without a wake pipeline the card is honest, not a fake control',
      (tester) async {
    await pumpAssistant(tester);

    // The page must scroll to the card on a phone-sized surface, so search the
    // whole tree instead of assuming it is visible.
    expect(
      find.textContaining('ONNX scoring backend'),
      findsOneWidget,
      reason: 'the missing model/backend is named explicitly',
    );
    expect(
      find.textContaining('never listens in the background'),
      findsOneWidget,
    );
    // No consent switch and no start button: they would imply the feature works.
    expect(find.text('Start listening'), findsNothing);
    expect(find.text('Stop listening'), findsNothing);
    expect(find.text('Allow hands-free listening'), findsNothing);

    await tearDownPage(tester);
  });
}
