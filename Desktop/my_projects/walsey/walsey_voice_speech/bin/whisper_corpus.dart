// Transcribes a WAV corpus through the app's real whisper.cpp FFI path.
//
// Unlike tools/voice_accuracy/run_whisper_corpus.ps1 (which drives the
// whisper-cli binary and therefore can only approximate the app's parameter
// struct), this harness links the exact same `WhisperBindings` the app ships:
// the same by-ref default parameters, the same greedy strategy, the same
// vocabulary prompt and the same struct-layout guard. It is the reference for
// "what the app would actually decode".
//
// Usage (inside walsey_voice_speech, with the real DLLs + model present):
//   dart run bin/whisper_corpus.dart \
//     --corpus <folder with expected.tsv + WAVs> \
//     --model <ggml-base.en.bin> \
//     --whisper-dir <folder with whisper.dll + ggml*.dll> \
//     [--no-prompt] [--out result.tsv]
//
// The TSV is `<file name>TAB<transcript>TAB<decode milliseconds>`, the same
// shape the PowerShell runner writes, so bin/voice_accuracy.dart
// --transcripts scores it with the shared parser/metrics code.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:walsey_voice_speech/src/diagnostics/wav.dart';
import 'package:walsey_voice_speech/src/whisper/whisper_bindings.dart';
import 'package:walsey_voice_speech/src/whisper/whisper_pcm.dart';
import 'package:walsey_voice_speech/src/whisper/whisper_speech_engine.dart';

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  if (options == null) {
    exit(64);
  }

  final corpus = Directory(options.corpusDirectory);
  final manifest = File('${corpus.path}${Platform.pathSeparator}expected.tsv');
  final modelFile = File(options.modelPath);
  if (!corpus.existsSync() || !manifest.existsSync()) {
    stderr.writeln('Corpus or expected.tsv not found: ${corpus.path}');
    exit(2);
  }
  if (!modelFile.existsSync()) {
    stderr.writeln('Model not found: ${modelFile.path}');
    exit(2);
  }

  final separator = Platform.pathSeparator;
  final bindings = WhisperBindings.load(
    ggmlLibraryPath: '${options.whisperDirectory}${separator}ggml.dll',
    whisperLibraryPath: '${options.whisperDirectory}${separator}whisper.dll',
    backendSearchPath: options.whisperDirectory,
  );
  bindings.loadBackends();

  final model = bindings.initFromFile(modelFile.path);
  if (model.address == 0) {
    stderr.writeln('Whisper could not load ${modelFile.path}');
    exit(3);
  }
  final params = bindings.createParams();
  if (params.address == 0) {
    stderr.writeln('Whisper did not return default parameters');
    bindings.free(model);
    exit(3);
  }

  final prompt = options.usePrompt ? whisperVocabularyPrompt : null;
  final promptPointer = prompt?.toNativeUtf8();
  var promptApplied = false;
  if (prompt != null && promptPointer != null) {
    promptApplied = WhisperBindings.setInitialPrompt(params, promptPointer);
    if (!promptApplied) {
      stderr.writeln(
        'The vocabulary prompt was rejected by the parameter-struct guard; '
        'this run is un-prompted. This is a layout mismatch, not a decode '
        'failure.',
      );
    }
  }
  print('prompt       ${promptApplied ? 'applied' : 'not applied'}');
  if (promptApplied) print('prompt text  $prompt');

  if (options.bestOf != null) {
    final applied = WhisperBindings.setGreedyBestOf(params, options.bestOf!);
    print('greedy bestOf ${options.bestOf} ${applied ? 'applied' : 'rejected'}');
    if (!applied) exit(5);
  }

  final entries = manifest
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => line.split('\t').first.trim())
      .toList();

  final results = <String>[];
  var totalMs = 0.0;
  var failures = 0;
  for (final name in entries) {
    final audio = File('${corpus.path}$separator$name');
    if (!audio.existsSync()) {
      stderr.writeln('missing audio: $name');
      continue;
    }
    final wav = decodePcm16Wav(audio.readAsBytesSync());
    if (!wav.isRecognizerFormat) {
      stderr.writeln('$name is ${wav.description}; need 16 kHz mono PCM16');
      failures++;
      continue;
    }
    final samples = pcm16ToFloat32(wav.pcm);
    final clock = Stopwatch()..start();
    final code = bindings.run(model, params, samples);
    clock.stop();
    if (code != 0) {
      stderr.writeln('$name: whisper_full failed with $code');
      failures++;
      continue;
    }
    final segments = <String>[];
    final count = bindings.segmentCount(model);
    for (var index = 0; index < count; index++) {
      segments.add(bindings.segmentText(model, index));
    }
    final text = segments.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final ms = clock.elapsedMilliseconds;
    totalMs += ms;
    results.add('$name\t$text\t$ms');
  }

  final outPath =
      options.outputPath ??
      '${corpus.path}$separator'
          'whisper_ffi${promptApplied ? '_prompt' : ''}.tsv';
  File(outPath).writeAsStringSync('${results.join('\n')}\n');

  print('');
  print('files        ${results.length}');
  print('engine time  ${totalMs.toStringAsFixed(0)} ms');
  print('wrote        $outPath');
  if (failures > 0) {
    stderr.writeln('$failures file(s) could not be decoded');
  }

  if (params.address != 0) bindings.freeParams(params);
  if (promptPointer != null) malloc.free(promptPointer);
  bindings.free(model);
  exit(failures > 0 ? 4 : 0);
}

final class _Options {
  const _Options({
    required this.corpusDirectory,
    required this.modelPath,
    required this.whisperDirectory,
    required this.usePrompt,
    required this.outputPath,
    required this.bestOf,
  });

  final String corpusDirectory;
  final String modelPath;
  final String whisperDirectory;
  final bool usePrompt;
  final String? outputPath;

  /// Greedy candidate count to force, or `null` to keep whisper.cpp's default.
  final int? bestOf;

  static _Options? parse(List<String> arguments) {
    String? corpus;
    String? model;
    String? whisperDirectory;
    String? out;
    int? bestOf;
    var usePrompt = true;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      String? value() =>
          index + 1 < arguments.length ? arguments[++index] : null;
      switch (argument) {
        case '--corpus':
          corpus = value();
        case '--model':
          model = value();
        case '--whisper-dir':
          whisperDirectory = value();
        case '--out':
          out = value();
        case '--best-of':
          bestOf = int.tryParse(value() ?? '');
          if (bestOf == null) {
            stderr.writeln('--best-of needs a number');
            return null;
          }
        case '--no-prompt':
          usePrompt = false;
        case '--help' || '-h':
          print(
            'usage: dart run bin/whisper_corpus.dart --corpus <dir> '
            '--model <ggml-*.bin> --whisper-dir <dir> [--no-prompt] '
            '[--best-of 1] [--out tsv]',
          );
          return null;
        default:
          stderr.writeln('unknown option: $argument');
          return null;
      }
    }
    if (corpus == null || model == null || whisperDirectory == null) {
      stderr.writeln(
        'need --corpus, --model and --whisper-dir (see --help)',
      );
      return null;
    }
    return _Options(
      corpusDirectory: corpus,
      modelPath: model,
      whisperDirectory: whisperDirectory,
      usePrompt: usePrompt,
      outputPath: out,
      bestOf: bestOf,
    );
  }
}
