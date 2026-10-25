import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'speech_engine.dart';
import 'vosk_bindings.dart';
import 'vosk_result.dart';

/// [SpeechEngine] backed by the native Vosk library.
///
/// Model loading and recognition both happen in a dedicated isolate:
/// `vosk_model_new` reads ~40–100 MB from disk and `accept_waveform` is a
/// synchronous CPU call, so running either on the UI isolate would freeze the
/// page. Audio is forwarded as [TransferableTypedData] to avoid copying, and
/// every command is handled in order by the worker.
class VoskSpeechEngine implements SpeechEngine {
  VoskSpeechEngine._(this._isolate, this._inboxCompleter, this._outbox) {
    _outbox.listen(_handleMessage);
  }

  /// Whether the native Vosk library exists for this operating system.
  static bool get isSupportedPlatform => VoskBindings.isSupportedPlatform;

  /// Spawns the worker isolate. The returned engine has no model loaded yet.
  ///
  /// Throws [VoskLibraryException] when the native library is unavailable.
  static Future<VoskSpeechEngine> spawn() async {
    final outbox = ReceivePort();
    final inboxCompleter = Completer<SendPort>();
    final isolate = await Isolate.spawn(
      _workerMain,
      outbox.sendPort,
      debugName: 'walsey-vosk-worker',
    );
    final engine = VoskSpeechEngine._(isolate, inboxCompleter, outbox);
    try {
      final sendPort = await inboxCompleter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw VoskLibraryException(
          'the Vosk worker did not start within 15 seconds',
        ),
      );
      engine._sendPort = sendPort;
      return engine;
    } catch (_) {
      outbox.close();
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  final Isolate _isolate;
  final Completer<SendPort> _inboxCompleter;
  final ReceivePort _outbox;
  SendPort? _sendPort;
  final Map<int, Completer<String?>> _pending = {};
  final StreamController<SpeechEngineEvent> _events =
      StreamController<SpeechEngineEvent>.broadcast();
  int _nextId = 0;
  bool _closing = false;
  bool _disposed = false;

  @override
  Stream<SpeechEngineEvent> get events => _events.stream;

  @override
  Future<void> loadModel(String modelPath) async {
    await _call('load', {'path': modelPath});
  }

  @override
  Future<void> beginSession({
    required int sampleRate,
    List<String>? grammar,
  }) async {
    await _call('begin', {'sampleRate': sampleRate, 'grammar': grammar});
  }

  @override
  void accept(Uint8List pcm) {
    if (_closing || _disposed || pcm.isEmpty) {
      return;
    }
    _sendPort?.send({
      'id': -1,
      'op': 'feed',
      'data': TransferableTypedData.fromList([pcm]),
    });
  }

  @override
  Future<String?> finish() => _call('finish');

  @override
  Future<void> reset() async {
    await _call('reset');
  }

  @override
  Future<void> dispose() async {
    if (_closing || _disposed) {
      return;
    }
    _closing = true;
    final sendPort = _sendPort;
    if (sendPort != null) {
      final id = _nextId++;
      final completer = Completer<String?>();
      _pending[id] = completer;
      sendPort.send({'id': id, 'op': 'dispose'});
      try {
        await completer.future.timeout(const Duration(seconds: 5));
      } on Object {
        // The worker may already be gone; local cleanup below still applies.
      }
      _pending.remove(id);
    }
    _disposed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          VoskLibraryException('the Vosk worker was disposed'),
        );
      }
    }
    _pending.clear();
    _outbox.close();
    _isolate.kill(priority: Isolate.immediate);
    await _events.close();
  }

  Future<String?> _call(
    String operation, [
    Map<String, Object?> args = const {},
  ]) {
    if (_closing || _disposed) {
      throw VoskLibraryException('the Vosk worker was disposed');
    }
    final sendPort = _sendPort;
    if (sendPort == null) {
      throw VoskLibraryException('the Vosk worker is not ready');
    }
    final id = _nextId++;
    final completer = Completer<String?>();
    _pending[id] = completer;
    sendPort.send({'id': id, 'op': operation, ...args});
    return completer.future;
  }

  void _handleMessage(Object? message) {
    if (message is Map && message['event'] == 'startupError') {
      final completer = _inboxCompleter;
      if (!completer.isCompleted) {
        completer.completeError(
          VoskLibraryException(
            message['message'] as String? ??
                'the Vosk worker could not load the native library',
          ),
        );
      }
      return;
    }
    if (message is SendPort) {
      if (!_inboxCompleter.isCompleted) {
        _inboxCompleter.complete(message);
      }
      return;
    }
    if (message is! Map) {
      return;
    }
    final event = message['event'];
    if (event is String) {
      _handleEvent(event, message);
      return;
    }
    final id = message['id'];
    if (id is! int) {
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }
    if (message['ok'] == true) {
      completer.complete(message['text'] as String?);
    } else {
      completer.completeError(
        VoskLibraryException(
          message['error'] as String? ?? 'unknown Vosk worker error',
        ),
      );
    }
  }

  void _handleEvent(String event, Map<Object?, Object?> message) {
    if (_events.isClosed) {
      return;
    }
    switch (event) {
      case 'partial':
        final text = message['text'];
        if (text is String && text.isNotEmpty) {
          _events.add(SpeechEnginePartial(text));
        }
      case 'segment':
        final text = message['text'];
        if (text is String && text.isNotEmpty) {
          _events.add(SpeechEngineSegment(text));
        }
      case 'error':
        _events.add(
          SpeechEngineError(
            message['message'] as String? ?? 'Vosk rejected the audio chunk',
          ),
        );
    }
  }
}

/// Entry point of the worker isolate. Everything below runs off the UI thread.
void _workerMain(SendPort outbox) {
  final inbox = ReceivePort();

  // Load the native library before announcing readiness: a missing DLL/SO is
  // then reported as a library problem, never misdiagnosed as a bad model.
  final VoskBindings bindings;
  try {
    bindings = VoskBindings.load();
  } on Object catch (error) {
    outbox.send({'event': 'startupError', 'message': error.toString()});
    return;
  }

  outbox.send(inbox.sendPort);

  Pointer<Void> model = nullptr;
  Pointer<Void> recognizer = nullptr;

  void reply(int id, {bool ok = true, String? error, String? text}) {
    outbox.send({'id': id, 'ok': ok, 'error': error, 'text': text});
  }

  void freeRecognizer() {
    if (recognizer != nullptr) {
      bindings.recognizerFree(recognizer);
      recognizer = nullptr;
    }
  }

  void freeModel() {
    if (model != nullptr) {
      bindings.modelFree(model);
      model = nullptr;
    }
  }

  inbox.listen((Object? message) {
    if (message is! Map) {
      return;
    }
    final id = message['id'];
    final operation = message['op'];
    if (id is! int || operation is! String) {
      return;
    }
    try {
      switch (operation) {
        case 'feed':
          final data = message['data'];
          if (recognizer == nullptr || data is! TransferableTypedData) {
            return;
          }
          final pcm = data.materialize().asUint8List();
          final status = bindings.acceptWaveform(recognizer, pcm);
          if (status < 0) {
            outbox.send({
              'event': 'error',
              'message': 'Vosk rejected an audio chunk (accept_waveform = -1)',
            });
          } else if (status == 1) {
            final text = voskTranscriptText(bindings.result(recognizer) ?? '');
            if (text != null) {
              outbox.send({'event': 'segment', 'text': text});
            }
          } else {
            final text = voskTranscriptText(
              bindings.partialResult(recognizer) ?? '',
            );
            if (text != null) {
              outbox.send({'event': 'partial', 'text': text});
            }
          }
        case 'load':
          final path = message['path'];
          if (path is! String) {
            reply(id, ok: false, error: 'missing model path');
            break;
          }
          freeRecognizer();
          freeModel();
          model = bindings.modelNew(path);
          if (model == nullptr) {
            reply(
              id,
              ok: false,
              error: 'Vosk could not load the model at $path',
            );
          } else {
            reply(id);
          }
        case 'begin':
          final rate = message['sampleRate'];
          if (model == nullptr) {
            reply(id, ok: false, error: 'no model is loaded');
            break;
          }
          final grammar = message['grammar'];
          final phrases = grammar is List
              ? grammar.whereType<String>().toList(growable: false)
              : const <String>[];
          freeRecognizer();
          recognizer = phrases.isEmpty
              ? bindings.recognizerNew(
                  model,
                  rate is int ? rate.toDouble() : 16000,
                )
              : bindings.recognizerNewWithGrammar(
                  model,
                  rate is int ? rate.toDouble() : 16000,
                  phrases,
                );
          if (recognizer == nullptr) {
            reply(id, ok: false, error: 'Vosk could not create a recognizer');
          } else {
            reply(id);
          }
        case 'finish':
          if (recognizer == nullptr) {
            reply(id, text: null);
            break;
          }
          final text = voskTranscriptText(
            bindings.finalResult(recognizer) ?? '',
          );
          freeRecognizer();
          reply(id, text: text);
        case 'reset':
          freeRecognizer();
          reply(id);
        case 'dispose':
          freeRecognizer();
          freeModel();
          reply(id);
          inbox.close();
        default:
          reply(id, ok: false, error: 'unknown command "$operation"');
      }
    } catch (error) {
      if (id >= 0) {
        reply(id, ok: false, error: error.toString());
      } else {
        outbox.send({'event': 'error', 'message': error.toString()});
      }
    }
  });
}
