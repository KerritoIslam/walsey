import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds the single Walsey dark theme. Accent changes retint primary
/// affordances; status colors stay semantic.
///
/// Every [ColorScheme] role is set explicitly. A partially specified
/// `ColorScheme.dark()` keeps the Material baseline palette for the missing
/// roles — most visibly the baseline **tertiary** purple — and any component
/// that reads those roles then leaks a colour the design never specified. The
/// roles below are all derived from `claude_design/tokens/design-tokens.json`.
ThemeData buildWalseyTheme({WalseyAccent accent = WalseyAccent.violet}) {
  final scheme = ColorScheme.dark(
    primary: accent.color,
    onPrimary: Colors.white,
    primaryContainer: accent.tint,
    onPrimaryContainer: WalseyColors.primaryText,
    secondary: WalseyColors.accentCyan,
    onSecondary: WalseyColors.bg,
    secondaryContainer: WalseyColors.surfaceRaised,
    onSecondaryContainer: WalseyColors.text,
    // The tertiary role exists in Material 3; the design's second accent is
    // cyan, so it is never the baseline purple.
    tertiary: WalseyColors.accentCyan,
    onTertiary: WalseyColors.bg,
    tertiaryContainer: WalseyColors.surfaceRaised,
    onTertiaryContainer: WalseyColors.text,
    surface: WalseyColors.surface,
    onSurface: WalseyColors.text,
    surfaceDim: WalseyColors.bg,
    surfaceBright: WalseyColors.surfaceRaised,
    surfaceContainerLowest: WalseyColors.bg,
    surfaceContainerLow: WalseyColors.surface,
    surfaceContainer: WalseyColors.surface,
    surfaceContainerHigh: WalseyColors.surfaceRaised,
    surfaceContainerHighest: WalseyColors.surfaceRaised,
    onSurfaceVariant: WalseyColors.textSecondary,
    outline: WalseyColors.border,
    outlineVariant: WalseyColors.border,
    inverseSurface: WalseyColors.text,
    onInverseSurface: WalseyColors.bg,
    inversePrimary: accent.color,
    shadow: WalseyColors.bg,
    scrim: WalseyColors.bg,
    error: WalseyColors.error,
    onError: Colors.white,
    errorContainer: WalseyColors.errorBg,
    onErrorContainer: WalseyColors.errorText,
  );

  final textTheme = const TextTheme(
    headlineMedium: WalseyType.pageTitle,
    titleLarge: WalseyType.sectionTitle,
    titleMedium: WalseyType.rowTitle,
    bodyLarge: WalseyType.body,
    bodyMedium: WalseyType.body,
    bodySmall: WalseyType.caption,
    labelLarge: TextStyle(
      fontFamily: WalseyType.family,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: TextStyle(
      fontFamily: WalseyType.family,
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: WalseyType.badge,
  );

  final rounded = BorderRadius.circular(WalseyRadius.control);

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: WalseyType.family,
    colorScheme: scheme,
    scaffoldBackgroundColor: WalseyColors.bg,
    canvasColor: WalseyColors.bg,
    dividerColor: WalseyColors.border,
    splashFactory: InkRipple.splashFactory,
    splashColor: accent.color.withValues(alpha: 0.10),
    highlightColor: accent.color.withValues(alpha: 0.06),
    hoverColor: WalseyColors.text.withValues(alpha: 0.04),
    focusColor: accent.color.withValues(alpha: 0.14),
    disabledColor: WalseyColors.textMuted,
    textTheme: textTheme,
    iconTheme: const IconThemeData(color: WalseyColors.textSecondary, size: 20),
    appBarTheme: const AppBarTheme(
      backgroundColor: WalseyColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: WalseyColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WalseyRadius.card),
        side: const BorderSide(color: WalseyColors.border),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: WalseyColors.border,
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent.color,
        foregroundColor: Colors.white,
        disabledBackgroundColor: WalseyColors.surfaceRaised,
        disabledForegroundColor: WalseyColors.textMuted,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: rounded),
        textStyle: const TextStyle(
          fontFamily: WalseyType.family,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: WalseyColors.text,
        disabledForegroundColor: WalseyColors.textMuted,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        side: const BorderSide(color: WalseyColors.border),
        shape: RoundedRectangleBorder(borderRadius: rounded),
        textStyle: const TextStyle(
          fontFamily: WalseyType.family,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: WalseyColors.primaryText,
        minimumSize: const Size(44, 44),
        textStyle: const TextStyle(
          fontFamily: WalseyType.family,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: WalseyColors.textSecondary,
        minimumSize: const Size(44, 44),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: WalseyColors.bg,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      hintStyle: WalseyType.caption,
      labelStyle: WalseyType.caption,
      floatingLabelStyle: const TextStyle(
        fontFamily: WalseyType.family,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: WalseyColors.primaryText,
      ),
      border: OutlineInputBorder(
        borderRadius: rounded,
        borderSide: const BorderSide(color: WalseyColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: rounded,
        borderSide: const BorderSide(color: WalseyColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: rounded,
        borderSide: BorderSide(color: accent.color, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: rounded,
        borderSide: const BorderSide(color: WalseyColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: rounded,
        borderSide: const BorderSide(color: WalseyColors.error, width: 1.4),
      ),
      errorStyle: const TextStyle(
        fontFamily: WalseyType.family,
        fontSize: 12,
        color: WalseyColors.errorText,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: WalseyColors.surfaceRaised,
      selectedColor: accent.tint,
      disabledColor: WalseyColors.surface,
      side: const BorderSide(color: WalseyColors.border),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WalseyRadius.chip),
      ),
      labelStyle: const TextStyle(
        fontFamily: WalseyType.family,
        fontSize: 12,
        color: WalseyColors.textSecondary,
      ),
      secondaryLabelStyle: const TextStyle(
        fontFamily: WalseyType.family,
        fontSize: 12,
        color: WalseyColors.primaryText,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : WalseyColors.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent.color
            : WalseyColors.track,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: accent.color,
      inactiveTrackColor: WalseyColors.border,
      thumbColor: Colors.white,
      overlayColor: accent.color.withValues(alpha: 0.16),
      trackHeight: 4,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      valueIndicatorColor: WalseyColors.surfaceRaised,
      valueIndicatorTextStyle: const TextStyle(
        fontFamily: WalseyType.family,
        color: WalseyColors.text,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent.color,
      linearTrackColor: WalseyColors.border,
      linearMinHeight: 6,
      circularTrackColor: WalseyColors.border,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: WalseyColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WalseyRadius.sheet),
        side: const BorderSide(color: WalseyColors.border),
      ),
      titleTextStyle: const TextStyle(
        fontFamily: WalseyType.family,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: WalseyColors.text,
      ),
      contentTextStyle: WalseyType.body,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: WalseyColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: WalseyColors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(WalseyRadius.sheet),
        ),
      ),
      showDragHandle: true,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: WalseyColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: accent.tint,
      elevation: 0,
      height: 66,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? WalseyColors.primaryText
              : WalseyColors.textMuted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: WalseyType.family,
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? WalseyColors.primaryText
              : WalseyColors.textMuted,
        ),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: WalseyColors.text,
      unselectedLabelColor: WalseyColors.textMuted,
      indicatorColor: accent.color,
      dividerColor: WalseyColors.border,
      labelStyle: const TextStyle(
        fontFamily: WalseyType.family,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelStyle: const TextStyle(
        fontFamily: WalseyType.family,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: WalseyColors.surfaceRaised,
      contentTextStyle: WalseyType.body,
      actionTextColor: WalseyColors.primaryText,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WalseyRadius.card),
        side: const BorderSide(color: WalseyColors.border),
      ),
    ),
    // Material 3 components below were previously left on their defaults,
    // which resolve through the baseline palette (not the Walsey tokens).
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent.tint
              : WalseyColors.surfaceRaised,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? WalseyColors.primaryText
              : WalseyColors.textSecondary,
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? WalseyColors.primaryText
              : WalseyColors.textMuted,
        ),
        overlayColor: WidgetStatePropertyAll(
          accent.color.withValues(alpha: 0.12),
        ),
        side: const WidgetStatePropertyAll(
          BorderSide(color: WalseyColors.border),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: rounded),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: WalseyType.family,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent.color
            : Colors.transparent,
      ),
      checkColor: const WidgetStatePropertyAll(Colors.white),
      overlayColor: WidgetStatePropertyAll(
        accent.color.withValues(alpha: 0.12),
      ),
      side: const BorderSide(color: WalseyColors.border, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent.color
            : WalseyColors.textSecondary,
      ),
      overlayColor: WidgetStatePropertyAll(
        accent.color.withValues(alpha: 0.12),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: WalseyType.body,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: WalseyColors.bg,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        hintStyle: WalseyType.caption,
        labelStyle: WalseyType.caption,
        border: OutlineInputBorder(
          borderRadius: rounded,
          borderSide: const BorderSide(color: WalseyColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: rounded,
          borderSide: const BorderSide(color: WalseyColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: rounded,
          borderSide: BorderSide(color: accent.color, width: 1.4),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: WalseyColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      textStyle: WalseyType.body,
      iconColor: WalseyColors.textSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WalseyRadius.card),
        side: const BorderSide(color: WalseyColors.border),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent.color,
      selectionColor: accent.color.withValues(alpha: 0.30),
      selectionHandleColor: accent.color,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      textColor: WalseyColors.text,
      collapsedTextColor: WalseyColors.text,
      iconColor: WalseyColors.textSecondary,
      collapsedIconColor: WalseyColors.textSecondary,
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      shape: const Border(),
      collapsedShape: const Border(),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: WalseyColors.surfaceRaised,
        borderRadius: BorderRadius.circular(WalseyRadius.badge),
        border: Border.all(color: WalseyColors.border),
      ),
      textStyle: WalseyType.caption.copyWith(color: WalseyColors.text),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(
        WalseyColors.textMuted.withValues(alpha: 0.35),
      ),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: WalseyColors.textSecondary,
      textColor: WalseyColors.text,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}
