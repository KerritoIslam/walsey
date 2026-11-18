import 'package:walsey_led_core/walsey_led_core.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import '../control/led_control_service.dart';

final class VoiceCommandExecution {
  const VoiceCommandExecution({required this.message, required this.success});

  final String message;
  final bool success;
}

/// The only bridge from the voice parser to the existing LED command facade.
/// It deliberately does not execute relative commands because the protocol
/// has no state read-back.
final class VoiceCommandExecutor {
  const VoiceCommandExecutor(this._controls);

  final LedControlService? _controls;

  Future<VoiceCommandExecution> execute(VoiceCommand command) async {
    final controls = _controls;
    if (controls == null) {
      return const VoiceCommandExecution(
        message: 'Connect to a supported LEDDMX controller first.',
        success: false,
      );
    }

    final CommandResult result;
    switch (command.intent) {
      case VoiceIntent.powerOn:
        result = await controls.setPower(on: true);
      case VoiceIntent.powerOff:
        result = await controls.setPower(on: false);
      case VoiceIntent.setColor:
        final parameters = command.parameters;
        if (parameters is! ColorParameters) {
          return const VoiceCommandExecution(
            message: 'The color parameter was not available.',
            success: false,
          );
        }
        result = await controls.setColor(
          RgbColor(parameters.color.r, parameters.color.g, parameters.color.b),
        );
      case VoiceIntent.setBrightness:
        final parameters = command.parameters;
        if (parameters is! BrightnessParameters) {
          return const VoiceCommandExecution(
            message: 'The brightness parameter was not available.',
            success: false,
          );
        }
        result = await controls.setBrightness(
          BrightnessLevel(parameters.brightness.percent),
        );
      case VoiceIntent.applyEffect:
        final parameters = command.parameters;
        if (parameters is! EffectParameters) {
          return const VoiceCommandExecution(
            message: 'The effect parameter was not available.',
            success: false,
          );
        }
        result = await controls.applyEffect(LedEffect(parameters.effect.id));
      case VoiceIntent.increaseBrightness || VoiceIntent.decreaseBrightness:
        return const VoiceCommandExecution(
          message:
              'Relative brightness needs device state, which this protocol '
              'cannot read.',
          success: false,
        );
      case VoiceIntent.queryStatus:
        // The legacy single-command path must stay honest too: there is no
        // state read-back, so nothing is sent and nothing is claimed.
        return const VoiceCommandExecution(
          message: 'The controller protocol has no state read-back, so the '
              'current LED state is unknown. Nothing was sent.',
          success: false,
        );
    }

    return switch (result) {
      CommandSent() => const VoiceCommandExecution(
        message: 'BLE write completed; LED response is not confirmed.',
        success: true,
      ),
      CommandUnsupported(:final reason) => VoiceCommandExecution(
        message: 'Command unsupported: $reason',
        success: false,
      ),
      CommandFailed(:final message) => VoiceCommandExecution(
        message: 'Command failed: $message',
        success: false,
      ),
    };
  }
}
