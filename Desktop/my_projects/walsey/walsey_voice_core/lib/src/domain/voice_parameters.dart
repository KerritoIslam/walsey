import 'errors.dart';

/// A colour name from the controlled list the voice layer understands.
///
/// The RGB values are fixed so a later stage can map the name to the LED
/// controller's `RgbColor` without inventing colours at execution time.
enum VoiceColor {
  red(255, 0, 0),
  green(0, 255, 0),
  blue(0, 0, 255),
  white(255, 255, 255),
  yellow(255, 255, 0),
  orange(255, 165, 0),
  purple(128, 0, 128),
  pink(255, 105, 180),
  cyan(0, 255, 255),
  magenta(255, 0, 255);

  const VoiceColor(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  /// The colour name as it appears in the interpretation panel.
  String get label => name;

  /// Recognizes a single token, including a small set of unambiguous aliases.
  ///
  /// Anything else is not a colour: callers must not pass arbitrary words on
  /// to the LED layer.
  static VoiceColor? fromWord(String word) {
    final canonical = _aliases[word] ?? word;
    for (final color in values) {
      if (color.name == canonical) return color;
    }
    return null;
  }

  static const Map<String, String> _aliases = {
    'violet': 'purple',
    'turquoise': 'cyan',
  };
}

/// Brightness as an integer percentage, validated in the constructor.
///
/// The LED core uses percentages 0..100 (`BrightnessLevel`), so the voice layer
/// validates the same range and never clamps.
final class VoiceBrightness {
  factory VoiceBrightness(int percent) {
    if (percent < 0 || percent > 100) {
      throw VoiceParameterException(
        'brightness percent must be 0..100, got $percent',
      );
    }
    return VoiceBrightness._(percent);
  }

  const VoiceBrightness._(this.percent);

  final int percent;

  @override
  bool operator ==(Object other) =>
      other is VoiceBrightness && other.percent == percent;

  @override
  int get hashCode => percent.hashCode;

  @override
  String toString() => '$percent%';
}

/// A built-in controller effect id.
///
/// Mirrors `LedEffect` in `walsey_led_core`: ids 1..210 plus 255 (AUTO) are the
/// documented set. The voice layer deliberately does not invent effect names;
/// the existing app exposes numbers only. Ids 73..210 are variant-dependent in
/// the protocol research, which is why the UI example recommends 1..72.
final class VoiceEffect {
  factory VoiceEffect(int id) {
    final valid = (id >= 1 && id <= 210) || id == autoId;
    if (!valid) {
      throw VoiceParameterException(
        'effect id $id is not in the documented set (1..210 or 255)',
      );
    }
    return VoiceEffect._(id);
  }

  const VoiceEffect._(this.id);

  static const int autoId = 255;

  final int id;

  @override
  bool operator ==(Object other) => other is VoiceEffect && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'effect $id';
}

/// Parameters attached to a parsed intent.
///
/// Sealed so a new parameter shape cannot be added without updating every
/// consumer that switches on it.
sealed class VoiceParameters {
  const VoiceParameters();

  /// Rows for the interpretation panel; empty when the intent takes no value.
  List<String> get summary;
}

final class NoParameters extends VoiceParameters {
  const NoParameters();

  @override
  List<String> get summary => const [];
}

final class ColorParameters extends VoiceParameters {
  const ColorParameters(this.color);

  final VoiceColor color;

  @override
  List<String> get summary => ['Color: ${color.label}'];
}

final class BrightnessParameters extends VoiceParameters {
  const BrightnessParameters(this.brightness);

  final VoiceBrightness brightness;

  @override
  List<String> get summary => ['Brightness: ${brightness.percent}%'];
}

final class EffectParameters extends VoiceParameters {
  const EffectParameters(this.effect);

  final VoiceEffect effect;

  @override
  List<String> get summary => ['Effect id: ${effect.id}'];
}
