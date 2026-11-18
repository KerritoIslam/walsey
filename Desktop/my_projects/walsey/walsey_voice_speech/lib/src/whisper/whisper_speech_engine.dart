import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../engine/speech_engine.dart';
import 'whisper_bindings.dart';
import 'whisper_pcm.dart';
import 'whisper_result.dart';

/// Vocabulary hint handed to the decoder as `initial_prompt`.
///
/// A general English model has never seen this product's words, so it guesses:
/// "Walsey" becomes "Volsidy", "LEDDMX" becomes "Letting 0", "green" becomes
/// "screen". The hint only biases the decoder towards the spellings the
/// command parser accepts — it adds no commands and bypasses no validation.
///
/// It is applied only when [WhisperBindings.setInitialPrompt] accepts the
/// native parameter struct; otherwise the engine decodes exactly as before.
const whisperVocabularyPrompt =
    'Walsey. LEDDMX. Turn the lights on. Turn the lights off. Make the lights '
    'cyan. Scan for devices. Walsey scan for devices. Connect to '
    'LEDDMX-03-6B4A. Turn the lights on, then set brightness to 60 percent. '
    'Activate effect 7. Make the lights red, green, blue, white, yellow, '
    'orange, purple, pink or magenta.';

/// [SpeechEngine] backed by whisper.cpp.
///
/// Whisper works per utterance, not incrementally: audio chunks are buffered
/// in the worker isolate and the whole take is decoded in one [finish] call.
/// That means there are no partial transcripts while the user is speaking —
/// the push-to-talk UX stays honest by simply showing none.
///
/// Model loading and inference both happen in a dedicated isolate:
/// `whisper_init_from_file` reads ~140 MB from disk and `whisper_full` is a
/// synchronous multi-second CPU call, so running either on the UI isolate
/// would freeze the page. Audio is forwarded as [TransferableTypedData] to
/// avoid copying, and every command is handled in order by the worker.
class WhisperSpeechEngine implements SpeechEngine {
  WhisperSpeechEngine._(this._isolate, this._inboxCompleter, this._outbox) {
    _outbox.listen(_handleMessage);
  }

  /// Whether the native whisper.cpp libraries exist for this operating
  /// system.
  static bool get isSupportedPlatform => WhisperBindings.isSupportedPlatform;

  /// Spawns the worker isolate. The returned engine has no model loaded yet.
  ///
  /// The optional paths exist for command-line tools and tests that do not run
  /// next to the shipped DLLs; production callers pass nothing and the loader
  /// resolves the libraries from the executable/APK directory.
  ///
  /// Throws [WhisperLibraryException] when the native libraries are
  /// unavailable or the worker does not start in time.
  static Future<WhisperSpeechEngine> spawn({
    String? ggmlLibraryPath,
    String? whisperLibraryPath,
    String? backendSearchPath,
  }) async {
    final outbox = ReceivePort();
    final inboxCompleter = Completer<SendPort>();
    final isolate = await Isolate.spawn(
      _workerMain,
      (
        outbox.sendPort,
        ggmlLibraryPath,
        whisperLibraryPath,
        backendSearchPath,
      ),
      debugName: 'walsey-whisper-worker',
    );
    final engine = WhisperSpeechEngine._(isolate, inboxCompleter, outbox);
    try {
      final sendPort = await inboxCompleter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw WhisperLibraryException(
          'the Whisper worker did not start within 15 seconds',
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

  /// Whether the installed whisper.cpp build accepted the vocabulary prompt
  /// (see [whisperVocabularyPrompt]). `false` means decoding is un-prompted —
  /// the behaviour of every build before this was added; it is not an error.
  bool get vocabularyPromptApplied => _vocabularyPromptApplied;
  bool _vocabularyPromptApplied = false;

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
    await _call('begin', {'sampleRate': sampleRate});
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
        // The worker may be stuck decoding a long take; local cleanup below
        // still applies and the isolate is killed outright.
      }
      _pending.remove(id);
    }
    _disposed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          WhisperLibraryException('the Whisper worker was disposed'),
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
      throw WhisperLibraryException('the Whisper worker was disposed');
    }
    final sendPort = _sendPort;
    if (sendPort == null) {
      throw WhisperLibraryException('the Whisper worker is not ready');
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
          WhisperLibraryException(
            message['message'] as String? ??
                'the Whisper worker could not load the native libraries',
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
    final promptBias = message['promptBias'];
    if (promptBias is bool) {
      _vocabularyPromptApplied = promptBias;
    }
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }
    if (message['ok'] == true) {
      completer.complete(message['text'] as String?);
    } else {
      completer.completeError(
        WhisperLibraryException(
          message['error'] as String? ?? 'unknown Whisper worker error',
        ),
      );
    }
  }

  void _handleEvent(String event, Map<Object?, Object?> message) {
    if (_events.isClosed) {
      return;
    }
    switch (event) {
      case 'error':
        _events.add(
          SpeechEngineError(
            message['message'] as String? ?? 'Whisper rejected the audio chunk',
          ),
        );
    }
  }
}

/// Entry point of the worker isolate. Everything below runs off the UI thread.
void _workerMain((SendPort, String?, String?, String?) arguments) {
  final (
    outbox,
    ggmlLibraryPath,
    whisperLibraryPath,
    backendSearchPath,
  ) = arguments;
  final inbox = ReceivePort();

  // Load the native libraries before announcing readiness: a missing
  // DLL/SO is then reported as a library problem, never misdiagnosed as a
  // bad model.
  final WhisperBindings bindings;
  try {
    bindings = WhisperBindings.load(
      ggmlLibraryPath: ggmlLibraryPath,
      whisperLibraryPath: whisperLibraryPath,
      backendSearchPath:
          backendSearchPath ?? WhisperBindings.defaultBackendSearchPath,
    );
    bindings.loadBackends();
  } on Object catch (error) {
    outbox.send({'event': 'startupError', 'message': error.toString()});
    return;
  }

  outbox.send(inbox.sendPort);

  Pointer<Void> model = nullptr;
  Pointer<Void> params = nullptr;
  Pointer<Utf8> prompt = nullptr;
  bool promptApplied = false;
  final utterance = BytesBuilder(copy: false);
  int utteranceBytes = 0;
  bool overflowReported = false;

  /// Kept at roughly 2 minutes of 16 kHz audio. Push-to-talk commands are
  /// seconds long; this bound only stops a forgotten open session from
  /// consuming unbounded memory.
  const maxUtteranceBytes = 16000 * 2 * 120;

  void reply(
    int id, {
    bool ok = true,
    String? error,
    String? text,
    bool? promptBias,
  }) {
    outbox.send({
      'id': id,
      'ok': ok,
      'error': error,
      'text': text,
      'promptBias': ?promptBias,
    });
  }

  void dropUtterance() {
    utterance.clear();
    utteranceBytes = 0;
    overflowReported = false;
  }

  void freeModel() {
    if (params != nullptr) {
      bindings.freeParams(params);
      params = nullptr;
    }
    if (prompt != nullptr) {
      // Owned by this isolate; whisper.cpp only borrows the pointer, so it must
      // outlive the parameter set and is released after it.
      malloc.free(prompt);
      prompt = nullptr;
      promptApplied = false;
    }
    if (model != nullptr) {
      bindings.free(model);
      model = nullptr;
    }
  }

  /// Decodes the buffered utterance and returns the raw transcript.
  String? decode() {
    final pcm = utterance.takeBytes();
    utteranceBytes = 0;
    if (pcm.isEmpty) {
      return null;
    }
    final samples = pcm16ToFloat32(pcm);
    final code = bindings.run(model, params, samples);
    if (code != 0) {
      throw WhisperLibraryException(
        'whisper_full failed with error code $code',
      );
    }
    final segments = <String>[];
    final count = bindings.segmentCount(model);
    for (var i = 0; i < count; i++) {
      segments.add(bindings.segmentText(model, i));
    }
    return whisperTranscriptText(segments);
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
          if (model == nullptr || data is! TransferableTypedData) {
            return;
          }
          final pcm = data.materialize().asUint8List();
          if (utteranceBytes + pcm.length > maxUtteranceBytes) {
            if (!overflowReported) {
              overflowReported = true;
              outbox.send({
                'event': 'error',
                'message':
                    'The utterance exceeded ${maxUtteranceBytes ~/ 32000} '
                    'seconds; later audio was dropped.',
              });
            }
            return;
          }
          utterance.add(pcm);
          utteranceBytes += pcm.length;
        case 'load':
          final path = message['path'];
          if (path is! String) {
            reply(id, ok: false, error: 'missing model path');
            break;
          }
          dropUtterance();
          freeModel();
          model = bindings.initFromFile(path);
          if (model == nullptr) {
            reply(
              id,
              ok: false,
              error: 'Whisper could not load the model at $path',
            );
          } else {
            params = bindings.createParams();
            if (params == nullptr) {
              bindings.free(model);
              model = nullptr;
              reply(
                id,
                ok: false,
                error: 'Whisper did not return a default parameter set',
              );
            } else {
              // Bias the decoder towards the product vocabulary. A rejected
              // struct is not an error: decoding simply stays un-prompted.
              prompt = whisperVocabularyPrompt.toNativeUtf8();
              promptApplied = WhisperBindings.setInitialPrompt(params, prompt);
              if (!promptApplied) {
                malloc.free(prompt);
                prompt = nullptr;
              }
              // whisper.cpp keeps 5 greedy candidates per window by default.
              // The command corpus shows no accuracy gain over one candidate
              // and roughly double the decode time (docs/voice_accuracy.md),
              // so ask for a single candidate. A rejected struct keeps the
              // library default; nothing here can corrupt the parameters.
              WhisperBindings.setGreedyBestOf(params, 1);
              reply(id, promptBias: promptApplied);
            }
          }
        case 'begin':
          final rate = message['sampleRate'];
          if (model == nullptr) {
            reply(id, ok: false, error: 'no model is loaded');
            break;
          }
          final sampleRate = rate is int ? rate : 16000;
          if (sampleRate != 16000) {
            reply(
              id,
              ok: false,
              error:
                  'Whisper expects 16 kHz audio; capture requested '
                  '$sampleRate Hz',
            );
            break;
          }
          dropUtterance();
          reply(id);
        case 'finish':
          if (model == nullptr) {
            reply(id, text: null);
            break;
          }
          reply(id, text: decode());
        case 'reset':
          dropUtterance();
          reply(id);
        case 'dispose':
          dropUtterance();
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
      // A failed decode may leave the buffer in a half-used state; the next
      // session must start clean either way.
      if (operation == 'finish') {
        dropUtterance();
      }
    }
  });
}
