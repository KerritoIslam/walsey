// Manual POC for the whisper.cpp by-ref FFI API (run with the real DLLs and
// model; see docs/voice_stage2.md). It exists to print what it finds, which is
// exactly what the linter would otherwise complain about.
// ignore_for_file: avoid_print
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

typedef WhisperInitFromFileNative = Pointer<Void> Function(Pointer<Utf8> pathModel);
typedef WhisperInitFromFileDart = Pointer<Void> Function(Pointer<Utf8> pathModel);

typedef WhisperFreeNative = Void Function(Pointer<Void> ctx);
typedef WhisperFreeDart = void Function(Pointer<Void> ctx);

typedef WhisperFullDefaultParamsByRefNative = Pointer<Void> Function(Int32 strategy);
typedef WhisperFullDefaultParamsByRefDart = Pointer<Void> Function(int strategy);

typedef WhisperFreeParamsNative = Void Function(Pointer<Void> params);
typedef WhisperFreeParamsDart = void Function(Pointer<Void> params);

typedef WhisperFullNative = Int32 Function(
  Pointer<Void> ctx,
  Pointer<Void> params,
  Pointer<Float> samples,
  Int32 nSamples,
);
typedef WhisperFullDart = int Function(
  Pointer<Void> ctx,
  Pointer<Void> params,
  Pointer<Float> samples,
  int nSamples,
);

typedef WhisperFullNSegmentsNative = Int32 Function(Pointer<Void> ctx);
typedef WhisperFullNSegmentsDart = int Function(Pointer<Void> ctx);

typedef WhisperFullGetSegmentTextNative = Pointer<Utf8> Function(Pointer<Void> ctx, Int32 iSegment);
typedef WhisperFullGetSegmentTextDart = Pointer<Utf8> Function(Pointer<Void> ctx, int iSegment);

typedef GgmlBackendLoadAllFromPathNative = Void Function(Pointer<Utf8> searchPath);
typedef GgmlBackendLoadAllFromPathDart = void Function(Pointer<Utf8> searchPath);

void main() {
  final binDir = r'C:\Users\NITRO\AppData\Local\Temp\opencode\voice_diag\whisper\bin\Release';
  final ggmlDllPath = '$binDir\\ggml.dll';
  final dllPath = '$binDir\\whisper.dll';

  print('Loading $ggmlDllPath');
  final ggmlDylib = DynamicLibrary.open(ggmlDllPath);
  final loadBackends = ggmlDylib.lookupFunction<GgmlBackendLoadAllFromPathNative, GgmlBackendLoadAllFromPathDart>('ggml_backend_load_all_from_path');
  final binDirNative = binDir.toNativeUtf8();
  loadBackends(binDirNative);
  calloc.free(binDirNative);
  print('Backends loaded from $binDir');

  print('Loading $dllPath');
  final dylib = DynamicLibrary.open(dllPath);

  final initFromFile = dylib.lookupFunction<WhisperInitFromFileNative, WhisperInitFromFileDart>('whisper_init_from_file');
  final freeCtx = dylib.lookupFunction<WhisperFreeNative, WhisperFreeDart>('whisper_free');
  final defaultParamsByRef = dylib.lookupFunction<WhisperFullDefaultParamsByRefNative, WhisperFullDefaultParamsByRefDart>('whisper_full_default_params_by_ref');
  final freeParams = dylib.lookupFunction<WhisperFreeParamsNative, WhisperFreeParamsDart>('whisper_free_params');
  final whisperFull = dylib.lookupFunction<WhisperFullNative, WhisperFullDart>('whisper_full');
  final nSegments = dylib.lookupFunction<WhisperFullNSegmentsNative, WhisperFullNSegmentsDart>('whisper_full_n_segments');
  final getSegmentText = dylib.lookupFunction<WhisperFullGetSegmentTextNative, WhisperFullGetSegmentTextDart>('whisper_full_get_segment_text');

  print('All symbols resolved successfully!');

  final modelPath = r'C:\Users\NITRO\AppData\Local\Temp\opencode\voice_diag\whisper\ggml-base.en.bin';
  final modelPathNative = modelPath.toNativeUtf8();
  print('Initializing model from $modelPath...');
  final ctx = initFromFile(modelPathNative);
  calloc.free(modelPathNative);

  if (ctx.address == 0) {
    print('Failed to initialize model!');
    exit(1);
  }
  print('Model initialized successfully: ctx = ${ctx.address.toRadixString(16)}');

  // strategy 0 = WHISPER_SAMPLING_GREEDY, 1 = WHISPER_SAMPLING_BEAM_SEARCH
  final params = defaultParamsByRef(0);
  print('Params created: ${params.address.toRadixString(16)}');

  final wavPath = r'C:\Users\NITRO\AppData\Local\Temp\opencode\voice_diag\corpus\01-01-microsoft-david-desktop.wav';
  print('Loading audio from $wavPath');
  final wavBytes = File(wavPath).readAsBytesSync();
  // WAV header is 44 bytes for standard PCM16
  final pcmBytes = wavBytes.sublist(44);
  final byteData = ByteData.sublistView(pcmBytes);
  final sampleCount = pcmBytes.length ~/ 2;
  final samples = calloc<Float>(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    final s16 = byteData.getInt16(i * 2, Endian.little);
    samples[i] = s16 / 32768.0;
  }

  print('Running whisper_full on $sampleCount samples...');
  final clock = Stopwatch()..start();
  final res = whisperFull(ctx, params, samples, sampleCount);
  clock.stop();
  print('whisper_full returned $res in ${clock.elapsedMilliseconds} ms');

  final segments = nSegments(ctx);
  print('Segments count: $segments');
  final transcriptBuffer = StringBuffer();
  for (var i = 0; i < segments; i++) {
    final textPtr = getSegmentText(ctx, i);
    final text = textPtr.toDartString();
    print('Segment $i: $text');
    transcriptBuffer.write(text);
  }
  print('Full transcript: "${transcriptBuffer.toString().trim()}"');

  calloc.free(samples);
  freeParams(params);
  freeCtx(ctx);
  print('Cleaned up successfully!');
}
