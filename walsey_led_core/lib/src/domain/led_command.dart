import 'values.dart';

/// The closed set of commands the core can express. Voice, scenes and UI all
/// produce these; nothing else reaches the driver.
sealed class LedCommand {
  const LedCommand();
}

final class PowerCommand extends LedCommand {
  const PowerCommand({required this.on});
  final bool on;
}

final class SetColorCommand extends LedCommand {
  const SetColorCommand(this.color);
  final RgbColor color;
}

final class SetBrightnessCommand extends LedCommand {
  const SetBrightnessCommand(this.brightness);
  final BrightnessLevel brightness;
}

final class ApplyEffectCommand extends LedCommand {
  const ApplyEffectCommand(this.effect);
  final LedEffect effect;
}
