import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_test/main.dart';

Future<void> analyze(WidgetTester tester, String input) async {
  await tester.enterText(find.byType(TextField), input);
  await tester.tap(find.text('Analyze'));
  await tester.pumpAndSettle();
}

/// The Stage 2 page is taller than the 800x600 default test surface, so the
/// chips and buttons below the microphone panel would be off-screen and taps
/// would miss them. Tests use a phone-sized tall surface instead.
Future<void> pumpVoiceTestApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(const WalseyVoiceTestApp());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows that Stage 2 cannot execute anything', (tester) async {
    await pumpVoiceTestApp(tester);

    expect(find.text('Walsey voice — Stage 2 test'), findsOneWidget);
    expect(find.textContaining('execution disabled'), findsOneWidget);
    expect(
      find.textContaining('Nothing you type here can change the LEDs'),
      findsOneWidget,
    );
    expect(find.text('Interpretation'), findsNothing);
  });

  testWidgets(
    'valid brightness command shows intent, parameter and no execution',
    (tester) async {
      await pumpVoiceTestApp(tester);

      await analyze(tester, 'Set brightness to 50 percent');

      expect(find.text('Interpretation'), findsOneWidget);
      expect(find.text('Set brightness'), findsOneWidget);
      expect(find.text('setBrightness'), findsOneWidget);
      expect(find.text('Brightness: 50%'), findsOneWidget);
      expect(find.text('Valid command'), findsWidgets);
      expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
      expect(
        find.textContaining('Parsing and validation succeeded'),
        findsOneWidget,
      );
    },
  );

  testWidgets('valid colour command shows the parsed colour', (tester) async {
    await pumpVoiceTestApp(tester);

    await analyze(tester, 'Turn the lights blue.');

    expect(find.text('Set color'), findsOneWidget);
    expect(find.text('Color: blue'), findsOneWidget);
    expect(find.text('Valid command'), findsWidgets);
  });

  testWidgets('ambiguous command is explained, not guessed', (tester) async {
    await pumpVoiceTestApp(tester);

    await analyze(tester, 'Turn the lights on and off');

    expect(find.text('Ambiguous command'), findsWidgets);
    expect(find.textContaining('both "on" and "off"'), findsOneWidget);
    expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
  });

  testWidgets('unsupported sentence is explained', (tester) async {
    await pumpVoiceTestApp(tester);

    await analyze(tester, 'Tell me a joke');

    expect(find.text('Unsupported command'), findsWidgets);
    expect(
      find.textContaining('question or an information request'),
      findsOneWidget,
    );
    expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
  });

  testWidgets('out-of-range brightness is rejected, not clamped', (
    tester,
  ) async {
    await pumpVoiceTestApp(tester);

    await analyze(tester, 'Set brightness to 150 percent');

    expect(find.text('Invalid parameter'), findsWidgets);
    expect(
      find.textContaining('Brightness must be 0..100 percent, got 150'),
      findsOneWidget,
    );
    expect(find.text('Not executed — Stage 2 testing mode'), findsOneWidget);
  });

  testWidgets('example chips analyze without retyping', (tester) async {
    await pumpVoiceTestApp(tester);

    await tester.tap(find.text('Walsey, set brightness to 50 percent.').first);
    await tester.pumpAndSettle();

    expect(find.text('Brightness: 50%'), findsOneWidget);
    expect(find.text('Valid command'), findsWidgets);
  });

  testWidgets('clear removes both the input and the interpretation', (
    tester,
  ) async {
    await pumpVoiceTestApp(tester);

    await analyze(tester, 'Turn the lights on');
    expect(find.text('Interpretation'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('Interpretation'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
  });
}

