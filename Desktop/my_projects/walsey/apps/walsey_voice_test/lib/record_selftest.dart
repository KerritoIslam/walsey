import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// Diagnostic entry point that records the *real* microphone through the same
/// `record`-backed [AudioCapture] the recognizer uses.
///
/// This exists because unit tests must not touch a microphone, yet the capture
/// format (`record` can silently resample) is exactly what has to be verified.
/// It is never part of the normal app flow: it runs only when the desktop
/// executable is started with `--record-selftest`.
///
/// It writes `record_selftest.json` plus a 16 kHz mono PCM16 `record_selftest.wav`
/// into the output folder and then exits. Nothing is uploaded and no model is
/// touched.
Future<void> runRecordSelfTest(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final seconds = _intArgument(arguments, '--seconds') ?? 5;
  final outArgument = _stringArgument(arguments, '--out');
  final directory = outArgument != null
      ? Directory(outArgument)
      : Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'walsey_record_selftest',
        );
  await directory.create(recursive: true);
  final reportFile = File(
    '${directory.path}${Platform.pathSeparator}record_selftest.json',
  );
  final wavFile = File(
    '${directory.path}${Platform.pathSeparator}record_selftest.wav',
  );

  final capture = RecordAudioCapture();
  final diagnostics = SessionDiagnostics();
  final result = <String, Object?>{'requestedSeconds': seconds, 'output': directory.path};
  final log = File('${directory.path}${Platform.pathSeparator}record_selftest.log');
  void note(String step) {
    log.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $step\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  note('start');
  try {
    note('requesting permission');
    final permitted = await capture.hasPermission();
    note('permission=$permitted');
    result['permission'] = permitted;
    if (!permitted) {
      result['error'] = 'microphone permission denied';
      await _writeReport(reportFile, result);
      exit(2);
    }

    diagnostics.beginSession(sampleRate: 16000);
    note('starting stream');
    final stream = await capture.startStream(sampleRate: 16000);
    note('stream started');
    final clock = Stopwatch()..start();
    int? firstChunkMs;
    int? lastChunkMs;
    final done = Completer<void>();
    final subscription = stream.listen(
      (chunk) {
        firstChunkMs ??= clock.elapsedMilliseconds;
        lastChunkMs = clock.elapsedMilliseconds;
        diagnostics.addChunk(chunk);
      },
      onError: (Object error, StackTrace _) {
        result['streamError'] = '$error';
        if (!done.isCompleted) {
          done.complete();
        }
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete();
        }
      },
    );

    await Future<void>.delayed(Duration(seconds: seconds));
    note('recording window over');
    final stopAtMs = clock.elapsedMilliseconds;
    await capture.stop();
    note('capture stopped');
    await done.future.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
    await subscription.cancel();
    diagnostics.closeCapture();
    note('writing wav');

    final file = await diagnostics.saveWav(directory);
    note('wav written: ${file?.path}');
    final stats = diagnostics.stats;
    result['wavPath'] = file?.path;
    result['captureWallMs'] = diagnostics.captureWallTime?.inMilliseconds;
    result['rateRatio'] = diagnostics.rateRatio;
    final firstAtMs = firstChunkMs;
    final lastAtMs = lastChunkMs;
    result['firstChunkDelayMs'] = firstAtMs;
    result['lastChunkAtMs'] = lastAtMs;
    result['stopAtMs'] = stopAtMs;
    result['tailGapMs'] = lastAtMs == null ? null : stopAtMs - lastAtMs;
    result['streamSpanMs'] = firstAtMs == null || lastAtMs == null
        ? null
        : lastAtMs - firstAtMs;
    result['rateOverSpan'] =
        firstAtMs == null || lastAtMs == null || lastAtMs == firstAtMs
        ? null
        : (stats?.durationSeconds ?? 0) / ((lastAtMs - firstAtMs) / 1000);
    result['stats'] = stats?.toJson();
    result['totalFileBytes'] = file == null ? 0 : await file.length();
    if (file != null && file.path != wavFile.path) {
      // Keep the name predictable for the measurement scripts.
      await file.copy(wavFile.path);
      result['wavCopyPath'] = wavFile.path;
    }
    result['ok'] = stats != null && stats.sampleCount > 0;
  } on Object catch (error, stack) {
    note('error: $error');
    result['error'] = '$error';
    result['stack'] = '$stack';
  } finally {
    await capture.dispose();
    diagnostics.dispose();
  }

  await _writeReport(reportFile, result);
  note('report written');
  exit(result['ok'] == true ? 0 : 1);
}

Future<void> _writeReport(File file, Map<String, Object?> result) =>
    file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
      flush: true,
    );

String? _stringArgument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) {
    return null;
  }
  return arguments[index + 1];
}

int? _intArgument(List<String> arguments, String name) {
  final raw = _stringArgument(arguments, name);
  return raw == null ? null : int.tryParse(raw);
}
