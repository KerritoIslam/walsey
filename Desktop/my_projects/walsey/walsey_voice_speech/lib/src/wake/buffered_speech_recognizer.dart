import 'dart:typed_data';

import 'package:walsey_voice_core/walsey_voice_core.dart';

import '../engine/speech_engine.dart';
import '../model/model_catalog.dart';
import '../model/model_store.dart';
import '../speech_recognizer.dart';

/// Port for "transcribe this already-captured PCM buffer".
///
/// Separate from `SpeechRecognizer` because that port owns the microphone. The
/// wake pipeline owns capture itself (it must score the wake word and keep a
/// pre-roll buffer), so it needs only the decode half.
abstract interface class BufferedRecognizer {
  /// Transcribes 16 kHz mono PCM16. Returns `null` for an empty buffer.
  Future<String?> recognize(Uint8List pcm16);
}

/// [BufferedRecognizer] over a [SpeechEngineBinding].
///
/// The engine and its model stay warm between calls exactly like the
/// push-to-talk path: [prepare] is idempotent, and [recognize] only starts a
/// session. No file is downloaded and nothing is parsed here.
final class BufferedSpeechRecognizer implements BufferedRecognizer {
  BufferedSpeechRecognizer({
    required SpeechEngineBinding binding,
    ModelStore? modelStore,
    SpeechEngine? engine,
    SpeechLanguage language = SpeechLanguage.defaultLanguage,
    this.sampleRate = 16000,
  })  : _binding = binding,
        _modelStore = modelStore ?? ModelStore.platform(),
        _engine = engine,
        _language = language;

  final SpeechEngineBinding _binding;
  final ModelStore _modelStore;
  final int sampleRate;

  SpeechEngine? _engine;
  SpeechLanguage _language;
  String? _loadedModelPath;
  bool _disposed = false;

  Future<SpeechAvailability>? _pendingPrepare;

  /// Loads the engine and model once. Reuses everything on subsequent calls.
  Future<SpeechAvailability> prepare({SpeechLanguage? language}) {
    final target = language ?? _language;
    _language = target;
    final pending = _pendingPrepare;
    if (pending != null) return pending;
    final future = _prepareFor(target);
    _pendingPrepare = future;
    return future.whenComplete(() {
      if (identical(_pendingPrepare, future)) _pendingPrepare = null;
    });
  }

  Future<SpeechAvailability> _prepareFor(SpeechLanguage language) async {
    if (!_binding.platformSupported()) {
      return SpeechUnavailable(
        kind: SpeechFailureKind.unsupportedPlatform,
        message: '${_binding.name} is not available on this platform; typed '
            'input still works.',
      );
    }
    final model = _binding.modelFor(language);
    if (model == null) {
      return SpeechUnavailable(
        kind: SpeechFailureKind.unsupportedLanguage,
        message: '${language.label}: ${language.detail}',
      );
    }
    final String? path;
    try {
      path = await _modelStore.installedModelPath(model);
    } on Object catch (error) {
      return SpeechUnavailable(
        kind: SpeechFailureKind.initializationFailed,
        message: 'Could not inspect the model folder: $error',
      );
    }
    if (path == null) {
      return SpeechModelRequired(
        message: '${model.languageLabel} needs the ${model.id} model '
            '(about ${model.archiveSizeMegabytes} MB). Install it once in the '
            'language model setup; nothing is downloaded automatically.',
      );
    }

    final existing = _engine;
    if (existing != null && _loadedModelPath == path) {
      return const SpeechReady();
    }

    final SpeechEngine engine;
    if (existing != null) {
      engine = existing;
    } else {
      try {
        engine = await _binding.spawn();
      } on Object catch (error) {
        return SpeechUnavailable(
          kind: SpeechFailureKind.nativeLibraryUnavailable,
          message: '${_binding.nativeLibraryHint} Details: $error',
        );
      }
      _engine = engine;
    }

    try {
      await engine.loadModel(path);
    } on Object catch (error) {
      return SpeechUnavailable(
        kind: SpeechFailureKind.modelInvalid,
        message: '${_binding.name} rejected the ${model.id} model. Details: '
            '$error',
      );
    }
    _loadedModelPath = path;
    return const SpeechReady();
  }

  @override
  Future<String?> recognize(Uint8List pcm16) async {
    if (_disposed) {
      throw StateError('The buffered recognizer has been disposed.');
    }
    if (pcm16.isEmpty) return null;
    final availability = await prepare();
    if (availability is! SpeechReady) {
      throw StateError(
        availability is SpeechUnavailable
            ? availability.message
            : (availability as SpeechModelRequired).message,
      );
    }
    final engine = _engine;
    if (engine == null) {
      throw StateError('The speech engine was not initialized.');
    }
    await engine.beginSession(sampleRate: sampleRate);
    // Feed in bounded slices: the worker transfers each slice without a copy,
    // and a 15 s take is still only a handful of messages.
    const sliceBytes = 64 * 1024;
    for (var offset = 0; offset < pcm16.length; offset += sliceBytes) {
      final end =
          offset + sliceBytes < pcm16.length ? offset + sliceBytes : pcm16.length;
      engine.accept(Uint8List.sublistView(pcm16, offset, end));
    }
    return engine.finish();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
  }
}
