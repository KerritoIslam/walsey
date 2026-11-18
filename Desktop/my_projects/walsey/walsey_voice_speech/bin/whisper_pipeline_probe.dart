// End-to-end probe: real WAV -> production Whisper engine (worker isolate) ->
// unchanged Stage 1 parser. Nothing here is mocked: the same
// `WhisperSpeechEngine` the app uses performs the inference.
//
// It exists so the voice pipeline can be exercised on recorded audio without a
// microphone, and so a platform can be checked without the UI. It never sends a
// command anywhere.
//
// Usage:
//   dart run bin/whisper_pipeline_probe.dart \
//     --model <ggml-base.en.bin> --wav <16 kHz mono PCM16 wav> \
//     --library-dir <folder containing whisper.dll / libwhisper.so> [--json]
//
// On Windows the shorthand `--library-dir apps/walsey_voice_test/build/windows/x64/runner/Debug`
// points at the DLLs the built testbed already has. On Android there is no
// command-line Dart runtime; the app itself is the probe there.
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/src/whisper/whisper_speech_engine.dart';

const int _expectedSampleRate = 16000;

Future<void> main(List<String> arguments) async {
  final modelPath = _stringArgument(arguments, '--model');
  final wavPath = _stringArgument(arguments, '--wav');
  final libraryDir = _stringArgument(arguments, '--library-dir');
  final ggmlPath = _stringArgument(arguments, '--ggml');
  final whisperPath = _stringArgument(arguments, '--whisper');
  final asJson = arguments.contains('--json');

  if (modelPath == null || wavPath == null) {
    stderr.writeln(
      'usage: whisper_pipeline_probe --model <model.bin> --wav <file.wav> '
      '[--library-dir <dir>] [--ggml <lib>] [--whisper <lib>] [--json]',
    );
    exit(64);
  }
  if (!File(modelPath).existsSync()) {
    stderr.writeln('model not found: $modelPath');
    exit(66);
  }
  if (!File(wavPath).existsSync()) {
    stderr.writeln('wav not found: $wavPath');
    exit(66);
  }

  final WavAudio audio;
  try {
    audio = _readWav(File(wavPath).readAsBytesSync());
  } on FormatException catch (error) {
    stderr.writeln('unsupported wav: ${error.message}');
    exit(65);
  }

  final engine = await WhisperSpeechEngine.spawn(
    ggmlLibraryPath: ggmlPath ?? _inDirectory(libraryDir, 'ggml.dll', 'libggml.so'),
    whisperLibraryPath:
        whisperPath ?? _inDirectory(libraryDir, 'whisper.dll', 'libwhisper.so'),
    backendSearchPath: libraryDir,
  );

  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'model': modelPath,
    'modelBytes': File(modelPath).lengthSync(),
    'wav': wavPath,
    'audioSeconds': audio.durationSeconds,
    'sampleRate': audio.sampleRate,
  };

  try {
    final loadClock = Stopwatch()..start();
    await engine.loadModel(modelPath);
    loadClock.stop();
    await engine.beginSession(sampleRate: audio.sampleRate);
    engine.accept(audio.pcm);
    final decodeClock = Stopwatch()..start();
    final transcript = await engine.finish();
    decodeClock.stop();

    report['modelLoadMs'] = loadClock.elapsedMilliseconds;
    report['decodeMs'] = decodeClock.elapsedMilliseconds;
    report['realTimeFactor'] =
        audio.durationSeconds == 0
            ? null
            : decodeClock.elapsedMilliseconds / (audio.durationSeconds * 1000);
    report['transcript'] = transcript;

    final parser = VoiceCommandParser();
    final result = parser.parse(transcript ?? '');
    switch (result) {
      case VoiceCommandResult(:final command):
        report['parsed'] = {
          'ok': true,
          'action': command.actionId,
          'parameters': command.parameters.summary.join('; '),
          'executionStatus': result.executionStatus.name,
        };
      case VoiceFailure(:final kind, :final explanation, :final intent):
        report['parsed'] = {
          'ok': false,
          'kind': kind.name,
          'intent': intent?.name,
          'explanation': explanation,
          'executionStatus': result.executionStatus.name,
        };
    }
  } on Object catch (error) {
    report['error'] = error.toString();
  } finally {
    await engine.dispose();
  }

  if (asJson) {
    print(const JsonEncoder.withIndent('  ').convert(report));
  } else {
    print('platform        : ${report['platform']}');
    print('model           : ${report['model']} '
        '(${_megabytes(report['modelBytes'] as int)} MiB)');
    print('audio           : ${report['audioSeconds']} s @ '
        '${report['sampleRate']} Hz');
    if (report['modelLoadMs'] != null) {
      print('model load      : ${report['modelLoadMs']} ms');
      print('decode          : ${report['decodeMs']} ms '
          '(RTF ${(report['realTimeFactor'] as double).toStringAsFixed(2)})');
    }
    print('raw transcript  : "${report['transcript'] ?? ''}"');
    final parsed = report['parsed'];
    if (parsed is Map) {
      if (parsed['ok'] == true) {
        print('parser          : ${parsed['action']} '
            '${parsed['parameters']}');
      } else {
        print('parser          : ${parsed['kind']} '
            '${parsed['explanation']}');
      }
      print('execution       : ${parsed['executionStatus']}');
    }
    final error = report['error'];
    if (error != null) {
      print('error           : $error');
    }
  }

  final failed = report.containsKey('error') || report['transcript'] == null;
  exit(failed ? 1 : 0);
}

String? _inDirectory(String? directory, String windowsName, String androidName) {
  if (directory == null) {
    return null;
  }
  final name = Platform.isWindows ? windowsName : androidName;
  return '$directory${Platform.pathSeparator}$name';
}

String? _stringArgument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) {
    return null;
  }
  return arguments[index + 1];
}

String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

final class WavAudio {
  const WavAudio({
    required this.pcm,
    required this.sampleRate,
    required this.durationSeconds,
  });

  final Uint8List pcm;
  final int sampleRate;
  final double durationSeconds;
}

/// Minimal RIFF/WAVE reader that refuses anything the engine cannot consume.
WavAudio _readWav(Uint8List bytes) {
  if (bytes.length < 44 ||
      _ascii(bytes, 0, 4) != 'RIFF' ||
      _ascii(bytes, 8, 4) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }
  final data = ByteData.sublistView(bytes);
  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  int? format;
  Uint8List? pcm;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = _ascii(bytes, offset, 4);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (body + chunkSize > bytes.length) {
      throw FormatException('truncated "$chunkId" chunk');
    }
    switch (chunkId) {
      case 'fmt ':
        if (chunkSize < 16) {
          throw const FormatException('fmt chunk is too small');
        }
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
      case 'data':
        pcm = Uint8List.sublistView(bytes, body, body + chunkSize);
    }
    offset = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
  }

  if (format != 1) {
    throw const FormatException('only uncompressed PCM is supported');
  }
  if (channels != 1) {
    throw FormatException('expected mono, got $channels channels');
  }
  final rate = sampleRate;
  if (rate == null || rate != _expectedSampleRate) {
    throw FormatException(
      'expected $_expectedSampleRate Hz, got $rate Hz',
    );
  }
  if (bitsPerSample != 16) {
    throw FormatException('expected 16-bit samples, got $bitsPerSample');
  }
  if (pcm == null || pcm.isEmpty) {
    throw const FormatException('no audio data');
  }
  if (pcm.length.isOdd) {
    throw const FormatException('an odd number of bytes is not 16-bit PCM');
  }
  final seconds = pcm.length / (rate * 2);
  return WavAudio(pcm: pcm, sampleRate: rate, durationSeconds: seconds);
}

String _ascii(Uint8List bytes, int offset, int length) =>
    String.fromCharCodes(bytes, offset, offset + length);
