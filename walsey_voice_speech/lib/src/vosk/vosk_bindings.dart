import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Function signatures for the subset of the Vosk C API Stage 2 uses.
///
/// The C header declares `float sample_rate`, so the Dart side uses [Float]
/// (not `Double`); `int` is [Int32] on every platform Vosk ships for.
typedef _SetLogLevelNative = Void Function(Int32);
typedef _SetLogLevelDart = void Function(int level);

typedef _ModelNewNative = Pointer<Void> Function(Pointer<Utf8> modelPath);
typedef _ModelNewDart = Pointer<Void> Function(Pointer<Utf8> modelPath);

typedef _ModelFreeNative = Void Function(Pointer<Void> model);
typedef _ModelFreeDart = void Function(Pointer<Void> model);

typedef _RecognizerNewNative =
    Pointer<Void> Function(Pointer<Void> model, Float sampleRate);
typedef _RecognizerNewDart =
    Pointer<Void> Function(Pointer<Void> model, double sampleRate);

typedef _RecognizerFreeNative = Void Function(Pointer<Void> recognizer);
typedef _RecognizerFreeDart = void Function(Pointer<Void> recognizer);

typedef _AcceptWaveformNative =
    Int32 Function(Pointer<Void> recognizer, Pointer<Uint8> data, Int32 length);
typedef _AcceptWaveformDart =
    int Function(Pointer<Void> recognizer, Pointer<Uint8> data, int length);

typedef _StringResultNative = Pointer<Utf8> Function(Pointer<Void> recognizer);

typedef _RecognizerNewGrmNative =
    Pointer<Void> Function(
      Pointer<Void> model,
      Float sampleRate,
      Pointer<Utf8> grammar,
    );
typedef _RecognizerNewGrmDart =
    Pointer<Void> Function(
      Pointer<Void> model,
      double sampleRate,
      Pointer<Utf8> grammar,
    );

/// Thrown when the native Vosk library cannot be loaded or called.
class VoskLibraryException implements Exception {
  VoskLibraryException(this.message);

  final String message;

  @override
  String toString() => 'VoskLibraryException: $message';
}

/// Direct `dart:ffi` binding for the Vosk C API.
///
/// Only ever constructed inside the Vosk worker isolate: the native model and
/// recognizer handles are pointers owned by that isolate and must not be
/// touched from the UI isolate.
class VoskBindings {
  VoskBindings._(DynamicLibrary library, this.loadedLibrary)
    : _setLogLevel = library
          .lookupFunction<_SetLogLevelNative, _SetLogLevelDart>(
            'vosk_set_log_level',
          ),
      _modelNew = library.lookupFunction<_ModelNewNative, _ModelNewDart>(
        'vosk_model_new',
      ),
      _modelFree = library.lookupFunction<_ModelFreeNative, _ModelFreeDart>(
        'vosk_model_free',
      ),
      _recognizerNew = library
          .lookupFunction<_RecognizerNewNative, _RecognizerNewDart>(
            'vosk_recognizer_new',
          ),
      _recognizerFree = library
          .lookupFunction<_RecognizerFreeNative, _RecognizerFreeDart>(
            'vosk_recognizer_free',
          ),
      _acceptWaveform = library
          .lookupFunction<_AcceptWaveformNative, _AcceptWaveformDart>(
            'vosk_recognizer_accept_waveform',
          ),
      _result = library
          .lookupFunction<_StringResultNative, _StringResultNative>(
            'vosk_recognizer_result',
          ),
      _partialResult = library
          .lookupFunction<_StringResultNative, _StringResultNative>(
            'vosk_recognizer_partial_result',
          ),
      _finalResult = library
          .lookupFunction<_StringResultNative, _StringResultNative>(
            'vosk_recognizer_final_result',
          ),
      _recognizerNewGrm = library.providesSymbol('vosk_recognizer_new_grm')
          ? library
                .lookupFunction<_RecognizerNewGrmNative, _RecognizerNewGrmDart>(
                  'vosk_recognizer_new_grm',
                )
          : null;

  /// Whether Vosk ships a native library on this operating system.
  ///
  /// Stage 2 wires Android and Windows only. macOS/Linux could be added later
  /// with their own release archive; until then the recognizer reports
  /// `unsupportedPlatform` instead of pretending to work.
  static bool get isSupportedPlatform =>
      Platform.isAndroid || Platform.isWindows;

  /// Name looked up by the dynamic loader.
  ///
  /// Android resolves it from the APK's `lib/<abi>/` directory; Windows looks
  /// next to the executable (see `windows/CMakeLists.txt`).
  static String get libraryName =>
      Platform.isWindows ? 'libvosk.dll' : 'libvosk.so';

  final _SetLogLevelDart _setLogLevel;
  final _ModelNewDart _modelNew;
  final _ModelFreeDart _modelFree;
  final _RecognizerNewDart _recognizerNew;
  final _RecognizerFreeDart _recognizerFree;
  final _AcceptWaveformDart _acceptWaveform;
  final _StringResultNative _result;
  final _StringResultNative _partialResult;
  final _StringResultNative _finalResult;
  final _RecognizerNewGrmDart? _recognizerNewGrm;

  /// The name this binding was opened with, for diagnostics.
  final String loadedLibrary;

  /// Whether this native build exposes the constrained-grammar entry point.
  bool get supportsGrammarApi => _recognizerNewGrm != null;

  static VoskBindings load({String? libraryPath}) {
    final name = libraryPath ?? libraryName;
    final DynamicLibrary library;
    try {
      library = DynamicLibrary.open(name);
    } on ArgumentError catch (error) {
      throw VoskLibraryException('Could not load $name: ${error.message}');
    }
    try {
      return VoskBindings._(library, name);
    } on ArgumentError catch (error) {
      // A library that loads but lacks the expected exports is just as useless,
      // and the error must not be reported as a model problem.
      throw VoskLibraryException(
        'loaded $name but an expected Vosk export is missing: '
        '${error.message}',
      );
    }
  }

  /// Vosk's own diagnostics are silenced by default (`-1`); a negative level
  /// is what its command-line tools use for "quiet".
  void setLogLevel(int level) => _setLogLevel(level);

  Pointer<Void> modelNew(String modelPath) {
    final pathPointer = modelPath.toNativeUtf8();
    try {
      return _modelNew(pathPointer);
    } finally {
      malloc.free(pathPointer);
    }
  }

  void modelFree(Pointer<Void> model) => _modelFree(model);

  Pointer<Void> recognizerNew(Pointer<Void> model, double sampleRate) =>
      _recognizerNew(model, sampleRate);

  /// Creates a recognizer constrained to the phrases in [phrases].
  ///
  /// Vosk expects a JSON array of phrase strings; `[unk]` may be included to
  /// keep an out-of-vocabulary token. Throws [VoskLibraryException] when the
  /// native build lacks the entry point, and callers must additionally check
  /// that the model has a dynamic graph (see `VoskModelInfo.supportsGrammar`):
  /// passing a grammar to a static-graph model aborts inside Vosk.
  Pointer<Void> recognizerNewWithGrammar(
    Pointer<Void> model,
    double sampleRate,
    List<String> phrases,
  ) {
    final constructor = _recognizerNewGrm;
    if (constructor == null) {
      throw VoskLibraryException(
        'this Vosk build does not export vosk_recognizer_new_grm',
      );
    }
    final escaped = phrases
        .map((phrase) => phrase.replaceAll('\\', r'\\').replaceAll('"', r'\"'))
        .map((phrase) => '"$phrase"')
        .join(',');
    final grammar = '[$escaped]';
    final pointer = grammar.toNativeUtf8();
    try {
      return constructor(model, sampleRate, pointer);
    } finally {
      malloc.free(pointer);
    }
  }

  void recognizerFree(Pointer<Void> recognizer) => _recognizerFree(recognizer);

  /// Feeds 16-bit little-endian mono PCM.
  ///
  /// Returns `1` when Vosk closed an utterance at this chunk, `0` when the
  /// utterance is still open, and `-1` on failure.
  int acceptWaveform(Pointer<Void> recognizer, Uint8List pcm) {
    // `malloc(0)` is not guaranteed to return a usable pointer.
    if (pcm.isEmpty) {
      return 0;
    }
    final buffer = malloc<Uint8>(pcm.length);
    try {
      buffer.asTypedList(pcm.length).setAll(0, pcm);
      return _acceptWaveform(recognizer, buffer, pcm.length);
    } finally {
      malloc.free(buffer);
    }
  }

  /// Text of the last completed segment inside an open utterance.
  String? result(Pointer<Void> recognizer) => _read(_result(recognizer));

  /// Unstable in-progress text.
  String? partialResult(Pointer<Void> recognizer) =>
      _read(_partialResult(recognizer));

  /// Text of the whole utterance. Vosk keeps ownership of the pointer, so the
  /// string is copied immediately.
  String? finalResult(Pointer<Void> recognizer) =>
      _read(_finalResult(recognizer));

  String? _read(Pointer<Utf8> pointer) {
    if (pointer == nullptr) {
      return null;
    }
    return pointer.toDartString();
  }
}
