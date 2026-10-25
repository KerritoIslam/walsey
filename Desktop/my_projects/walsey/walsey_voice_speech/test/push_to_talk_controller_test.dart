import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// In-memory recognizer: no microphone, no Vosk, no platform channel.
class FakeRecognizer implements SpeechRecognizer {
  final StreamController<SpeechRecognitionEvent> _events =
      StreamController<SpeechRecognitionEvent>.broadcast();

  SpeechAvailability availability = const SpeechReady();
  Object? initializeError;
  Object? startError;
  String? lastLanguageId;

  int initializeCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<SpeechAvailability> initialize({String? languageId}) async {
    initializeCalls++;
    lastLanguageId = languageId;
    final error = initializeError;
    if (error != null) {
      throw error;
    }
    return availability;
  }

  @override
  Future<void> start({String? languageId}) async {
    startCalls++;
    lastLanguageId = languageId;
    final error = startError;
    if (error != null) {
      throw error;
    }
    emit(const SpeechSessionStarted());
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _events.close();
  }

  void emit(SpeechRecognitionEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}

void main() {
  late FakeRecognizer recognizer;
  late PushToTalkController controller;

  setUp(() {
    recognizer = FakeRecognizer();
    controller = PushToTalkController(recognizer: recognizer);
  });

  tearDown(() {
    controller.dispose();
  });

  group('successful session', () {
    test('streams partial text and parses the final transcript', () async {
      await controller.startListening();
      await pumpEventQueue();

      expect(controller.status, PushToTalkStatus.listening);
      expect(recognizer.startCalls, 1);

      recognizer.emit(const SpeechPartialTranscript('set bright'));
      await pumpEventQueue();
      expect(controller.partialText, 'set bright');

      recognizer.emit(
        const SpeechFinalTranscript('set brightness to 50 percent'),
      );
      await pumpEventQueue();

      expect(controller.status, PushToTalkStatus.result);
      expect(controller.finalText, 'set brightness to 50 percent');
      expect(controller.partialText, isNull);
      expect(controller.interpretationSource, InterpretationSource.speech);

      final result = controller.interpretation;
      expect(result, isA<VoiceCommandResult>());
      final command = (result! as VoiceCommandResult).command;
      expect(command.intent, VoiceIntent.setBrightness);
      expect(command.actionId, 'setBrightness');
      expect(command.parameters.summary, contains('Brightness: 50%'));
      expect(result.executionStatus, VoiceExecutionStatus.notExecuted);
    });

    test(
      'recognized text goes through the same parser as typed text',
      () async {
        controller.analyzeTyped('Turn the lights blue.');
        final typed = controller.interpretation! as VoiceCommandResult;

        await controller.startListening();
        await pumpEventQueue();
        recognizer.emit(const SpeechFinalTranscript('Turn the lights blue.'));
        await pumpEventQueue();

        final spoken = controller.interpretation! as VoiceCommandResult;
        expect(spoken.command.intent, typed.command.intent);
        expect(
          spoken.command.parameters.summary,
          typed.command.parameters.summary,
        );
        expect(controller.interpretationSource, InterpretationSource.speech);
      },
    );

    test('unsupported speech stays an unsupported parser failure', () async {
      await controller.startListening();
      await pumpEventQueue();
      recognizer.emit(const SpeechFinalTranscript('tell me a joke'));
      await pumpEventQueue();

      final result = controller.interpretation;
      expect(result, isA<VoiceFailure>());
      final failure = result! as VoiceFailure;
      expect(failure.kind, VoiceFailureKind.unsupported);
      expect(result.executionStatus, VoiceExecutionStatus.notExecuted);
      expect(controller.status, PushToTalkStatus.result);
    });

    test('invalid spoken parameter is rejected, not clamped', () async {
      await controller.startListening();
      await pumpEventQueue();
      recognizer.emit(
        const SpeechFinalTranscript('set brightness to 150 percent'),
      );
      await pumpEventQueue();

      final failure = controller.interpretation! as VoiceFailure;
      expect(failure.kind, VoiceFailureKind.invalidParameter);
      expect(failure.explanation, contains('0..100'));
    });
  });

  group('session outcomes', () {
    test('empty result clears any previous transcript', () async {
      await controller.startListening();
      await pumpEventQueue();
      recognizer.emit(const SpeechFinalTranscript('turn the lights on'));
      await pumpEventQueue();
      expect(controller.finalText, isNotNull);

      await controller.startListening();
      await pumpEventQueue();
      expect(
        controller.finalText,
        isNull,
        reason: 'new session must not show old text',
      );

      recognizer.emit(const SpeechNoSpeechDetected());
      await pumpEventQueue();
      expect(controller.status, PushToTalkStatus.empty);
      expect(controller.finalText, isNull);
      expect(controller.interpretation, isNull);
    });

    test('cancellation discards late results', () async {
      await controller.startListening();
      await pumpEventQueue();

      await controller.cancel();
      await pumpEventQueue();

      expect(controller.status, PushToTalkStatus.cancelled);
      expect(recognizer.cancelCalls, 1);

      recognizer.emit(const SpeechFinalTranscript('turn the lights on'));
      await pumpEventQueue();
      expect(controller.finalText, isNull);
      expect(controller.interpretation, isNull);
      expect(controller.status, PushToTalkStatus.cancelled);
    });

    test('model required is an error with a model-specific kind', () async {
      recognizer.availability = const SpeechModelRequired(
        message: 'English (US) needs the small model.',
      );

      await controller.startListening();
      await pumpEventQueue();

      expect(controller.status, PushToTalkStatus.error);
      expect(controller.failureKind, SpeechFailureKind.modelNotInstalled);
      expect(controller.errorMessage, contains('small model'));
      expect(recognizer.startCalls, 0);
    });

    test('initialization failure is reported, not swallowed', () async {
      recognizer.initializeError = StateError('boom');

      await controller.startListening();
      await pumpEventQueue();

      expect(controller.status, PushToTalkStatus.error);
      expect(controller.failureKind, SpeechFailureKind.initializationFailed);
      expect(controller.errorMessage, contains('boom'));
    });

    test('recognition failure from the engine surfaces as an error', () async {
      await controller.startListening();
      await pumpEventQueue();

      recognizer.emit(
        const SpeechSessionFailed(
          kind: SpeechFailureKind.microphoneUnavailable,
          message: 'Microphone disappeared.',
        ),
      );
      await pumpEventQueue();

      expect(controller.status, PushToTalkStatus.error);
      expect(controller.failureKind, SpeechFailureKind.microphoneUnavailable);
      expect(controller.errorMessage, 'Microphone disappeared.');
    });

    test('stop publishes recognizing, then accepts the final event', () async {
      await controller.startListening();
      await pumpEventQueue();

      final stopping = controller.stopListening();
      expect(controller.status, PushToTalkStatus.recognizing);
      await stopping;
      expect(recognizer.stopCalls, 1);

      recognizer.emit(const SpeechFinalTranscript('turn the lights off'));
      await pumpEventQueue();
      expect(controller.status, PushToTalkStatus.result);
    });

    test('hung recognizer times out instead of staying stuck', () async {
      final local = FakeRecognizer();
      final fast = PushToTalkController(
        recognizer: local,
        recognitionTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(fast.dispose);

      await fast.startListening();
      await pumpEventQueue();
      await fast.stopListening();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fast.status, PushToTalkStatus.error);
      expect(fast.failureKind, SpeechFailureKind.recognitionFailed);
      expect(fast.errorMessage, contains('did not return a final result'));
    });
  });

  group('single session and retry', () {
    test('a second start while active does nothing', () async {
      await controller.startListening();
      await pumpEventQueue();

      await controller.startListening();
      await pumpEventQueue();

      expect(recognizer.startCalls, 1);
      expect(controller.status, PushToTalkStatus.listening);
    });

    test('retry after an error starts a fresh session', () async {
      recognizer.availability = const SpeechUnavailable(
        kind: SpeechFailureKind.permissionDenied,
        message: 'Denied.',
      );
      await controller.startListening();
      await pumpEventQueue();
      expect(controller.status, PushToTalkStatus.error);

      recognizer.availability = const SpeechReady();
      await controller.retry();
      await pumpEventQueue();

      expect(controller.status, PushToTalkStatus.listening);
      expect(controller.failureKind, isNull);
      expect(controller.errorMessage, isNull);
      expect(recognizer.startCalls, 1);
    });

    test('cannot retry while a session is active', () async {
      await controller.startListening();
      await pumpEventQueue();
      await controller.retry();
      expect(recognizer.startCalls, 1);
    });
  });

  group('typed workflow', () {
    test('typed analysis is separate from speech state', () async {
      expect(controller.analyzeTyped('Set brightness to 50 percent'), isTrue);

      expect(controller.status, PushToTalkStatus.idle);
      expect(controller.interpretationSource, InterpretationSource.typed);
      expect(controller.finalText, isNull);
      expect(controller.partialText, isNull);
      expect(controller.interpretation, isA<VoiceCommandResult>());
    });

    test('typed analysis is refused during a session', () async {
      await controller.startListening();
      await pumpEventQueue();
      expect(controller.analyzeTyped('turn the lights on'), isFalse);
      expect(controller.interpretation, isNull);
    });

    test('clear removes transcript, interpretation and error', () async {
      await controller.startListening();
      await pumpEventQueue();
      recognizer.emit(const SpeechFinalTranscript('turn the lights on'));
      await pumpEventQueue();
      expect(controller.interpretation, isNotNull);

      controller.clear();

      expect(controller.status, PushToTalkStatus.idle);
      expect(controller.finalText, isNull);
      expect(controller.interpretation, isNull);
    });
  });

  group('languages', () {
    test('selecting Algerian Darija disables the microphone honestly', () {
      expect(controller.selectLanguage(SpeechLanguage.algerianDarija), isTrue);

      expect(controller.canStart, isFalse);
      expect(controller.notice, contains('No Vosk model exists'));
    });

    test('language cannot change during a session', () async {
      await controller.startListening();
      await pumpEventQueue();

      expect(controller.selectLanguage(SpeechLanguage.french), isFalse);
      expect(controller.language.id, 'en-US');
    });
  });

  group('disposal', () {
    test('dispose releases the recognizer exactly once', () async {
      final local = FakeRecognizer();
      final localController = PushToTalkController(recognizer: local);
      await localController.startListening();
      await pumpEventQueue();

      localController.dispose();
      await pumpEventQueue();

      expect(local.disposeCalls, 1);
    });
  });
}
