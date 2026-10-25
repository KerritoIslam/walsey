import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

final parser = VoiceCommandParser();

VoiceCommand commandFor(String input) {
  final result = parser.parse(input);
  if (result is! VoiceCommandResult) {
    fail('expected a command for "$input", got $result');
  }
  return result.command;
}

VoiceFailure failureFor(String input) {
  final result = parser.parse(input);
  if (result is! VoiceFailure) {
    fail('expected a failure for "$input", got $result');
  }
  return result;
}

void expectCommand(
  String input, {
  required VoiceIntent intent,
  List<String> parameters = const [],
}) {
  final command = commandFor(input);
  expect(command.intent, intent, reason: 'input: "$input"');
  expect(command.parameters.summary, parameters, reason: 'input: "$input"');
}
