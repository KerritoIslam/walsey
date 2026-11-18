import 'voice_plan.dart';

/// Port between "text" and "a validated plan".
///
/// The only shipped implementation is [VoicePlanParser] (`walsey_voice_core`),
/// which delegates single commands to the Stage 1 parser and keeps the
/// registry as the authorization allowlist. An implementation must never
/// execute anything: it returns data only.
abstract interface class CommandInterpreter {
  /// Interprets one sentence without executing it.
  VoicePlanResult interpret(String input);
}
