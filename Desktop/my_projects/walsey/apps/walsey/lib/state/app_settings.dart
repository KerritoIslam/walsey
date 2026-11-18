import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/tokens.dart';

/// User preferences that genuinely affect this build.
///
/// Nothing here pretends to represent device state: the protocol has no
/// read-back, so settings only describe the app itself.
@immutable
final class AppSettings {
  const AppSettings({
    this.accent = WalseyAccent.violet,
    this.displayName = '',
    this.showDiagnosticsPanel = true,
    this.spokenResponses = false,
    this.wakeWordEnabled = false,
    this.favoriteColors = const <int>[],
    this.lastDeviceName,
    this.lastDeviceAt,
  });

  final WalseyAccent accent;
  final String displayName;
  final bool showDiagnosticsPanel;

  /// Speak a short outcome after a voice session. Off by default; uses the
  /// operating system's installed voice, no download.
  final bool spokenResponses;

  /// Consent for hands-free wake-word listening. This is a preference only:
  /// listening still starts from an explicit button press, never at launch.
  final bool wakeWordEnabled;

  /// RGB values (`0xRRGGBB`) saved from LED Studio.
  final List<int> favoriteColors;

  final String? lastDeviceName;
  final DateTime? lastDeviceAt;

  AppSettings copyWith({
    WalseyAccent? accent,
    String? displayName,
    bool? showDiagnosticsPanel,
    bool? spokenResponses,
    bool? wakeWordEnabled,
    List<int>? favoriteColors,
    String? lastDeviceName,
    DateTime? lastDeviceAt,
  }) => AppSettings(
    accent: accent ?? this.accent,
    displayName: displayName ?? this.displayName,
    showDiagnosticsPanel: showDiagnosticsPanel ?? this.showDiagnosticsPanel,
    spokenResponses: spokenResponses ?? this.spokenResponses,
    wakeWordEnabled: wakeWordEnabled ?? this.wakeWordEnabled,
    favoriteColors: favoriteColors ?? this.favoriteColors,
    lastDeviceName: lastDeviceName ?? this.lastDeviceName,
    lastDeviceAt: lastDeviceAt ?? this.lastDeviceAt,
  );
}

/// Tiny offline settings store backed by `shared_preferences`.
///
/// Loaded once at startup; every mutation updates a [ValueNotifier] first so
/// the UI never waits on disk. Persistence failures are logged and ignored
/// rather than blocking a user action.
final class AppSettingsService {
  AppSettingsService._(this._prefs, this._value);

  static const _accentKey = 'walsey.accent';
  static const _nameKey = 'walsey.displayName';
  static const _diagnosticsKey = 'walsey.showDiagnosticsPanel';
  static const _spokenKey = 'walsey.spokenResponses';
  static const _wakeWordKey = 'walsey.wakeWordEnabled';
  static const _favoritesKey = 'walsey.favoriteColors';
  static const _lastDeviceKey = 'walsey.lastDeviceName';
  static const _lastDeviceAtKey = 'walsey.lastDeviceAt';

  final SharedPreferences? _prefs;
  final ValueNotifier<AppSettings> _value;

  ValueListenable<AppSettings> get listenable => _value;
  AppSettings get value => _value.value;

  static AppSettingsService inMemory([AppSettings initial = const AppSettings()]) =>
      AppSettingsService._(null, ValueNotifier<AppSettings>(initial));

  static Future<AppSettingsService> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object catch (error) {
      debugPrint('[WalseyApp] settings unavailable: $error');
    }
    if (prefs == null) {
      return AppSettingsService._(null, ValueNotifier(const AppSettings()));
    }

    final accent = WalseyAccent.fromName(prefs.getString(_accentKey));
    final favorites = <int>[];
    for (final raw in prefs.getStringList(_favoritesKey) ?? const <String>[]) {
      final value = int.tryParse(raw);
      if (value != null) favorites.add(value);
    }
    final lastDeviceAt = DateTime.tryParse(
      prefs.getString(_lastDeviceAtKey) ?? '',
    );

    return AppSettingsService._(
      prefs,
      ValueNotifier(
        AppSettings(
          accent: accent,
          displayName: prefs.getString(_nameKey) ?? '',
          showDiagnosticsPanel: prefs.getBool(_diagnosticsKey) ?? true,
          spokenResponses: prefs.getBool(_spokenKey) ?? false,
          wakeWordEnabled: prefs.getBool(_wakeWordKey) ?? false,
          favoriteColors: List<int>.unmodifiable(favorites),
          lastDeviceName: prefs.getString(_lastDeviceKey),
          lastDeviceAt: lastDeviceAt,
        ),
      ),
    );
  }

  Future<void> setAccent(WalseyAccent accent) async {
    _update(value.copyWith(accent: accent));
    await _write((prefs) => prefs.setString(_accentKey, accent.name));
  }

  Future<void> setDisplayName(String name) async {
    _update(value.copyWith(displayName: name.trim()));
    await _write((prefs) => prefs.setString(_nameKey, name.trim()));
  }

  Future<void> setShowDiagnosticsPanel(bool show) async {
    _update(value.copyWith(showDiagnosticsPanel: show));
    await _write((prefs) => prefs.setBool(_diagnosticsKey, show));
  }

  Future<void> setSpokenResponses(bool spoken) async {
    _update(value.copyWith(spokenResponses: spoken));
    await _write((prefs) => prefs.setBool(_spokenKey, spoken));
  }

  Future<void> setWakeWordEnabled(bool enabled) async {
    _update(value.copyWith(wakeWordEnabled: enabled));
    await _write((prefs) => prefs.setBool(_wakeWordKey, enabled));
  }

  Future<void> toggleFavoriteColor(int rgb) async {
    final favorites = List<int>.of(value.favoriteColors);
    if (favorites.contains(rgb)) {
      favorites.remove(rgb);
    } else {
      favorites.insert(0, rgb);
      if (favorites.length > 12) favorites.removeLast();
    }
    _update(
      value.copyWith(favoriteColors: List<int>.unmodifiable(favorites)),
    );
    await _write(
      (prefs) => prefs.setStringList(
        _favoritesKey,
        favorites.map((color) => '$color').toList(),
      ),
    );
  }

  Future<void> rememberDevice(String name) async {
    final now = DateTime.now();
    _update(value.copyWith(lastDeviceName: name, lastDeviceAt: now));
    await _write((prefs) async {
      await prefs.setString(_lastDeviceKey, name);
      await prefs.setString(_lastDeviceAtKey, now.toIso8601String());
    });
  }

  void _update(AppSettings settings) => _value.value = settings;

  Future<void> _write(Future<void> Function(SharedPreferences prefs) action) async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await action(prefs);
    } on Object catch (error) {
      debugPrint('[WalseyApp] could not persist settings: $error');
    }
  }

  void dispose() => _value.dispose();
}
