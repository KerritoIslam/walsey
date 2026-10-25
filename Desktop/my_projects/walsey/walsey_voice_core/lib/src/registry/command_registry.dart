import '../domain/voice_intent.dart';

/// Domains the assistant can eventually route commands to.
///
/// Stage 1 registers LED actions only. System/application/audio domains are
/// named here as the extension point but have no actions, so the parser can
/// never emit them yet.
enum VoiceDomain {
  led,
  system,
  applications,
  audio,
}

/// One allowed action: the allowlist entry between parsing and execution.
///
/// A parsed intent is only turned into a valid command when its spec is
/// registered. Nothing in the voice core can execute a spec; Stage 3 will map
/// registered actions to explicit handlers.
final class VoiceActionSpec {
  const VoiceActionSpec({
    required this.intent,
    required this.domain,
    required this.description,
    required this.example,
  });

  final VoiceIntent intent;
  final VoiceDomain domain;
  final String description;

  /// A canonical sentence used by the testing UI's example section.
  final String example;

  /// Stable identifier; the enum name is the contract.
  String get id => intent.name;
}

/// Immutable set of allowed actions.
///
/// Deliberately small: it stores descriptors and answers "is this action
/// registered?". Adding a domain later means constructing another registry,
/// not changing the parser's execution path.
final class CommandRegistry {
  CommandRegistry(Iterable<VoiceActionSpec> actions)
      : _actions = {
          for (final action in actions) action.intent: action,
        } {
    if (_actions.length != actions.length) {
      throw ArgumentError('duplicate intent in command registry');
    }
    for (final action in _actions.values) {
      if (action.description.trim().isEmpty) {
        throw ArgumentError('action ${action.id} needs a description');
      }
    }
  }

  /// The Stage 1 allowlist: only actions backed by the existing LED API.
  ///
  /// `increaseBrightness`/`decreaseBrightness` are recognized but cannot be
  /// executed until the controller can report its current brightness; the
  /// protocol has no state read-back. `applyEffect` takes a documented effect
  /// id because the existing app exposes no effect names.
  factory CommandRegistry.ledDefaults() => CommandRegistry(const [
        VoiceActionSpec(
          intent: VoiceIntent.powerOn,
          domain: VoiceDomain.led,
          description: 'Turn the LED controller on.',
          example: 'Walsey, turn the lights on.',
        ),
        VoiceActionSpec(
          intent: VoiceIntent.powerOff,
          domain: VoiceDomain.led,
          description: 'Turn the LED controller off.',
          example: 'Walsey, turn the lights off.',
        ),
        VoiceActionSpec(
          intent: VoiceIntent.setColor,
          domain: VoiceDomain.led,
          description: 'Set a named colour from the controlled list.',
          example: 'Walsey, make the lights blue.',
        ),
        VoiceActionSpec(
          intent: VoiceIntent.setBrightness,
          domain: VoiceDomain.led,
          description: 'Set brightness to an absolute percentage 0..100.',
          example: 'Walsey, set brightness to 50 percent.',
        ),
        VoiceActionSpec(
          intent: VoiceIntent.increaseBrightness,
          domain: VoiceDomain.led,
          description: 'Relative brightness increase (needs device state).',
          example: 'Walsey, increase the brightness.',
        ),
        VoiceActionSpec(
          intent: VoiceIntent.decreaseBrightness,
          domain: VoiceDomain.led,
          description: 'Relative brightness decrease (needs device state).',
          example: 'Walsey, make the lights dimmer.',
        ),
        VoiceActionSpec(
          intent: VoiceIntent.applyEffect,
          domain: VoiceDomain.led,
          description: 'Apply a documented built-in effect id.',
          example: 'Walsey, activate effect 5.',
        ),
      ]);

  final Map<VoiceIntent, VoiceActionSpec> _actions;

  /// Registered actions in stable declaration order.
  List<VoiceActionSpec> get actions => List.unmodifiable(_actions.values);

  VoiceActionSpec? lookup(VoiceIntent intent) => _actions[intent];

  bool supports(VoiceIntent intent) => _actions.containsKey(intent);
}
