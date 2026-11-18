import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:walsey/design/tokens.dart';
import 'package:walsey/state/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads documented defaults when nothing is stored', () async {
    final settings = await AppSettingsService.load();
    addTearDown(settings.dispose);

    expect(settings.value.accent, WalseyAccent.violet);
    expect(settings.value.displayName, '');
    expect(settings.value.showDiagnosticsPanel, isTrue);
    expect(settings.value.spokenResponses, isFalse);
    expect(settings.value.wakeWordEnabled, isFalse);
    expect(settings.value.favoriteColors, isEmpty);
    expect(settings.value.lastDeviceName, isNull);
    expect(settings.value.lastDeviceAt, isNull);
  });

  test('accent, name, dock and device memory survive a reload', () async {
    final settings = await AppSettingsService.load();
    await settings.setAccent(WalseyAccent.cyan);
    await settings.setDisplayName('  Alex  ');
    await settings.setShowDiagnosticsPanel(false);
    await settings.setSpokenResponses(true);
    await settings.setWakeWordEnabled(true);
    await settings.rememberDevice('LEDDMX-03-6B4A');
    settings.dispose();

    final reloaded = await AppSettingsService.load();
    addTearDown(reloaded.dispose);

    expect(reloaded.value.accent, WalseyAccent.cyan);
    expect(reloaded.value.displayName, 'Alex');
    expect(reloaded.value.showDiagnosticsPanel, isFalse);
    expect(reloaded.value.spokenResponses, isTrue);
    expect(reloaded.value.wakeWordEnabled, isTrue);
    expect(reloaded.value.lastDeviceName, 'LEDDMX-03-6B4A');
    expect(reloaded.value.lastDeviceAt, isNotNull);
  });

  test('favourites are prepended, toggled off and persisted', () async {
    final settings = await AppSettingsService.load();

    await settings.toggleFavoriteColor(0xFF0000);
    await settings.toggleFavoriteColor(0x00FF00);
    expect(settings.value.favoriteColors, [0x00FF00, 0xFF0000]);

    await settings.toggleFavoriteColor(0xFF0000);
    expect(settings.value.favoriteColors, [0x00FF00]);
    settings.dispose();

    final reloaded = await AppSettingsService.load();
    addTearDown(reloaded.dispose);
    expect(reloaded.value.favoriteColors, [0x00FF00]);
  });

  test('favourites are capped at twelve entries', () async {
    final settings = await AppSettingsService.load();
    addTearDown(settings.dispose);

    for (var index = 0; index < 14; index++) {
      await settings.toggleFavoriteColor(0x100000 + index);
    }

    expect(settings.value.favoriteColors, hasLength(12));
    // The newest colour is first and the oldest were dropped.
    expect(settings.value.favoriteColors.first, 0x100000 + 13);
    expect(settings.value.favoriteColors, isNot(contains(0x100000)));
  });

  test('unknown stored accent falls back to violet', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'walsey.accent': 'not-a-tint',
    });

    final settings = await AppSettingsService.load();
    addTearDown(settings.dispose);
    expect(settings.value.accent, WalseyAccent.violet);
  });

  test('in-memory settings work without touching disk', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = AppSettingsService.inMemory();
    addTearDown(settings.dispose);

    await settings.setAccent(WalseyAccent.amber);
    await settings.setDisplayName('Local only');

    expect(settings.value.accent, WalseyAccent.amber);
    expect(settings.value.displayName, 'Local only');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('walsey.accent'), isNull);
    expect(prefs.getString('walsey.displayName'), isNull);
  });
}
