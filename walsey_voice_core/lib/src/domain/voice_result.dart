import 'voice_intent.dart';
import 'voice_parameters.dart';

/// Whether a parsed command has been carried out.
///
/// Stages 1 and 2 only ever produce [notExecuted]. The enum exists so later
/// stages cannot accidentally report a parse as an execution: a valid command
/// result still says "not executed" until a real executor reports otherwise.
enum VoiceExecutionStatus {
  notExecuted,
  executed,
  failed;

  String get label => switch (this) {
        VoiceExecutionStatus.notExecuted =>
          'Not executed — Stage 2 testing mode',
        VoiceExecutionStatus.executed => 'Executed',
        VoiceExecutionStatus.failed => 'Execution failed',
      };
}

/// A validated command. Constructed only after parameter validation succeeds.
final class VoiceCommand {
  const VoiceCommand({
    required this.intent,
    required this.parameters,
    required this.sourceText,
    required this.normalizedText,
  });

  final VoiceIntent intent;
  final VoiceParameters parameters;

  /// Exactly what the user submitted, before normalization.
  final String sourceText;

  /// Normalized, wake-word-stripped text used by the parser.
  final String normalizedText;

  /// Stable action identifier (`powerOn`, `setColor`, ...).
  String get actionId => intent.name;

  @override
  String toString() => 'VoiceCommand($actionId, $parameters)';
}

/// Why a sentence did not produce an executable command.
enum VoiceFailureKind {
  emptyInput,
  unsupported,
  ambiguous,
  missingParameter,
  invalidParameter;

  String get label => switch (this) {
        VoiceFailureKind.emptyInput => 'Empty input',
        VoiceFailureKind.unsupported => 'Unsupported command',
        VoiceFailureKind.ambiguous => 'Ambiguous command',
        VoiceFailureKind.missingParameter => 'Missing parameter',
        VoiceFailureKind.invalidParameter => 'Invalid parameter',
      };
}

/// The result of analyzing one sentence.
///
/// Sealed so the UI must handle a failure explicitly instead of treating every
/// string as a command.
sealed class VoiceResult {
  const VoiceResult({
    required this.sourceText,
    this.executionStatus = VoiceExecutionStatus.notExecuted,
  });

  /// Exactly what the user submitted.
  final String sourceText;

  /// Stage 1 invariant: parsing never executes anything.
  final VoiceExecutionStatus executionStatus;
}

/// A recognized, validated command. Execution is still [notExecuted].
final class VoiceCommandResult extends VoiceResult {
  const VoiceCommandResult({
    required super.sourceText,
    required this.command,
  });

  final VoiceCommand command;
}

/// An explicit non-command result with a user-facing explanation.
final class VoiceFailure extends VoiceResult {
  const VoiceFailure({
    required super.sourceText,
    required this.kind,
    required this.explanation,
    this.intent,
  });

  final VoiceFailureKind kind;

  /// Plain-language reason shown in the testing UI.
  final String explanation;

  /// Set when an action was recognized but its parameters were missing or
  /// invalid, so the UI can still show which intent was intended.
  final VoiceIntent? intent;
}
