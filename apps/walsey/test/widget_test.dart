import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/app/app_shell.dart';
import 'package:walsey/connection/led_connection_service.dart';
import 'package:walsey/design/theme.dart';
import 'package:walsey/state/activity_log.dart';
import 'package:walsey/state/app_settings.dart';

import 'fakes.dart';

void main() {
  testWidgets('desktop shell shows sidebar navigation and dashboard', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late LedConnectionService service;
    await tester.runAsync(() async {
      service = LedConnectionService(central: FakeCentral());
    });
    final settings = AppSettingsService.inMemory(
      const AppSettings(showDiagnosticsPanel: false),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWalseyTheme(),
        home: WalseyShell(
          service: service,
          settings: settings,
          activity: ActivityLog(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Walsey'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Devices'), findsWidgets);
    expect(find.text('Studio'), findsWidgets);
    expect(find.text('Assistant'), findsWidgets);
    expect(find.text('Connect'), findsWidgets);
    expect(find.text('Automations'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Start scan'), findsOneWidget);

    // The diagnostic dock is opt-in and hidden in this configuration.
    expect(find.textContaining('Walsey app initialized'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.dispose);
    settings.dispose();
  });

  testWidgets('narrow layout uses five bottom navigation destinations', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late LedConnectionService service;
    await tester.runAsync(() async {
      service = LedConnectionService(central: FakeCentral());
    });
    final settings = AppSettingsService.inMemory(
      const AppSettings(showDiagnosticsPanel: false),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWalseyTheme(),
        home: WalseyShell(
          service: service,
          settings: settings,
          activity: ActivityLog(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Devices'), findsWidgets);
    expect(find.text('Studio'), findsWidgets);
    expect(find.text('Assistant'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Connect'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Studio'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('LED Studio'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.dispose);
    settings.dispose();
  });

  testWidgets('every mobile destination renders without layout errors', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late LedConnectionService service;
    await tester.runAsync(() async {
      service = LedConnectionService(central: FakeCentral());
    });
    final settings = AppSettingsService.inMemory(
      const AppSettings(showDiagnosticsPanel: false),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWalseyTheme(),
        home: WalseyShell(
          service: service,
          settings: settings,
          activity: ActivityLog(),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    for (final destination in const [
      'Devices',
      'Studio',
      'Assistant',
      'Settings',
      'Home',
    ]) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(destination),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: '$destination rendered at 390x844',
      );
    }

    // Activity is reachable from the dashboard, not a sixth destination.
    await tester.tap(find.byTooltip('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Activity'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Back to dashboard'));
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.dispose);
    settings.dispose();
  });

  testWidgets('desktop sidebar reaches planned pages and secondary pages', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late LedConnectionService service;
    await tester.runAsync(() async {
      service = LedConnectionService(central: FakeCentral());
    });
    final settings = AppSettingsService.inMemory(
      const AppSettings(showDiagnosticsPanel: false),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWalseyTheme(),
        home: WalseyShell(
          service: service,
          settings: settings,
          activity: ActivityLog(),
        ),
      ),
    );
    await tester.pump();

    for (final (label, heading) in const [
      ('Connect', 'Phone ↔ PC'),
      ('Automations', 'Automations'),
      ('Activity', 'Activity'),
      ('Settings', 'Settings'),
      ('Home', 'Dashboard'),
    ]) {
      await tester.tap(find.text(label).first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text(heading), findsWidgets, reason: '$label → $heading');
      expect(tester.takeException(), isNull, reason: '$label rendered');
    }

    // Planned pages must say so, and must not offer working controls.
    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();
    expect(find.text('Planned'), findsWidgets);
    expect(find.text('Not built'), findsWidgets);
    expect(find.text('Pair'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.dispose);
    settings.dispose();
  });
}
