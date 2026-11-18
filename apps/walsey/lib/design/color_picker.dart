import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Maps a pointer position inside the circular picker to a color.
///
/// This is the design prototype's model: angle selects hue, distance from the
/// centre selects lightness (centre = white, rim = full hue at 50 % lightness).
/// Exposed as a pure function so it can be unit tested without a widget.
Color colorFromWheel(Offset local, Size size) {
  final radius = size.width / 2;
  if (radius <= 0) return Colors.white;
  final dx = local.dx - radius;
  final dy = local.dy - radius;
  final distance = (math.sqrt(dx * dx + dy * dy) / radius).clamp(0.0, 1.0);
  final hue = (math.atan2(dy, dx) * 180 / math.pi + 450) % 360;
  final lightness = 1 - 0.5 * distance;
  final a = math.min(lightness, 1 - lightness);

  int channel(double n) {
    final k = (n + hue / 30) % 12;
    final value =
        lightness - a * math.max(-1.0, math.min(math.min(k - 3, 9 - k), 1.0));
    return (255 * value).round().clamp(0, 255);
  }

  return Color.fromARGB(255, channel(0), channel(8), channel(4));
}

/// Position of [color] on the wheel, matching [colorFromWheel].
Offset wheelPositionFor(Color color, Size size) {
  final hsl = HSLColor.fromColor(color);
  final radius = size.width / 2;
  final distance = ((1 - hsl.lightness) / 0.5).clamp(0.0, 1.0);
  final angle = (hsl.hue - 450) * math.pi / 180;
  return Offset(
    radius + radius * distance * math.cos(angle),
    radius + radius * distance * math.sin(angle),
  );
}

Color colorFromRgb(int r, int g, int b) => Color.fromARGB(255, r, g, b);

String colorToHex(Color color) {
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  return '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

/// Parses `#RRGGBB` or `RRGGBB`. Returns null for anything else.
Color? colorFromHex(String text) {
  final value = text.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)) return null;
  return Color.fromARGB(255, int.parse(value.substring(0, 2), radix: 16),
      int.parse(value.substring(2, 4), radix: 16),
      int.parse(value.substring(4, 6), radix: 16));
}

/// Parses `r, g, b` with each channel in 0..255.
Color? colorFromRgbText(String text) {
  final parts = text.split(',').map((part) => part.trim()).toList();
  if (parts.length != 3) return null;
  final values = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    values.add(value);
  }
  return colorFromRgb(values[0], values[1], values[2]);
}

String colorToRgbText(Color color) =>
    '${(color.r * 255).round()}, ${(color.g * 255).round()}, '
    '${(color.b * 255).round()}';

/// Filled circular color picker (design component "filled color picker").
///
/// The disc is solid: hue runs around the rim while lightness rises to white
/// in the centre — never a hollow hue ring.
class WFilledColorPicker extends StatelessWidget {
  const WFilledColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
    this.size = 250,
    this.onChangeEnd,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final VoidCallback? onChangeEnd;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Color picker',
      hint: 'Drag to choose hue and lightness',
      child: SizedBox(
        width: size,
        height: size,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (details) =>
              onChanged(colorFromWheel(details.localPosition, Size.square(size))),
          onPanUpdate: (details) =>
              onChanged(colorFromWheel(details.localPosition, Size.square(size))),
          onPanEnd: (_) => onChangeEnd?.call(),
          onTapDown: (details) =>
              onChanged(colorFromWheel(details.localPosition, Size.square(size))),
          onTapUp: (_) => onChangeEnd?.call(),
          child: CustomPaint(painter: _WheelPainter(color)),
        ),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  const _WheelPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = size.width / 2;
    final center = Offset(radius, radius);
    final circle = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius - 1));

    canvas.save();
    canvas.clipPath(circle);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: math.pi * 3 / 2,
          colors: [
            Color(0xFFFF0000),
            Color(0xFFFFFF00),
            Color(0xFF00FF00),
            Color(0xFF00FFFF),
            Color(0xFF0000FF),
            Color(0xFFFF00FF),
            Color(0xFFFF0000),
          ],
        ).createShader(rect),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          colors: [Colors.white, Color(0x00FFFFFF)],
          stops: [0, 0.74],
        ).createShader(rect),
    );
    canvas.restore();

    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = WalseyColors.track,
    );

    final marker = wheelPositionFor(color, size);
    canvas.drawCircle(
      marker,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    canvas.drawCircle(
      marker,
      13,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.black.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_WheelPainter oldDelegate) => oldDelegate.color != color;
}
