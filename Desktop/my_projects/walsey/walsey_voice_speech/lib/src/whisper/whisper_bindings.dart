import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Function signatures for the subset of the whisper.cpp C API Stage 2 uses.
///
/// The C API takes `whisper_full_params` by value, which is fragile across
/// FFI boundaries, so every whisper.cpp build ships `whisper_full_default_params_by_ref`
/// returning a `whisper_full_params*` instead. This binding therefore works
/// exclusively with that pointer form (`Pointer<Void>` — the struct is opaque
/// to Dart; we never mutate it, we only use the greedy defaults).
typedef _WhisperInitFromFileNative = Pointer<Void> Function(Pointer<Utf8> path);
typedef _WhisperInitFromFileDart = Pointer<Void> Function(Pointer<Utf8> path);

typedef _WhisperFreeNative = Void Function(Pointer<Void> context);
typedef _WhisperFreeDart = void Function(Pointer<Void> context);

typedef _WhisperFullDefaultParamsByRefNative = Pointer<Void> Function(
  Int32 strategy,
);
typedef _WhisperFullDefaultParamsByRefDart = Pointer<Void> Function(
  int strategy,
);

typedef _WhisperFreeParamsNative = Void Function(Pointer<Void> params);
typedef _WhisperFreeParamsDart = void Function(Pointer<Void> params);

typedef _WhisperFullNative =
    Int32 Function(
      Pointer<Void> context,
      Pointer<Void> params,
      Pointer<Float> samples,
      Int32 sampleCount,
    );
typedef _WhisperFullDart =
    int Function(
      Pointer<Void> context,
      Pointer<Void> params,
      Pointer<Float> samples,
      int sampleCount,
    );

typedef _WhisperFullNSegmentsNative = Int32 Function(Pointer<Void> context);
typedef _WhisperFullNSegmentsDart = int Function(Pointer<Void> context);

typedef _WhisperFullGetSegmentTextNative =
    Pointer<Utf8> Function(Pointer<Void> context, Int32 segment);
typedef _WhisperFullGetSegmentTextDart =
    Pointer<Utf8> Function(Pointer<Void> context, int segment);

typedef _GgmlBackendLoadAllFromPathNative = Void Function(Pointer<Utf8> path);
typedef _GgmlBackendLoadAllFromPathDart = void Function(Pointer<Utf8> path);

typedef _GgmlBackendLoadAllNative = Void Function();
typedef _GgmlBackendLoadAllDart = void Function();

/// `struct whisper_full_params` prefix, as laid out by the pinned whisper.cpp
/// release (1.9.5, binaries tag b5454).
///
/// The binding never needs this struct to decode: [WhisperBindings.createParams]
/// uses the opaque by-reference default. It exists only so
/// [WhisperBindings.setInitialPrompt] can point `initial_prompt` at a
/// Dart-owned string, and that method refuses to write anything unless every
/// known default in this prefix matches. A whisper.cpp build with a different
/// layout therefore degrades to "no prompt", never to a corrupted struct.
final class _WhisperFullParams extends Struct {
  @Int32()
  external int strategy;

  @Int32()
  external int nThreads;

  @Int32()
  external int nMaxTextCtx;

  @Int32()
  external int offsetMs;

  @Int32()
  external int durationMs;

  @Uint8()
  external int translate;

  @Uint8()
  external int noContext;

  @Uint8()
  external int noTimestamps;

  @Uint8()
  external int singleSegment;

  @Uint8()
  external int printSpecial;

  @Uint8()
  external int printProgress;

  @Uint8()
  external int printRealtime;

  @Uint8()
  external int printTimestamps;

  @Uint8()
  external int tokenTimestamps;

  @Float()
  external double tholdPt;

  @Float()
  external double tholdPtsum;

  @Int32()
  external int maxLen;

  @Uint8()
  external int splitOnWord;

  @Int32()
  external int maxTokens;

  @Uint8()
  external int debugMode;

  @Int32()
  external int audioCtx;

  @Uint8()
  external int tdrzEnable;

  external Pointer<Utf8> suppressRegex;

  external Pointer<Utf8> initialPrompt;

  @Uint8()
  external int carryInitialPrompt;

  external Pointer<Void> promptTokens;

  @Int32()
  external int promptNTokens;

  external Pointer<Utf8> language;

  @Uint8()
  external int detectLanguage;

  @Uint8()
  external int suppressBlank;

  @Uint8()
  external int suppressNst;

  @Float()
  external double temperature;

  @Float()
  external double maxInitialTs;

  @Float()
  external double lengthPenalty;

  @Float()
  external double temperatureInc;

  @Float()
  external double entropyThold;

  @Float()
  external double logprobThold;

  @Float()
  external double noSpeechThold;

  /// `struct { int best_of; } greedy;` — decoding candidates per window.
  @Int32()
  external int greedyBestOf;
}

/// Thrown when the native whisper.cpp libraries cannot be loaded or called.
class WhisperLibraryException implements Exception {
  WhisperLibraryException(this.message);

  final String message;

  @override
  String toString() => 'WhisperLibraryException: $message';
}

/// Direct `dart:ffi` binding for whisper.cpp (and the ggml backend loader).
///
/// Only ever constructed inside the Whisper worker isolate: the model context
/// and the params struct are native pointers owned by that isolate and must
/// not be touched from the UI isolate.
class WhisperBindings {
  WhisperBindings._(
    DynamicLibrary whisper,
    this._ggml,
    this.loadedLibraryName, {
    required this.backendSearchPath,
  }) : _initFromFile = whisper
           .lookupFunction<_WhisperInitFromFileNative, _WhisperInitFromFileDart>(
             'whisper_init_from_file',
           ),
       _free = whisper.lookupFunction<_WhisperFreeNative, _WhisperFreeDart>(
         'whisper_free',
       ),
       _fullDefaultParamsByRef = whisper.lookupFunction<
         _WhisperFullDefaultParamsByRefNative,
         _WhisperFullDefaultParamsByRefDart
       >('whisper_full_default_params_by_ref'),
       _freeParams = whisper
           .lookupFunction<_WhisperFreeParamsNative, _WhisperFreeParamsDart>(
             'whisper_free_params',
           ),
       _full = whisper.lookupFunction<_WhisperFullNative, _WhisperFullDart>(
         'whisper_full',
       ),
       _fullNSegments = whisper
           .lookupFunction<_WhisperFullNSegmentsNative, _WhisperFullNSegmentsDart>(
             'whisper_full_n_segments',
           ),
       _fullGetSegmentText = whisper.lookupFunction<
         _WhisperFullGetSegmentTextNative,
         _WhisperFullGetSegmentTextDart
       >('whisper_full_get_segment_text');

  /// Whether whisper.cpp ships native libraries for this operating system.
  ///
  /// Stage 2 wires Android and Windows only. A future platform needs its own
  /// built library plus a loader strategy here; until then the recognizer
  /// reports `unsupportedPlatform` instead of pretending to work.
  static bool get isSupportedPlatform =>
      Platform.isAndroid || Platform.isWindows;

  /// Name of the ggml core library looked up by the dynamic loader.
  ///
  /// Windows resolves it next to the executable (see the whisper block in
  /// `windows/runner/CMakeLists.txt`); Android resolves it from the APK's
  /// `lib/<abi>/` directory.
  static String get ggmlLibraryName =>
      Platform.isWindows ? 'ggml.dll' : 'libggml.so';

  /// Name of the whisper library looked up by the dynamic loader.
  static String get whisperLibraryName =>
      Platform.isWindows ? 'whisper.dll' : 'libwhisper.so';

  final DynamicLibrary _ggml;
  final _WhisperInitFromFileDart _initFromFile;
  final _WhisperFreeDart _free;
  final _WhisperFullDefaultParamsByRefDart _fullDefaultParamsByRef;
  final _WhisperFreeParamsDart _freeParams;
  final _WhisperFullDart _full;
  final _WhisperFullNSegmentsDart _fullNSegments;
  final _WhisperFullGetSegmentTextDart _fullGetSegmentText;

  /// The name this binding was opened with, for diagnostics.
  final String loadedLibraryName;

  /// Directory that may contain dynamically loadable ggml backends
  /// (the CPU instruction-set variants on Windows). `null` uses the
  /// platform default search path.
  final String? backendSearchPath;

  /// Opens ggml first, registers the ggml backends, then opens whisper.
  ///
  /// The ggml core must be loaded and its backends registered before the
  /// first whisper context is created, otherwise inference cannot find a CPU
  /// backend. A missing library or a missing export is a library problem and
  /// must never be misdiagnosed as a model problem.
  static WhisperBindings load({
    String? ggmlLibraryPath,
    String? whisperLibraryPath,
    String? backendSearchPath,
  }) {
    final ggmlName = ggmlLibraryPath ?? ggmlLibraryName;
    final whisperName = whisperLibraryPath ?? whisperLibraryName;
    // Windows resolves the imports of an explicitly opened DLL through the
    // host process's search path, not through the DLL's own folder. When a
    // caller (a CLI tool or a test) passes full paths, preload ggml.dll's
    // ggml-base.dll sibling from that same folder so the loader can reuse it
    // by base name. The shipped app loads from its executable directory and
    // never needs this.
    if (Platform.isWindows && ggmlLibraryPath != null) {
      final separator = Platform.pathSeparator;
      final index = ggmlLibraryPath.lastIndexOf(separator);
      if (index > 0) {
        final sibling = '${ggmlLibraryPath.substring(0, index)}'
            '${separator}ggml-base.dll';
        if (File(sibling).existsSync()) {
          try {
            DynamicLibrary.open(sibling);
          } on ArgumentError {
            // Let the ggml.dll load below report the real problem.
          }
        }
      }
    }
    final DynamicLibrary ggml;
    try {
      ggml = DynamicLibrary.open(ggmlName);
    } on ArgumentError catch (error) {
      throw WhisperLibraryException(
        'Could not load $ggmlName: ${error.message}',
      );
    }
    try {
      return WhisperBindings._(
        DynamicLibrary.open(whisperName),
        ggml,
        whisperName,
        backendSearchPath: backendSearchPath,
      );
    } on ArgumentError catch (error) {
      throw WhisperLibraryException(
        'Could not load $whisperName: ${error.message}',
      );
    }
  }

  /// Registers the ggml backends available to the running process.
  ///
  /// Must be called before [createParams]/[initFromFile] are first used.
  ///
  /// Two build shapes exist and both are supported:
  /// - Windows official builds compile the CPU backend as per-instruction-set
  ///   DLLs (`ggml-cpu-*.dll`) next to the executable; they must be
  ///   discovered through `ggml_backend_load_all_from_path`, which is why the
  ///   executable directory is passed as [backendSearchPath].
  /// - Source builds (the Android packaging) compile the CPU backend into
  ///   `libggml.so` and register it on load; the loader entry points may then
  ///   be absent, which is not an error.
  void loadBackends() {
    final path = backendSearchPath;
    if (path != null &&
        _ggml.providesSymbol('ggml_backend_load_all_from_path')) {
      final fromPath = _ggml
          .lookupFunction<
            _GgmlBackendLoadAllFromPathNative,
            _GgmlBackendLoadAllFromPathDart
          >('ggml_backend_load_all_from_path');
      final pointer = path.toNativeUtf8();
      try {
        fromPath(pointer);
      } finally {
        calloc.free(pointer);
      }
      return;
    }
    if (_ggml.providesSymbol('ggml_backend_load_all')) {
      final loadAll = _ggml
          .lookupFunction<_GgmlBackendLoadAllNative, _GgmlBackendLoadAllDart>(
            'ggml_backend_load_all',
          );
      loadAll();
    }
    // Without either symbol the CPU backend is compiled into the ggml
    // library itself and is already registered.
  }

  /// Directory that may hold the per-CPU backend libraries on Windows.
  static String? get defaultBackendSearchPath {
    if (!Platform.isWindows) {
      return null;
    }
    final executable = Platform.resolvedExecutable;
    final index = executable.lastIndexOf(Platform.pathSeparator);
    return index <= 0 ? null : executable.substring(0, index);
  }

  /// Loads a GGUF model file, returning an opaque context, or `null`
  /// (nullptr) when whisper.cpp rejects the file.
  Pointer<Void> initFromFile(String modelPath) {
    final pointer = modelPath.toNativeUtf8();
    try {
      return _initFromFile(pointer);
    } finally {
      malloc.free(pointer);
    }
  }

  /// Greedy-decoding parameter set. Owned by the caller; free with
  /// [freeParams].
  Pointer<Void> createParams() => _fullDefaultParamsByRef(0);

  /// Points `initial_prompt` at [prompt] **only if** the parameter struct still
  /// matches the layout this binding was written for.
  ///
  /// Returns `false` when the guard rejects the struct (a different
  /// whisper.cpp build). The caller then decodes without a prompt — exactly the
  /// behaviour of every build before vocabulary biasing — and must free its own
  /// [prompt] buffer.
  ///
  /// Vocabulary biasing is the one recognition lever the offline engine offers:
  /// the command words ("Walsey", "LEDDMX", colours, "percent", "effect") are
  /// otherwise an out-of-vocabulary guess for a general English model.
  static bool setInitialPrompt(Pointer<Void> params, Pointer<Utf8> prompt) {
    if (params == nullptr || prompt == nullptr) {
      return false;
    }
    final p = params.cast<_WhisperFullParams>().ref;
    if (!_matchesPinnedLayout(p) || p.initialPrompt != nullptr) {
      return false;
    }
    // Defaults set `language` to "en", so this pointer is valid once every
    // preceding field matched. Re-check it anyway: the shipped catalogue only
    // offers English models, and a multilingual model would need its own
    // language decision rather than a silently English-biased prompt.
    if (p.language.toDartString() != 'en') {
      return false;
    }
    p.initialPrompt = prompt;
    return true;
  }

  /// Test-only counterpart of [createParams].
  ///
  /// Allocates memory laid out like [_WhisperFullParams] and fills it with the
  /// pinned release's defaults, so a unit test can prove the guard accepts the
  /// expected layout and rejects every deviation without a native library. The
  /// app never calls this; free the result with `malloc.free`.
  static Pointer<Void> debugAllocatePinnedParams({int greedyBestOf = 5}) {
    final memory = malloc<Uint8>(sizeOf<_WhisperFullParams>());
    final pointer = memory.cast<Void>();
    final p = pointer.cast<_WhisperFullParams>().ref;
    p
      ..strategy = 0
      ..nThreads = 4
      ..nMaxTextCtx = 16384
      ..offsetMs = 0
      ..durationMs = 0
      ..translate = 0
      ..noContext = 1
      ..noTimestamps = 0
      ..singleSegment = 0
      ..printSpecial = 0
      ..printProgress = 1
      ..printRealtime = 0
      ..printTimestamps = 1
      ..tokenTimestamps = 0
      ..tholdPt = 0.01
      ..tholdPtsum = 0.01
      ..maxLen = 0
      ..splitOnWord = 0
      ..maxTokens = 0
      ..debugMode = 0
      ..audioCtx = 0
      ..tdrzEnable = 0
      ..suppressRegex = nullptr
      ..initialPrompt = nullptr
      ..carryInitialPrompt = 0
      ..promptTokens = nullptr
      ..promptNTokens = 0
      ..language = 'en'.toNativeUtf8()
      ..detectLanguage = 0
      ..suppressBlank = 1
      ..suppressNst = 0
      ..temperature = 0
      ..maxInitialTs = 1
      ..lengthPenalty = -1
      ..temperatureInc = 0.2
      ..entropyThold = 2.4
      ..logprobThold = -1
      ..noSpeechThold = 0.6
      ..greedyBestOf = greedyBestOf;
    return pointer;
  }

  /// Number of greedy candidates the decoder keeps per window.
  ///
  /// whisper.cpp's own default is 5, which costs ~5× the decoder work for no
  /// measurable accuracy gain on the command corpus (see docs/voice_accuracy.md).
  /// Returns `false` when the layout guard rejects the struct; the caller then
  /// keeps whatever default the library chose.
  static bool setGreedyBestOf(Pointer<Void> params, int bestOf) {
    if (params == nullptr || bestOf < 1 || bestOf > 32) {
      return false;
    }
    final p = params.cast<_WhisperFullParams>().ref;
    if (!_matchesPinnedLayout(p)) {
      return false;
    }
    p.greedyBestOf = bestOf;
    return true;
  }

  /// Compares every field this binding knows against
  /// `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)` of the pinned
  /// release (whisper.cpp 1.9.5, binaries tag b5454, src/whisper.cpp).
  ///
  /// If any of them differs, the struct this binding describes is not the
  /// struct the library returned, and writing into it would corrupt native
  /// memory. The caller then degrades to the untouched defaults.
  static bool _matchesPinnedLayout(_WhisperFullParams p) {
    return p.strategy == 0 &&
        p.nThreads >= 1 &&
        p.nThreads <= 128 &&
        p.nMaxTextCtx == 16384 &&
        p.offsetMs == 0 &&
        p.durationMs == 0 &&
        p.translate == 0 &&
        p.noContext == 1 &&
        p.noTimestamps == 0 &&
        p.singleSegment == 0 &&
        p.printSpecial == 0 &&
        p.printProgress == 1 &&
        p.printRealtime == 0 &&
        p.printTimestamps == 1 &&
        p.tokenTimestamps == 0 &&
        (p.tholdPt - 0.01).abs() < 0.000001 &&
        (p.tholdPtsum - 0.01).abs() < 0.000001 &&
        p.maxLen == 0 &&
        p.splitOnWord == 0 &&
        p.maxTokens == 0 &&
        p.debugMode == 0 &&
        p.audioCtx == 0 &&
        p.tdrzEnable == 0 &&
        p.suppressRegex == nullptr &&
        p.carryInitialPrompt == 0 &&
        p.promptTokens == nullptr &&
        p.promptNTokens == 0 &&
        p.language != nullptr &&
        p.detectLanguage == 0 &&
        p.suppressBlank == 1 &&
        p.suppressNst == 0 &&
        p.temperature.abs() < 0.000001 &&
        (p.maxInitialTs - 1.0).abs() < 0.000001 &&
        (p.lengthPenalty + 1.0).abs() < 0.000001 &&
        (p.temperatureInc - 0.2).abs() < 0.000001 &&
        (p.entropyThold - 2.4).abs() < 0.000001 &&
        (p.logprobThold + 1.0).abs() < 0.000001 &&
        (p.noSpeechThold - 0.6).abs() < 0.000001 &&
        p.greedyBestOf == 5;
  }

  void freeParams(Pointer<Void> params) => _freeParams(params);

  void free(Pointer<Void> context) => _free(context);

  /// Runs full-file inference over the float32 samples.
  ///
  /// Returns `0` on success and a negative whisper error code otherwise.
  int run(Pointer<Void> context, Pointer<Void> params, Float32List samples) {
    if (samples.isEmpty) {
      return 0;
    }
    final buffer = malloc<Float>(samples.length);
    try {
      buffer.asTypedList(samples.length).setAll(0, samples);
      return _full(context, params, buffer, samples.length);
    } finally {
      malloc.free(buffer);
    }
  }

  int segmentCount(Pointer<Void> context) => _fullNSegments(context);

  /// Text of one decoded segment. whisper.cpp keeps pointer ownership, so the
  /// string is copied immediately.
  String segmentText(Pointer<Void> context, int segment) =>
      _fullGetSegmentText(context, segment).toDartString();
}
