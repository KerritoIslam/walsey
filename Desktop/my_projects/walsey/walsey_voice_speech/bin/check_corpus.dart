// Corpus sanity check: every positive must parse, every negative (`!`) must be
// rejected. Run this before recording a corpus — an unparseable "expected"
// sentence would otherwise be reported as a recognition failure forever.
//
// One exception is deliberate: a negative may parse as a status inquiry
// (`queryStatus` / a plan of only `QueryStatusStep`), because that intent sends
// nothing and reports that the protocol has no state read-back. It is printed
// as NON-WRITING and does not fail the check. Any other parsed negative does.
//
// Usage (inside walsey_voice_speech):
//   dart run bin/check_corpus.dart ../tools/voice_accuracy/commands.txt
//   dart run bin/check_corpus.dart ../tools/voice_accuracy/commands_plan.txt --plan
//
// It never executes anything and never touches audio or BLE.

import 'dart:io';

import 'package:walsey_voice_core/walsey_voice_core.dart';

void main(List<String> arguments) {
  final paths = arguments.where((a) => !a.startsWith('--')).toList();
  final planMode = arguments.contains('--plan');
  if (paths.isEmpty) {
    stderr.writeln(
      'usage: dart run bin/check_corpus.dart <commands.txt> [--plan]',
    );
    exit(64);
  }
  final parser = VoicePlanParser();
  var failures = 0;
  var positives = 0;
  var negatives = 0;

  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('not found: $path');
      exit(66);
    }
    stdout.writeln('=== $path${planMode ? " (plan mode)" : ""} ===');
    for (final raw in file.readAsLinesSync()) {
      final line = raw.replaceFirst('\uFEFF', '').trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final expectsCommand = !line.startsWith('!');
      final sentence = expectsCommand ? line : line.substring(1).trim();
      final result = planMode
          ? parser.parse(sentence)
          : VoiceCommandParser().parse(sentence);
      final parses = planMode
          ? result is VoicePlanReady
          : result is VoiceCommandResult;
      if (expectsCommand) {
        positives++;
        if (!parses) {
          failures++;
          stdout.writeln('BAD POSITIVE: "$sentence" -> ${_describe(result)}');
        }
      } else {
        negatives++;
        if (parses) {
          if (_onlyNonWriting(result)) {
            stdout.writeln('NON-WRITING: "$sentence" -> ${_describe(result)} '
                '(status inquiry; nothing is sent)');
          } else {
            failures++;
            stdout.writeln('BAD NEGATIVE: "$sentence" still parses -> '
                '${_describe(result)}');
          }
        }
      }
    }
  }

  stdout.writeln('');
  stdout.writeln('positives $positives, negatives $negatives, problems $failures');
  exit(failures == 0 ? 0 : 1);
}

String _describe(Object? result) => switch (result) {
  VoiceCommandResult(:final command) =>
    '${command.actionId} ${command.parameters.summary.join(", ")}',
  VoiceFailure(:final kind, :final explanation) => '${kind.name}: $explanation',
  VoicePlanReady(:final plan) => plan.summary.join(' | '),
  VoicePlanFailure(:final kind, :final explanation) =>
    '${kind.name}: $explanation',
  _ => '$result',
};

/// Whether a parsed result can only read nothing and send nothing.
///
/// The only such intent is [VoiceIntent.queryStatus]; every other intent maps
/// to a BLE write. A plan qualifies only when every step is a status query.
bool _onlyNonWriting(Object result) => switch (result) {
  VoiceCommandResult(:final command) =>
    command.intent == VoiceIntent.queryStatus,
  VoicePlanReady(:final plan) => plan.steps.every((s) => s is QueryStatusStep),
  _ => false,
};
