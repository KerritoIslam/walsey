import 'package:flutter/material.dart';

/// Walsey visual language, ported from `claude_design/tokens/design-tokens.json`.
///
/// Dark-first, deep charcoal surfaces, restrained violet accent and a small,
/// single-purpose status palette. Widgets must use these tokens instead of
/// raw colors so the appearance settings can retint the primary accent.
abstract final class WalseyColors {
  const WalseyColors._();

  static const bg = Color(0xFF0E0F14);
  static const surface = Color(0xFF171923);
  static const surfaceRaised = Color(0xFF1F2230);
  static const border = Color(0xFF262A38);
  static const track = Color(0xFF3A3F52);

  static const text = Color(0xFFE8EAF2);
  static const textSecondary = Color(0xFFB4BACB);
  static const textMuted = Color(0xFF9AA1B5);

  static const primary = Color(0xFF7B6CF6);
  static const primaryTint = Color(0xFF242246);
  static const primaryText = Color(0xFFB7AEFF);
  static const accentCyan = Color(0xFF3DD6E8);

  static const success = Color(0xFF4CC38A);
  static const successBg = Color(0xFF12362A);
  static const successText = Color(0xFF6FE0A8);

  static const warning = Color(0xFFF2B04A);
  static const warningBg = Color(0xFF3A2C10);
  static const warningText = Color(0xFFF5C26B);

  static const error = Color(0xFFE5646B);
  static const errorBg = Color(0xFF3A1A1E);
  static const errorText = Color(0xFFF59BA0);

  static const offlineBg = Color(0xFF262A38);
  static const offlineText = Color(0xFFB4BACB);
}

/// Accent tints offered in Settings. Each retints primary affordances only;
/// semantic status colors never change.
enum WalseyAccent {
  violet('Violet', WalseyColors.primary, WalseyColors.primaryTint),
  cyan('Cyan', WalseyColors.accentCyan, Color(0xFF102F34)),
  emerald('Emerald', WalseyColors.success, Color(0xFF113127)),
  amber('Amber', WalseyColors.warning, Color(0xFF33280F));

  const WalseyAccent(this.label, this.color, this.tint);

  final String label;
  final Color color;
  final Color tint;

  static WalseyAccent fromName(String? name) => values.firstWhere(
    (accent) => accent.name == name,
    orElse: () => WalseyAccent.violet,
  );
}

abstract final class WalseySpacing {
  const WalseySpacing._();

  static const double xxs = 4;
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 12;
  static const double xl = 14;
  static const double xxl = 16;
  static const double xxxl = 20;
  static const double huge = 24;
  static const double giant = 28;

  static const double screenMobile = 16;
  static const double screenDesktopX = 28;
  static const double screenDesktopY = 24;
  static const double sidebarWidth = 210;
  static const double rightPanelWidth = 270;
  static const double maxContentWidth = 1180;
}

abstract final class WalseyRadius {
  const WalseyRadius._();

  static const double badge = 6;
  static const double control = 8;
  static const double card = 10;
  static const double sheet = 16;
  static const double chip = 16;
}

/// Typography scale from the design export (Inter 400/500/600/700).
abstract final class WalseyType {
  const WalseyType._();

  static const String family = 'Inter';

  static const TextStyle pageTitle = TextStyle(
    fontFamily: family,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.25,
    color: WalseyColors.text,
  );

  static const TextStyle pageTitleMobile = TextStyle(
    fontFamily: family,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.25,
    color: WalseyColors.text,
  );

  static const TextStyle sectionTitle = TextStyle(
    fontFamily: family,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: WalseyColors.text,
  );

  static const TextStyle body = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.45,
    color: WalseyColors.text,
  );

  static const TextStyle rowTitle = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: WalseyColors.text,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: WalseyColors.textMuted,
  );

  static const TextStyle sectionLabel = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.72,
    color: WalseyColors.textMuted,
  );

  static const TextStyle badge = TextStyle(
    fontFamily: family,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  static const TextStyle display = TextStyle(
    fontFamily: family,
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: 3,
    color: WalseyColors.text,
  );

  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11,
    height: 1.5,
    color: WalseyColors.textSecondary,
  );
}
