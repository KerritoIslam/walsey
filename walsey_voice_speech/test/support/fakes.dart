import 'dart:async';
import 'dart:typed_data';

import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// In-memory [SpeechEngine] shared by the recognizer tests. Never touches a
/// native library, a microphone or the network.
class FakeEngine implements SpeechEngine {
  final StreamController<SpeechEngineEvent> _events =
      StreamController<SpeechEngineEvent>.broadcast();

  String? loadedPath;
  Object? loadError;
  String? finalText = 'set brightness to 50 percent';
  int sessions = 0;
  int resets = 0;
  bool disposed = false;
  List<String>? requestedGrammar;
  final List<Uint8List> chunks = [];

  @override
  Stream<SpeechEngineEvent> get events => _events.stream;

  @override
  Future<void> loadModel(String modelPath) async {
    final error = loadError;
    if (error != null) {
      throw error;
    }
    loadedPath = modelPath;
  }

  @override
  Future<void> beginSession({
    required int sampleRate,
    List<String>? grammar,
  }) async {
    sessions++;
    requestedGrammar = grammar;
  }

  @override
  void accept(Uint8List pcm) => chunks.add(pcm);

  @override
  Future<String?> finish() async => finalText;

  @override
  Future<void> reset() async {
    resets++;
    finalText = null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }

  void emit(SpeechEngineEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}

/// In-memory [AudioCapture] shared by the recognizer tests.
class FakeCapture implements AudioCapture {
  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast();

  bool permission = true;
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  int? requestedSampleRate;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<Uint8List>> startStream({required int sampleRate}) async {
    starts++;
    requestedSampleRate = sampleRate;
    return _chunks.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await _chunks.close();
  }

  void add(Uint8List chunk) => _chunks.add(chunk);
}

/// Behaves like a real recorder on shutdown: the platform emits one final
/// buffer inside `stop()` and only then closes the stream.
class TailCapture implements AudioCapture {
  final StreamController<Uint8List> _chunks = StreamController<Uint8List>();
  bool started = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> startStream({required int sampleRate}) async {
    started = true;
    return _chunks.stream;
  }

  @override
  Future<void> stop() async {
    if (!started || _chunks.isClosed) {
      return;
    }
    _chunks.add(Uint8List.fromList(const [7, 7]));
    await _chunks.close();
  }

  @override
  Future<void> dispose() async {
    if (!_chunks.isClosed) {
      await _chunks.close();
    }
  }

  void add(Uint8List chunk) => _chunks.add(chunk);
}

/// Capture whose permission check and stream open can be held open by a
/// [Completer], so tests can release the button while the microphone is still
/// starting — the exact window in which a real take used to be left recording.
///
/// [recording] models the platform fact the unit tests care about: the recorder
/// is capturing between a successful `startStream` and `stop`.
class GatedCapture implements AudioCapture {
  GatedCapture({
    this.permissionGate,
    this.startGate,
    this.stopGate,
  });

  final Completer<void>? permissionGate;
  final Completer<void>? startGate;
  Completer<void>? stopGate;

  final StreamController<Uint8List> _chunks =
      StreamController<Uint8List>.broadcast();

  bool permission = true;
  Object? stopError;
  bool recording = false;
  int permissionChecks = 0;
  int startCalls = 0;
  int stops = 0;
  int disposals = 0;

  @override
  Future<bool> hasPermission() async {
    permissionChecks++;
    final gate = permissionGate;
    if (gate != null) await gate.future;
    return permission;
  }

  @override
  Future<Stream<Uint8List>> startStream({required int sampleRate}) async {
    startCalls++;
    final gate = startGate;
    if (gate != null) await gate.future;
    recording = true;
    return _chunks.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    recording = false;
    final gate = stopGate;
    if (gate != null) await gate.future;
    final error = stopError;
    if (error != null) throw error;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    recording = false;
    if (!_chunks.isClosed) await _chunks.close();
  }

  void add(Uint8List chunk) {
    if (!_chunks.isClosed) _chunks.add(chunk);
  }
}
