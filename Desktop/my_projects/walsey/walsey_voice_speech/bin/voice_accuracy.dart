// Repeatable speech-recognition accuracy measurement.
//
// This is a measurement tool, not part of the app: it drives the exact same
// `dart:ffi` Vosk bindings the app uses, but feeds WAV files instead of a
// microphone so a run is deterministic and repeatable.
//
// Usage (inside walsey_voice_speech):
//   dart run bin/voice_accuracy.dart \
//     --model <model folder> --corpus <folder with expected.tsv + WAVs> \
//     [--library <libvosk path>] [--grammar [--unk]] [--out result.json] [--verbose]
//
// Another engine (for example whisper.cpp) can be scored on the exact same
// recordings with `--transcripts <file.tsv>`, where each line is
// `<file name>\t<raw transcript>[\t<decode milliseconds>]`. The parser and all
// metrics are shared with the Vosk path, so the comparison is apples to apples.
//
// Every WAV must be 16 kHz, mono, 16-bit PCM: the format the recognizer asks
// the microphone for. A file with another format is rejected, never resampled.
//
// The script reports exact-sentence accuracy and word error rate separately,
// plus whether the *expected* sentence parses (a corpus sanity check) and
// whether the *transcript* parses to the same intent and parameters.
//
// It never sends an LED frame, never executes a command and never changes the
// parser: `VoiceResult.executionStatus` stays `notExecuted`.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/src/diagnostics/audio_stats.dart';
import 'package:walsey_voice_speech/src/diagnostics/wav.dart';
import 'package:walsey_voice_speech/src/vosk/vosk_bindings.dart';
import 'package:walsey_voice_speech/src/vosk/vosk_model_info.dart';
import 'package:walsey_voice_speech/src/vosk/vosk_result.dart';

/// One expected sentence and its audio file.
final class CorpusItem {
  CorpusItem(this.fileName, this.expected, this.speaker);

  final String fileName;
  final String expected;

  /// Derived from the file name (`01-05-microsoft-david-desktop.wav` →
  /// `microsoft david desktop`); used only to break the summary down per voice.
  final String speaker;
}

/// Measurement for one corpus file.
final class ItemResult {
  ItemResult({
    required this.fileName,
    required this.speaker,
    required this.expected,
    required this.transcript,
    required this.audio,
    required this.decodeSeconds,
    required this.expectedParses,
    required this.transcriptParses,
    required this.parserMatch,
    required this.expectedDescription,
    required this.transcriptDescription,
  });

  final String fileName;
  final String speaker;
  final String expected;
  final String transcript;
  final AudioStats audio;
  final double decodeSeconds;

  /// The expected sentence itself is a valid command (corpus sanity).
  final bool expectedParses;

  /// The raw transcript is a valid command.
  final bool transcriptParses;

  /// Both parse to the same intent *and* the same parameter summary.
  final bool parserMatch;

  final String expectedDescription;
  final String transcriptDescription;

  bool get exact => _normalize(expected) == _normalize(transcript);

  /// Exact match after mapping spelled-out numbers to digits on both sides.
  ///
  /// The corpus is written with digits ("50"), while Vosk always emits words
  /// ("fifty"). That is an output-format difference, not a recognition error,
  /// so it is scored separately from the verbatim exact match.
  bool get exactDigitNormalized =>
      _normalizeDigits(expected) == _normalizeDigits(transcript);

  double get wordErrorRate => _wordErrorRate(expected, transcript);

  double get wordErrorRateDigits => _wordErrorRateOn(
    _foldNumbers(_tokens(expected)),
    _foldNumbers(_tokens(transcript)),
  );

  Map<String, Object?> toJson() => {
    'file': fileName,
    'speaker': speaker,
    'expected': expected,
    'transcript': transcript,
    'exact': exact,
    'exactDigitNormalized': exactDigitNormalized,
    'wer': _round(wordErrorRate),
    'werDigitNormalized': _round(wordErrorRateDigits),
    'decodeSeconds': _round(decodeSeconds),
    'rtf': _round(decodeSeconds / math.max(audio.durationSeconds, 1e-9)),
    'expectedParses': expectedParses,
    'transcriptParses': transcriptParses,
    'parserMatch': parserMatch,
    'expectedInterpretation': expectedDescription,
    'transcriptInterpretation': transcriptDescription,
    'audio': audio.toJson(),
  };
}

void main(List<String> arguments) {
  final options = _Options.parse(arguments);
  if (options == null) {
    exit(64);
  }
  _run(options).then(exit);
}

Future<int> _run(_Options options) async {
  final modelDirectory = Directory(options.modelPath);
  final corpusDirectory = Directory(options.corpusPath);
  final manifest = File(p.join(corpusDirectory.path, 'expected.tsv'));
  if (!manifest.existsSync()) {
    stderr.writeln('No expected.tsv in ${corpusDirectory.path}');
    return 66;
  }
  final items = _readManifest(manifest);
  if (items.isEmpty) {
    stderr.writeln('expected.tsv has no entries.');
    return 65;
  }
  final limited = options.limit > 0 && options.limit < items.length
      ? items.sublist(0, options.limit)
      : items;

  if (options.transcriptsPath != null) {
    return _runTranscripts(options, manifest, limited);
  }

  if (!modelDirectory.existsSync()) {
    stderr.writeln('Model folder not found: ${modelDirectory.path}');
    return 66;
  }

  final parser = VoiceCommandParser();
  final modelInfo = await VoskModelInfo.inspect(modelDirectory.path);
  vv('model: ${modelInfo?.path}');

  final grammarPhrases = options.grammar
      ? _grammarPhrases(unk: options.unk)
      : const <String>[];
  if (options.grammar && !(modelInfo?.supportsGrammar ?? false)) {
    stderr.writeln(
      'Refusing --grammar: ${modelInfo?.graphDescription ?? "unknown graph"}. '
      'vosk_recognizer_new_grm aborts on a static graph.',
    );
    return 65;
  }

  final rssBefore = ProcessInfo.currentRss;
  final loadWatch = Stopwatch()..start();
  final bindings = VoskBindings.load(libraryPath: options.libraryPath);
  bindings.setLogLevel(-1);
  if (options.grammar && !bindings.supportsGrammarApi) {
    stderr.writeln(
      'Refusing --grammar: this libvosk build does not export '
      'vosk_recognizer_new_grm.',
    );
    return 65;
  }
  final model = bindings.modelNew(modelDirectory.path);
  if (model == nullptr) {
    stderr.writeln('Vosk could not load ${modelDirectory.path}');
    return 70;
  }
  loadWatch.stop();
  final rssAfterLoad = ProcessInfo.currentRss;

  stdout.writeln('=== environment ===');
  stdout.writeln('dart             ${Platform.version}');
  stdout.writeln(
    'os               ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );
  stdout.writeln('library          ${bindings.loadedLibrary}');
  stdout.writeln('model            ${modelDirectory.path}');
  stdout.writeln('model size       ${_mb(modelInfo?.sizeBytes ?? 0)}');
  stdout.writeln('model files      ${modelInfo?.fileCount ?? 0}');
  stdout.writeln(
    'model graph      ${modelInfo?.graphDescription ?? "unknown"}',
  );
  stdout.writeln(
    'model rate       ${modelInfo?.sampleRate ?? "unknown"} Hz (from conf/mfcc.conf)',
  );
  stdout.writeln(
    'grammar          ${options.grammar ? "${grammarPhrases.length} phrases" : "off (unconstrained)"}',
  );
  stdout.writeln('load time        ${loadWatch.elapsedMilliseconds} ms');
  stdout.writeln(
    'rss              ${_mb(rssBefore)} before, ${_mb(rssAfterLoad)} after model load',
  );
  stdout.writeln('');

  final results = <ItemResult>[];
  for (final item in limited) {
    final file = File(p.join(corpusDirectory.path, item.fileName));
    if (!file.existsSync()) {
      stderr.writeln('missing file: ${file.path}');
      continue;
    }
    final WavData wav;
    try {
      wav = decodePcm16Wav(file.readAsBytesSync());
    } on FormatException catch (error) {
      stderr.writeln('${item.fileName}: ${error.message}');
      continue;
    }
    if (!wav.isRecognizerFormat) {
      stderr.writeln(
        '${item.fileName}: ${wav.description} is not the 16000 Hz mono '
        '16-bit PCM the recognizer expects — not resampling it.',
      );
      continue;
    }

    final stats = AudioStats(declaredSampleRate: wav.sampleRate)
      ..addChunk(wav.pcm);
    final transcript = _recognize(
      bindings: bindings,
      model: model,
      wav: wav,
      sampleRate: wav.sampleRate,
      grammar: grammarPhrases,
    );
    if (transcript == null) {
      stderr.writeln('${item.fileName}: Vosk failed on this file');
      continue;
    }

    results.add(
      _buildResult(
        item: item,
        transcript: transcript.text,
        stats: stats,
        seconds: transcript.seconds,
        parser: parser,
      ),
    );
  }

  bindings.modelFree(model);
  final rssEnd = ProcessInfo.currentRss;

  if (results.isEmpty) {
    stderr.writeln('No file could be measured.');
    return 70;
  }

  if (options.verbose) {
    stdout.writeln('=== per file ===');
    for (final result in results) {
      stdout.writeln(
        '${result.exact ? "EXACT" : "-----"}  '
        '${result.fileName}  '
        'wer=${result.wordErrorRate.toStringAsFixed(3)}  '
        'rtf=${(result.decodeSeconds / math.max(result.audio.durationSeconds, 1e-9)).toStringAsFixed(3)}',
      );
      if (!result.exact) {
        stdout.writeln('   expected: ${result.expected}');
        stdout.writeln('   heard:    ${result.transcript}');
      }
      stdout.writeln(
        '   parser:    expected ${result.expectedParses ? result.expectedDescription : "REJECTED"}'
        ' / heard ${result.transcriptParses ? result.transcriptDescription : "REJECTED"}'
        '${result.parserMatch ? "  (same command)" : ""}',
      );
    }
    stdout.writeln('');
  }

  final n = results.length;
  final exact = results.where((r) => r.exact).length;
  final exactDigits = results.where((r) => r.exactDigitNormalized).length;
  final werTotal = results.fold<double>(0, (sum, r) => sum + r.wordErrorRate);
  final werDigitsTotal = results.fold<double>(
    0,
    (sum, r) => sum + r.wordErrorRateDigits,
  );
  final parseableExpected = results.where((r) => r.expectedParses).length;
  final parsedTranscript = results.where((r) => r.transcriptParses).length;
  final parserMatches = results.where((r) => r.parserMatch).length;
  final audioSeconds = results.fold<double>(
    0,
    (s, r) => s + r.audio.durationSeconds,
  );
  final decodeSeconds = results.fold<double>(0, (s, r) => s + r.decodeSeconds);
  final clipped = results.fold<int>(0, (s, r) => s + r.audio.clippedSamples);
  final samples = results.fold<int>(0, (s, r) => s + r.audio.sampleCount);

  stdout.writeln('=== results ===');
  stdout.writeln('files                 $n');
  stdout.writeln(
    'exact sentence        $exact/$n (${_percent(exact, n)}) verbatim',
  );
  stdout.writeln(
    '                      $exactDigits/$n (${_percent(exactDigits, n)}) '
    'numbers folded to digits',
  );
  stdout.writeln(
    'word error rate       ${(werTotal / n).toStringAsFixed(4)} verbatim, '
    '${(werDigitsTotal / n).toStringAsFixed(4)} digits folded',
  );
  stdout.writeln('expected parses       $parseableExpected/$n (corpus sanity)');
  stdout.writeln('transcript parses     $parsedTranscript/$n');
  stdout.writeln('same command          $parserMatches/$n');
  stdout.writeln(
    'audio                 ${audioSeconds.toStringAsFixed(1)} s total',
  );
  stdout.writeln(
    'decode                ${decodeSeconds.toStringAsFixed(2)} s total, '
    'mean ${(decodeSeconds / n).toStringAsFixed(3)} s/file',
  );
  stdout.writeln(
    'real time factor      ${(decodeSeconds / math.max(audioSeconds, 1e-9)).toStringAsFixed(3)}',
  );
  stdout.writeln('clipping              $clipped/$samples samples');
  stdout.writeln('rss                   ${_mb(rssEnd)} after run');

  final speakers = <String, List<ItemResult>>{};
  for (final result in results) {
    speakers.putIfAbsent(result.speaker, () => []).add(result);
  }
  if (speakers.length > 1) {
    stdout.writeln('');
    stdout.writeln('=== by voice ===');
    for (final entry in speakers.entries) {
      final group = entry.value;
      final groupExact = group.where((r) => r.exact).length;
      final groupMatches = group.where((r) => r.parserMatch).length;
      stdout.writeln(
        '${entry.key.padRight(30)} '
        'exact $groupExact/${group.length}, '
        'same command $groupMatches/${group.length}',
      );
    }
  }
  final rejected = results.where((r) => !r.expectedParses).toList();
  if (rejected.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln(
      '!!! these expected sentences do not parse — the corpus is wrong:',
    );
    for (final result in rejected) {
      stdout.writeln(
        '    ${result.expected}  ->  ${result.expectedDescription}',
      );
    }
  }

  final report = <String, Object?>{
    'kind': 'walsey-voice-accuracy',
    'generatedAt': DateTime.now().toIso8601String(),
    'environment': {
      'dart': Platform.version,
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'library': bindings.loadedLibrary,
      'modelPath': modelDirectory.path,
      'modelSizeBytes': modelInfo?.sizeBytes,
      'modelFileCount': modelInfo?.fileCount,
      'modelGraph': modelInfo?.graphDescription,
      'modelDeclaredSampleRate': modelInfo?.sampleRate,
      'grammar': options.grammar,
      'grammarUnk': options.unk,
      'grammarPhraseCount': grammarPhrases.length,
      'modelLoadMs': loadWatch.elapsedMilliseconds,
      'rssBeforeBytes': rssBefore,
      'rssAfterModelBytes': rssAfterLoad,
      'rssAfterRunBytes': rssEnd,
    },
    'summary': {
      'files': n,
      'exactSentences': exact,
      'exactSentenceRate': _round(exact / n),
      'exactSentencesDigitNormalized': exactDigits,
      'exactSentenceRateDigitNormalized': _round(exactDigits / n),
      'meanWordErrorRate': _round(werTotal / n),
      'meanWordErrorRateDigitNormalized': _round(werDigitsTotal / n),
      'expectedParses': parseableExpected,
      'transcriptParses': parsedTranscript,
      'sameCommand': parserMatches,
      'audioSeconds': _round(audioSeconds),
      'decodeSeconds': _round(decodeSeconds),
      'realTimeFactor': _round(decodeSeconds / math.max(audioSeconds, 1e-9)),
      'clippedSamples': clipped,
      'totalSamples': samples,
    },
    'bySpeaker': {
      for (final entry in speakers.entries)
        entry.key: {
          'files': entry.value.length,
          'exact': entry.value.where((r) => r.exact).length,
          'sameCommand': entry.value.where((r) => r.parserMatch).length,
        },
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

bool _sameCommand(VoiceCommand? expected, VoiceCommand? heard) =>
    expected != null &&
    heard != null &&
    expected.actionId == heard.actionId &&
    expected.parameters.summary.join('|') == heard.parameters.summary.join('|');

/// Scores a transcript file produced by another engine on the same corpus.
///
/// The engine is not run here; every metric (exact match, WER, parser match,
/// parameters) is computed by the same code as the Vosk path, so a comparison
/// cannot drift into two different definitions of "correct".
Future<int> _runTranscripts(
  _Options options,
  File manifest,
  List<CorpusItem> items,
) async {
  final source = File(options.transcriptsPath!);
  if (!source.existsSync()) {
    stderr.writeln('Transcript file not found: ${source.path}');
    return 66;
  }
  final transcripts = <String, _TranscriptLine>{};
  for (final raw in source.readAsLinesSync()) {
    final line = raw.replaceFirst('\uFEFF', '');
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) {
      continue;
    }
    final parts = line.split('\t');
    if (parts.length < 2) {
      continue;
    }
    final milliseconds = parts.length > 2
        ? double.tryParse(parts[2].trim()) ?? 0
        : 0;
    transcripts[parts[0].trim()] = _TranscriptLine(
      parts[1].trim(),
      milliseconds / 1000,
    );
  }
  if (transcripts.isEmpty) {
    stderr.writeln('No transcripts in ${source.path}');
    return 65;
  }

  final parser = VoiceCommandParser();
  final results = <ItemResult>[];
  for (final item in items) {
    final line = transcripts[item.fileName];
    if (line == null) {
      stderr.writeln('missing transcript: ${item.fileName}');
      continue;
    }
    final file = File(p.join(options.corpusPath, item.fileName));
    final stats = AudioStats(declaredSampleRate: 16000);
    if (file.existsSync()) {
      try {
        final wav = decodePcm16Wav(file.readAsBytesSync());
        stats.addChunk(wav.pcm);
      } on FormatException catch (error) {
        stderr.writeln('${item.fileName}: ${error.message}');
      }
    }
    results.add(
      _buildResult(
        item: item,
        transcript: line.text,
        stats: stats,
        seconds: line.seconds,
        parser: parser,
      ),
    );
  }
  if (results.isEmpty) {
    stderr.writeln('No transcript could be scored.');
    return 70;
  }

  final n = results.length;
  final exact = results.where((r) => r.exact).length;
  final exactDigits = results.where((r) => r.exactDigitNormalized).length;
  final wer = results.fold<double>(0, (s, r) => s + r.wordErrorRate) / n;
  final werDigits =
      results.fold<double>(0, (s, r) => s + r.wordErrorRateDigits) / n;
  final matches = results.where((r) => r.parserMatch).length;
  final audioSeconds = results.fold<double>(
    0,
    (s, r) => s + r.audio.durationSeconds,
  );
  final decodeSeconds = results.fold<double>(0, (s, r) => s + r.decodeSeconds);

  stdout.writeln('=== transcripts: ${source.path} ===');
  for (final result in results.where((r) => !r.exact)) {
    stdout.writeln(result.fileName);
    stdout.writeln('   expected: ${result.expected}');
    stdout.writeln('   heard:    ${result.transcript}');
  }
  stdout.writeln('');
  stdout.writeln('files                 $n');
  stdout.writeln(
    'exact sentence        $exact/$n (${_percent(exact, n)}) verbatim',
  );
  stdout.writeln(
    '                      $exactDigits/$n (${_percent(exactDigits, n)}) '
    'numbers folded to digits',
  );
  stdout.writeln(
    'word error rate       ${wer.toStringAsFixed(4)} verbatim, '
    '${werDigits.toStringAsFixed(4)} digits folded',
  );
  stdout.writeln('same command          $matches/$n');
  stdout.writeln(
    'decode                ${decodeSeconds.toStringAsFixed(2)} s total',
  );
  if (audioSeconds > 0) {
    stdout.writeln(
      'real time factor      '
      '${(decodeSeconds / audioSeconds).toStringAsFixed(3)}',
    );
  }

  final report = <String, Object?>{
    'kind': 'walsey-voice-accuracy',
    'generatedAt': DateTime.now().toIso8601String(),
    'environment': {
      'engine': 'external-transcripts',
      'transcripts': source.path,
      'dart': Platform.version,
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    },
    'summary': {
      'files': n,
      'exactSentences': exact,
      'exactSentenceRate': _round(exact / n),
      'exactSentencesDigitNormalized': exactDigits,
      'exactSentenceRateDigitNormalized': _round(exactDigits / n),
      'meanWordErrorRate': _round(wer),
      'meanWordErrorRateDigitNormalized': _round(werDigits),
      'sameCommand': matches,
      'audioSeconds': _round(audioSeconds),
      'decodeSeconds': _round(decodeSeconds),
      'realTimeFactor': audioSeconds > 0
          ? _round(decodeSeconds / audioSeconds)
          : null,
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

ItemResult _buildResult({
  required CorpusItem item,
  required String transcript,
  required AudioStats stats,
  required double seconds,
  required VoiceCommandParser parser,
}) {
  final expectedResult = parser.parse(item.expected);
  final transcriptResult = parser.parse(transcript);
  final expectedCommand = expectedResult is VoiceCommandResult
      ? expectedResult.command
      : null;
  final transcriptCommand = transcriptResult is VoiceCommandResult
      ? transcriptResult.command
      : null;
  return ItemResult(
    fileName: item.fileName,
    speaker: item.speaker,
    expected: item.expected,
    transcript: transcript,
    audio: stats,
    decodeSeconds: seconds,
    expectedParses: expectedCommand != null,
    transcriptParses: transcriptCommand != null,
    parserMatch: _sameCommand(expectedCommand, transcriptCommand),
    expectedDescription: _describe(expectedResult),
    transcriptDescription: _describe(transcriptResult),
  );
}

final class _TranscriptLine {
  const _TranscriptLine(this.text, this.seconds);

  final String text;
  final double seconds;
}

/// Recognizes one WAV and returns its text plus the decode wall-clock time.
_Transcript? _recognize({
  required VoskBindings bindings,
  required Pointer<Void> model,
  required WavData wav,
  required int sampleRate,
  required List<String> grammar,
}) {
  final recognizer = grammar.isEmpty
      ? bindings.recognizerNew(model, sampleRate.toDouble())
      : bindings.recognizerNewWithGrammar(
          model,
          sampleRate.toDouble(),
          grammar,
        );
  if (recognizer == nullptr) {
    return null;
  }
  try {
    // 3200 bytes = 100 ms at 16 kHz, close to a live capture chunk.
    const chunkBytes = 3200;
    final clock = Stopwatch()..start();
    for (var offset = 0; offset < wav.pcm.length; offset += chunkBytes) {
      final end = math.min(offset + chunkBytes, wav.pcm.length);
      final chunk = Uint8List.sublistView(wav.pcm, offset, end);
      final status = bindings.acceptWaveform(recognizer, chunk);
      if (status < 0) {
        return null;
      }
    }
    final finalJson = bindings.finalResult(recognizer);
    clock.stop();
    return _Transcript(
      voskTranscriptText(finalJson ?? '') ?? '',
      clock.elapsedMicroseconds / 1e6,
    );
  } finally {
    bindings.recognizerFree(recognizer);
  }
}

final class _Transcript {
  const _Transcript(this.text, this.seconds);

  final String text;
  final double seconds;
}

String _describe(VoiceResult result) => switch (result) {
  VoiceCommandResult(:final command) =>
    '${command.actionId} ${command.parameters.summary.join(", ")}'.trim(),
  VoiceFailure(:final kind, :final explanation) => '${kind.name}: $explanation',
};

List<CorpusItem> _readManifest(File manifest) {
  final items = <CorpusItem>[];
  for (final raw in manifest.readAsLinesSync()) {
    final line = raw.replaceFirst('\uFEFF', '');
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) {
      continue;
    }
    final tab = line.indexOf('\t');
    if (tab <= 0) {
      continue;
    }
    final name = line.substring(0, tab).trim();
    final expected = line.substring(tab + 1).trim();
    if (name.isEmpty || expected.isEmpty) {
      continue;
    }
    items.add(CorpusItem(name, expected, _speakerFromName(name)));
  }
  return items;
}

String _speakerFromName(String fileName) {
  final stem = fileName.endsWith('.wav')
      ? fileName.substring(0, fileName.length - 4)
      : fileName;
  final match = RegExp(r'^\d+-\d+-(.+)$').firstMatch(stem);
  return (match?.group(1) ?? 'unknown').replaceAll('-', ' ');
}

/// Normalized comparison form: case, punctuation and spacing do not count.
///
/// Apostrophes are dropped so a recognizer's "light's" compares equal to
/// "lights"; that is punctuation, not a misheard word.
String _normalize(String text) => text
    .toLowerCase()
    .replaceAll("'", '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// [_normalize] with spelled-out numbers folded to digits on both sides.
///
/// Used only for the secondary `exactDigitNormalized`/`werDigitNormalized`
/// figures: Vosk emits "fifty", the corpus is written "50".
String _normalizeDigits(String text) =>
    _foldNumbers(_normalize(text).split(' ')).join(' ');

List<String> _foldNumbers(List<String> tokens) {
  const ones = {
    'zero': 0,
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
    'eleven': 11,
    'twelve': 12,
    'thirteen': 13,
    'fourteen': 14,
    'fifteen': 15,
    'sixteen': 16,
    'seventeen': 17,
    'eighteen': 18,
    'nineteen': 19,
  };
  const tens = {
    'twenty': 20,
    'thirty': 30,
    'forty': 40,
    'fifty': 50,
    'sixty': 60,
    'seventy': 70,
    'eighty': 80,
    'ninety': 90,
  };
  final output = <String>[];
  var value = 0;
  var inNumber = false;

  void flush() {
    if (inNumber) {
      output.add('$value');
      value = 0;
      inNumber = false;
    }
  }

  for (final token in tokens) {
    if (token.isEmpty) {
      continue;
    }
    final unit = ones[token];
    if (unit != null) {
      value += unit;
      inNumber = true;
      continue;
    }
    final ten = tens[token];
    if (ten != null) {
      value += ten;
      inNumber = true;
      continue;
    }
    if (token == 'hundred') {
      value = (value == 0 ? 1 : value) * 100;
      inNumber = true;
      continue;
    }
    flush();
    output.add(token);
  }
  flush();
  return output;
}

List<String> _tokens(String text) {
  final normalized = _normalize(text);
  return normalized.isEmpty ? const [] : normalized.split(' ');
}

/// Word error rate: (substitutions + deletions + insertions) / reference words.
double _wordErrorRate(String expected, String actual) {
  return _wordErrorRateOn(_tokens(expected), _tokens(actual));
}

double _wordErrorRateOn(List<String> reference, List<String> hypothesis) {
  if (reference.isEmpty) {
    return hypothesis.isEmpty ? 0 : 1;
  }
  var previous = List<int>.generate(hypothesis.length + 1, (i) => i);
  for (var i = 1; i <= reference.length; i++) {
    final current = List<int>.filled(hypothesis.length + 1, 0);
    current[0] = i;
    for (var j = 1; j <= hypothesis.length; j++) {
      final cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1;
      current[j] = math.min(
        math.min(current[j - 1] + 1, previous[j] + 1),
        previous[j - 1] + cost,
      );
    }
    previous = current;
  }
  return previous[hypothesis.length] / reference.length;
}

/// Grammar covering the *supported LED command vocabulary*.
///
/// This is the words the assistant could accept, not the test sentences: the
/// phrases are generated from the registry's command forms, every colour name,
/// every brightness value and every documented effect id. It therefore
/// necessarily overlaps with a corpus built from the same vocabulary — the
/// grammar result measures the best case for this closed command set, and says
/// nothing about general English.
List<String> _grammarPhrases({bool unk = false}) {
  final bodies = <String>{};
  for (final on in const [
    'turn the lights on',
    'turn on the lights',
    'switch on the lights',
    'switch the lights on',
  ]) {
    bodies.add(on);
  }
  for (final off in const [
    'turn the lights off',
    'turn off the lights',
    'switch off the lights',
    'switch the lights off',
  ]) {
    bodies.add(off);
  }
  for (final color in VoiceColor.values) {
    for (final form in [
      'make the lights ${color.name}',
      'turn the lights ${color.name}',
      'set the lights to ${color.name}',
      'set color to ${color.name}',
      'change the lights to ${color.name}',
    ]) {
      bodies.add(form);
    }
  }
  for (var percent = 0; percent <= 100; percent++) {
    final words = _numberToWords(percent);
    bodies.add('set brightness to $words percent');
    bodies.add('set the brightness to $words percent');
    bodies.add('change brightness to $words percent');
  }
  for (final relative in const [
    'increase the brightness',
    'decrease the brightness',
    'make the lights brighter',
    'make the lights dimmer',
    'turn up the brightness',
    'turn down the brightness',
  ]) {
    bodies.add(relative);
  }
  for (var id = 1; id <= 210; id++) {
    final words = _numberToWords(id);
    bodies.add('activate effect $words');
    bodies.add('set effect $words');
    bodies.add('turn on effect $words');
  }

  final phrases = <String>{};
  for (final body in bodies) {
    phrases.add(body);
    phrases.add('walsey $body');
  }
  if (unk) {
    // `[unk]` lets audio that matches no phrase (for example the wake word,
    // which is not in Vosk's vocabulary) be consumed instead of being forced
    // into the nearest command word.
    phrases.add('[unk]');
  }
  final sorted = phrases.toList()..sort();
  return sorted;
}

String _numberToWords(int value) {
  const ones = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
  ];
  const tens = [
    '',
    '',
    'twenty',
    'thirty',
    'forty',
    'fifty',
    'sixty',
    'seventy',
    'eighty',
    'ninety',
  ];
  if (value < 20) {
    return ones[value];
  }
  if (value < 100) {
    final remainder = value % 10;
    return remainder == 0
        ? tens[value ~/ 10]
        : '${tens[value ~/ 10]} ${ones[remainder]}';
  }
  final remainder = value % 100;
  final hundreds = '${ones[value ~/ 100]} hundred';
  return remainder == 0 ? hundreds : '$hundreds ${_numberToWords(remainder)}';
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _percent(int part, int total) =>
    total == 0 ? '0%' : '${(100 * part / total).toStringAsFixed(1)}%';

double _round(double value) =>
    value.isFinite ? double.parse(value.toStringAsFixed(4)) : -1;

final class _Options {
  const _Options({
    required this.modelPath,
    required this.corpusPath,
    required this.libraryPath,
    required this.grammar,
    required this.unk,
    required this.transcriptsPath,
    required this.outPath,
    required this.limit,
    required this.verbose,
  });

  final String modelPath;
  final String corpusPath;
  final String? libraryPath;
  final bool grammar;
  final bool unk;

  /// Score pre-computed transcripts instead of running Vosk.
  ///
  /// Format: `file name<TAB>raw transcript[<TAB>decode milliseconds]`. Used to
  /// compare another engine (whisper.cpp) on the exact same recordings without
  /// re-implementing the metrics.
  final String? transcriptsPath;
  final String? outPath;
  final int limit;
  final bool verbose;

  static _Options? parse(List<String> arguments) {
    String? model;
    String? corpus;
    String? library;
    String? out;
    String? transcripts;
    var grammar = false;
    var unk = false;
    var verbose = false;
    var limit = 0;
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      switch (argument) {
        case '--model':
          model = _value(arguments, ++i, argument);
        case '--corpus':
          corpus = _value(arguments, ++i, argument);
        case '--library':
          library = _value(arguments, ++i, argument);
        case '--out':
          out = _value(arguments, ++i, argument);
        case '--transcripts':
          transcripts = _value(arguments, ++i, argument);
        case '--limit':
          limit = int.tryParse(_value(arguments, ++i, argument) ?? '') ?? 0;
        case '--grammar':
          grammar = true;
        case '--unk':
          unk = true;
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
      libraryPath: library,
      grammar: grammar,
      unk: unk,
      transcriptsPath: transcripts,
      outPath: out,
      limit: limit,
      verbose: verbose,
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
      'usage: dart run bin/voice_accuracy.dart --model <dir> --corpus <dir> '
      '[--library <dll>] [--grammar [--unk]] [--transcripts <tsv>] '
      '[--out <json>] [--limit <n>] [-v]',
    );
  }
}

void vv(String message) {
  // Reserved for future debug output; kept silent so summaries stay readable.
  if (Platform.environment['WALSEY_ACCURACY_DEBUG'] == '1') {
    stdout.writeln(message);
  }
}
