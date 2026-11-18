// Repeatable wake-phrase benchmark for the streaming Vosk detector.
//
// This runs the *production* detector (`VoskWakeWordDetector`, a real Vosk
// worker isolate and the real phonetic matcher) over recorded WAV files. It
// measures what the unit tests cannot: detection rate, misses, false
// activations and detection offset on actual audio.
//
// Usage (inside walsey_voice_speech):
//   dart run bin/wake_accuracy.dart --model <vosk model dir> \
//     --corpus <folder with expected.tsv + WAVs> [--out result.json] [-v]
//
// `expected.tsv` uses the same polarity convention as the command benchmark:
//   <file name>TAB<spoken sentence>      must trigger
//   <file name>TAB!<spoken sentence>     must NOT trigger
//
// Generate a corpus with tools/voice_accuracy/make_tts_corpus.ps1 pointed at
// tools/voice_accuracy/wake.txt. Synthetic speech is a regression baseline, not
// proof of acoustic robustness; human recordings are still required.
//
// No BLE, no command execution, no transcript correction and no network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/src/audio/audio_capture_port.dart';
import 'package:walsey_voice_speech/src/diagnostics/wav.dart';
import 'package:walsey_voice_speech/src/vosk/vosk_speech_engine.dart';
import 'package:walsey_voice_speech/src/wake/vosk_wake_word_detector.dart';

/// 100 ms at 16 kHz mono PCM16, the same chunk size the live capture path uses.
const _chunkBytes = 3200;

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    exit(64);
  }
  exit(await _run(options));
}

Future<int> _run(_Options options) async {
  final corpus = Directory(options.corpusPath);
  final manifest = File(p.join(corpus.path, 'expected.tsv'));
  if (!manifest.existsSync()) {
    stderr.writeln('No expected.tsv in ${corpus.path}');
    return 66;
  }
  final allItems = _readManifest(manifest);
  if (allItems.isEmpty) {
    stderr.writeln('expected.tsv has no entries.');
    return 65;
  }
  final items = options.limit > 0 && options.limit < allItems.length
      ? allItems.sublist(0, options.limit)
      : allItems;
  if (!Directory(options.modelPath).existsSync()) {
    stderr.writeln('Model folder not found: ${options.modelPath}');
    return 66;
  }

  final capture = _FileReplayCapture();
  final engine = await VoskSpeechEngine.spawn();
  final detector = VoskWakeWordDetector(
    engine: engine,
    capture: capture,
    modelPath: options.modelPath,
    onTranscript: options.verbose
        ? (text) => stdout.writeln('   heard: $text')
        : null,
  );

  final results = <_ClipResult>[];
  final loadClock = Stopwatch();
  var modelLoadMs = 0;
  var rssBefore = 0;
  var rssAfterLoad = 0;

  try {
    // Load the model once, through the first start(), and measure it.
    final first = items.first;
    final firstWav = _readWav(corpus, first);
    if (firstWav == null) return 65;
    rssBefore = ProcessInfo.currentRss;
    loadClock.start();
    await detector.start();
    loadClock.stop();
    modelLoadMs = loadClock.elapsedMilliseconds;
    rssAfterLoad = ProcessInfo.currentRss;

    results.add(await _measure(detector, capture, first, firstWav, options));
    await detector.stop();

    for (final item in items.skip(1)) {
      final wav = _readWav(corpus, item);
      if (wav == null) continue;
      await detector.start();
      results.add(await _measure(detector, capture, item, wav, options));
      await detector.stop();
    }
  } finally {
    await detector.dispose();
  }

  final rssEnd = ProcessInfo.currentRss;
  if (results.isEmpty) {
    stderr.writeln('No clip could be measured.');
    return 70;
  }

  final positives = results.where((r) => r.expectsWake).toList();
  final negatives = results.where((r) => !r.expectsWake).toList();
  final detections = positives.where((r) => r.detected).length;
  final falseActivations = negatives.where((r) => r.detected).length;
  final negativeSeconds = negatives.fold<double>(
    0,
    (sum, r) => sum + r.audioSeconds,
  );
  final positiveSeconds = positives.fold<double>(
    0,
    (sum, r) => sum + r.audioSeconds,
  );
  final offsets = positives
      .where((r) => r.detected && r.detectionOffsetSeconds != null)
      .map((r) => r.detectionOffsetSeconds!)
      .toList()
    ..sort();
  final decodeSeconds = results.fold<double>(0, (s, r) => s + r.decodeSeconds);
  final audioSeconds = results.fold<double>(0, (s, r) => s + r.audioSeconds);

  if (options.verbose) {
    stdout.writeln('=== per clip ===');
    for (final result in results) {
      final label = result.expectsWake
          ? (result.detected ? 'HIT ' : 'MISS')
          : (result.detected ? 'FALSE!' : 'ok  ');
      stdout.writeln(
        '$label ${result.fileName}  '
        'offset=${result.detectionOffsetSeconds == null ? "-" : "${(result.detectionOffsetSeconds! * 1000).toStringAsFixed(0)} ms"}  '
        'audio=${result.audioSeconds.toStringAsFixed(1)} s',
      );
      if (result.expectsWake && !result.detected) {
        stdout.writeln('   expected a trigger from: ${result.sentence}');
      }
      if (!result.expectsWake && result.detected) {
        stdout.writeln('   FALSE ACTIVATION on: ${result.sentence}');
      }
    }
    stdout.writeln('');
  }

  stdout.writeln('=== environment ===');
  stdout.writeln('dart             ${Platform.version}');
  stdout.writeln(
    'os               ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );
  stdout.writeln('model            ${options.modelPath}');
  stdout.writeln('detector         ${detector.engineName}');
  stdout.writeln('model load       $modelLoadMs ms (first start)');
  stdout.writeln(
    'rss              ${_mb(rssBefore)} before, ${_mb(rssAfterLoad)} after load, '
    '${_mb(rssEnd)} after run',
  );
  stdout.writeln('');
  stdout.writeln('=== results ===');
  stdout.writeln('clips                 ${results.length}');
  stdout.writeln('positives             ${positives.length}');
  stdout.writeln(
    'detected              $detections/${positives.length} '
    '(${_percent(detections, positives.length)})',
  );
  stdout.writeln(
    'missed                ${positives.length - detections}/${positives.length}',
  );
  stdout.writeln('negatives             ${negatives.length}');
  stdout.writeln(
    'false activations     $falseActivations/${negatives.length} '
    '(${_percent(falseActivations, negatives.length)})',
  );
  stdout.writeln(
    'false activations/h   ${_ratePerHour(falseActivations, negativeSeconds)} '
    'over ${negativeSeconds.toStringAsFixed(1)} s of negative audio',
  );
  if (offsets.isNotEmpty) {
    final mean = offsets.reduce((a, b) => a + b) / offsets.length;
    final median = offsets[(offsets.length - 1) ~/ 2];
    stdout.writeln(
      'detection offset      mean ${(mean * 1000).toStringAsFixed(0)} ms, '
      'median ${(median * 1000).toStringAsFixed(0)} ms '
      '(from clip start to the event)',
    );
  }
  stdout.writeln(
    'positive audio        ${positiveSeconds.toStringAsFixed(1)} s',
  );
  stdout.writeln(
    'decode                ${decodeSeconds.toStringAsFixed(2)} s total, '
    'real time factor '
    '${(decodeSeconds / math.max(audioSeconds, 1e-9)).toStringAsFixed(3)}',
  );
  stdout.writeln(
    'note                  CPU% is not sampled by this harness; RTF above is '
    'the measured decode cost.',
  );

  final report = <String, Object?>{
    'kind': 'walsey-wake-accuracy',
    'generatedAt': DateTime.now().toIso8601String(),
    'environment': {
      'dart': Platform.version,
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'modelPath': options.modelPath,
      'detector': detector.engineName,
      'modelLoadMs': modelLoadMs,
      'rssBeforeBytes': rssBefore,
      'rssAfterLoadBytes': rssAfterLoad,
      'rssAfterRunBytes': rssEnd,
    },
    'summary': {
      'clips': results.length,
      'positives': positives.length,
      'detected': detections,
      'detectionRate': positives.isEmpty
          ? null
          : double.parse((detections / positives.length).toStringAsFixed(4)),
      'missed': positives.length - detections,
      'negatives': negatives.length,
      'falseActivations': falseActivations,
      'falseActivationRate': negatives.isEmpty
          ? null
          : double.parse(
              (falseActivations / negatives.length).toStringAsFixed(4),
            ),
      'falseActivationsPerHour': _parsePerHour(
        falseActivations,
        negativeSeconds,
      ),
      'negativeAudioSeconds':
          double.parse(negativeSeconds.toStringAsFixed(1)),
      'meanDetectionOffsetSeconds': offsets.isEmpty
          ? null
          : double.parse(
              (offsets.reduce((a, b) => a + b) / offsets.length)
                  .toStringAsFixed(4),
            ),
      'medianDetectionOffsetSeconds': offsets.isEmpty
          ? null
          : double.parse(offsets[(offsets.length - 1) ~/ 2].toStringAsFixed(4)),
      'audioSeconds': double.parse(audioSeconds.toStringAsFixed(1)),
      'decodeSeconds': double.parse(decodeSeconds.toStringAsFixed(3)),
      'realTimeFactor': double.parse(
        (decodeSeconds / math.max(audioSeconds, 1e-9)).toStringAsFixed(4),
      ),
    },
    'items': [for (final result in results) result.toJson()],
  };
  if (options.outPath != null) {
    final out = File(options.outPath!);
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('');
    stdout.writeln('wrote ${out.path}');
  }
  return 0;
}

Future<_ClipResult> _measure(
  VoskWakeWordDetector detector,
  _FileReplayCapture capture,
  _CorpusItem item,
  WavData wav,
  _Options options,
) async {
  WakeWordDetected? detection;
  WakeWordFailed? failure;
  double? offset;
  final subscription = detector.events.listen((event) {
    if (event is WakeWordDetected && detection == null) {
      detection = event;
      // Bytes already handed to the engine when the event arrived: the decoder
      // can only have seen audio up to this point.
      offset = capture.audioSecondsFed;
    } else if (event is WakeWordFailed && failure == null) {
      failure = event;
    }
  });
  final clock = Stopwatch()..start();
  capture.play(wav.pcm);
  await capture.drained;
  // Give the worker isolate time to emit the final partial for this clip.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  clock.stop();
  await subscription.cancel();

  if (failure != null && options.verbose) {
    stderr.writeln('${item.fileName}: detector failed: ${failure!.message}');
  }
  return _ClipResult(
    fileName: item.fileName,
    sentence: item.sentence,
    expectsWake: item.expectsWake,
    detected: detection != null,
    detectionOffsetSeconds: offset,
    audioSeconds: wav.durationSeconds,
    decodeSeconds: clock.elapsedMicroseconds / 1e6,
  );
}

WavData? _readWav(Directory corpus, _CorpusItem item) {
  final file = File(p.join(corpus.path, item.fileName));
  if (!file.existsSync()) {
    stderr.writeln('missing file: ${file.path}');
    return null;
  }
  try {
    final wav = decodePcm16Wav(file.readAsBytesSync());
    if (!wav.isRecognizerFormat) {
      stderr.writeln(
        '${item.fileName}: ${wav.description} is not 16 kHz mono PCM16.',
      );
      return null;
    }
    return wav;
  } on FormatException catch (error) {
    stderr.writeln('${item.fileName}: ${error.message}');
    return null;
  }
}

/// Replays a WAV through the [AudioCapture] seam as fast as the consumer
/// accepts it. Not real time: decode cost is measured by the clock instead.
final class _FileReplayCapture implements AudioCapture {
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  Completer<void> _drained = Completer<void>()..complete();
  int _bytesFed = 0;
  int _sampleRate = 16000;

  double get audioSecondsFed => _bytesFed / (_sampleRate * 2);

  Future<void> get drained => _drained.future;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> startStream({required int sampleRate}) async {
    _sampleRate = sampleRate;
    return _controller.stream;
  }

  void play(Uint8List pcm) {
    _bytesFed = 0;
    _drained = Completer<void>();
    unawaited(_feed(pcm));
  }

  Future<void> _feed(Uint8List pcm) async {
    for (var offset = 0; offset < pcm.length; offset += _chunkBytes) {
      if (_controller.isClosed) break;
      final end = math.min(offset + _chunkBytes, pcm.length);
      _controller.add(Uint8List.sublistView(pcm, offset, end));
      _bytesFed = end;
      // Yield so the isolate mailbox and the event stream stay interleaved.
      await Future<void>.delayed(Duration.zero);
    }
    if (!_drained.isCompleted) _drained.complete();
  }

  @override
  Future<void> stop() async {
    _bytesFed = 0;
  }

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}

final class _CorpusItem {
  const _CorpusItem(this.fileName, this.sentence, this.expectsWake);

  final String fileName;
  final String sentence;
  final bool expectsWake;
}

List<_CorpusItem> _readManifest(File manifest) {
  final items = <_CorpusItem>[];
  for (final raw in manifest.readAsLinesSync()) {
    final line = raw.replaceFirst('\uFEFF', '');
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final tab = line.indexOf('\t');
    if (tab <= 0) continue;
    final name = line.substring(0, tab).trim();
    var sentence = line.substring(tab + 1).trim();
    if (name.isEmpty || sentence.isEmpty) continue;
    final expectsWake = !sentence.startsWith('!');
    if (!expectsWake) sentence = sentence.substring(1).trim();
    items.add(_CorpusItem(name, sentence, expectsWake));
  }
  return items;
}

final class _ClipResult {
  const _ClipResult({
    required this.fileName,
    required this.sentence,
    required this.expectsWake,
    required this.detected,
    required this.detectionOffsetSeconds,
    required this.audioSeconds,
    required this.decodeSeconds,
  });

  final String fileName;
  final String sentence;
  final bool expectsWake;
  final bool detected;
  final double? detectionOffsetSeconds;
  final double audioSeconds;
  final double decodeSeconds;

  Map<String, Object?> toJson() => {
        'file': fileName,
        'sentence': sentence,
        'expectsWake': expectsWake,
        'detected': detected,
        'detectionOffsetSeconds': detectionOffsetSeconds == null
            ? null
            : double.parse(detectionOffsetSeconds!.toStringAsFixed(4)),
        'audioSeconds': double.parse(audioSeconds.toStringAsFixed(3)),
        'decodeSeconds': double.parse(decodeSeconds.toStringAsFixed(3)),
      };
}

final class _Options {
  const _Options({
    required this.modelPath,
    required this.corpusPath,
    required this.outPath,
    required this.verbose,
    required this.limit,
  });

  final String modelPath;
  final String corpusPath;
  final String? outPath;
  final bool verbose;
  final int limit;

  static _Options? parse(List<String> arguments) {
    String? model;
    String? corpus;
    String? out;
    var verbose = false;
    var limit = 0;
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      switch (argument) {
        case '--model':
          model = _value(arguments, ++i, argument);
        case '--corpus':
          corpus = _value(arguments, ++i, argument);
        case '--out':
          out = _value(arguments, ++i, argument);
        case '--limit':
          limit = int.tryParse(_value(arguments, ++i, argument) ?? '') ?? 0;
        case '--verbose':
        case '-v':
          verbose = true;
        case '--help':
        case '-h':
          _usage();
          return null;
        default:
          stderr.writeln('Unknown argument: $argument');
          _usage();
          return null;
      }
    }
    if (model == null || corpus == null) {
      _usage();
      return null;
    }
    return _Options(
      modelPath: model,
      corpusPath: corpus,
      outPath: out,
      verbose: verbose,
      limit: limit,
    );
  }

  static String? _value(List<String> arguments, int index, String name) {
    if (index >= arguments.length) {
      stderr.writeln('$name needs a value');
      return null;
    }
    return arguments[index];
  }

  static void _usage() {
    stderr.writeln(
      'usage: dart run bin/wake_accuracy.dart --model <dir> --corpus <dir> '
      '[--out <json>] [--limit <n>] [-v]',
    );
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _percent(int part, int total) =>
    total == 0 ? '0%' : '${(100 * part / total).toStringAsFixed(1)}%';

String _ratePerHour(int events, double seconds) {
  final rate = _parsePerHour(events, seconds);
  return rate == null ? 'n/a' : rate.toStringAsFixed(2);
}

double? _parsePerHour(int events, double seconds) => seconds <= 0
    ? null
    : double.parse((events * 3600 / seconds).toStringAsFixed(2));
