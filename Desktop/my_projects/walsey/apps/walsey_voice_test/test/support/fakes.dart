import 'dart:async';
import 'dart:io';

import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// Deterministic recognizer for widget tests: no microphone, no Vosk, no
/// platform channel. Tests drive it with [emit].
class FakeSpeechRecognizer implements SpeechRecognizer {
  final StreamController<SpeechRecognitionEvent> _events =
      StreamController<SpeechRecognitionEvent>.broadcast();

  SpeechAvailability availability = const SpeechReady();
  Object? initializeError;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<SpeechAvailability> initialize({String? languageId}) async {
    final error = initializeError;
    if (error != null) {
      throw error;
    }
    return availability;
  }

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
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  void emit(SpeechRecognitionEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}

/// In-memory model store: no downloads and no file system.
class FakeModelStore extends ModelStore {
  FakeModelStore({this.installedFor = const {'en-US'}})
    : super(baseDirectory: () async => Directory.systemTemp);

  /// Language ids reported as installed.
  final Set<String> installedFor;

  @override
  Future<bool> isInstalled(SpeechModel model) async =>
      installedFor.contains(model.languageId);

  @override
  Future<String?> installedModelPath(SpeechModel model) async =>
      installedFor.contains(model.languageId) ? '/fake/models/${model.id}' : null;

  @override
  Future<Directory> modelsDirectory() async =>
      Directory('${Directory.systemTemp.path}${Platform.pathSeparator}fake_models');
}
