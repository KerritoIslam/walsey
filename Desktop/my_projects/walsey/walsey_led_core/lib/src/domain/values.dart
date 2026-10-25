import 'errors.dart';

/// An RGB color, each channel 0..255.
final class RgbColor {
  factory RgbColor(int r, int g, int b) {
    _check('red', r, 0, 255);
    _check('green', g, 0, 255);
    _check('blue', b, 0, 255);
    return RgbColor._(r, g, b);
  }

  const RgbColor._(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  @override
  bool operator ==(Object other) =>
      other is RgbColor && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'RgbColor($r, $g, $b)';
}

/// BrightnessLevel as an integer percentage, 0..100.
final class BrightnessLevel {
  factory BrightnessLevel(int percent) {
    _check('brightness percent', percent, 0, 100);
    return BrightnessLevel._(percent);
  }

  const BrightnessLevel._(this.percent);

  final int percent;

  @override
  bool operator ==(Object other) =>
      other is BrightnessLevel && other.percent == percent;

  @override
  int get hashCode => percent.hashCode;

  @override
  String toString() => 'BrightnessLevel($percent%)';
}

/// A built-in controller effect id.
///
/// Valid ids come from LED_UNION's `dmx_model.tsv`: 1..210 plus 255 (AUTO).
/// The two LEDDMX effect tables disagree from id 73 upward, so what an id
/// *looks like* is variant-dependent and unverified. Ids 1..72 are identical
/// in both tables.
final class LedEffect {
  factory LedEffect(int id) {
    final valid = (id >= 1 && id <= 210) || id == autoId;
    if (!valid) {
      throw InvalidCommandException(
          'effect id $id is not in the documented set (1..210 or 255)');
    }
    return LedEffect._(id);
  }

  const LedEffect._(this.id);

  static const int autoId = 255;

  final int id;

  @override
  bool operator ==(Object other) => other is LedEffect && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'LedEffect($id)';
}

void _check(String what, int v, int min, int max) {
  if (v < min || v > max) {
    throw InvalidCommandException('$what must be $min..$max, got $v');
  }
}
