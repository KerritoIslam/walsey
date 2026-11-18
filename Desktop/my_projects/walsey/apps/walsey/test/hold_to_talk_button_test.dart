import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/design/hold_to_talk_button.dart';
import 'package:walsey/design/theme.dart';
import 'package:walsey/voice/voice_session_controller.dart';

void main() {
  Widget host({
    required VoiceSessionPhase phase,
    bool enabled = true,
    VoidCallback? onStart,
    VoidCallback? onEnd,
    VoidCallback? onCancel,
  }) =>
      MaterialApp(
        theme: buildWalseyTheme(),
        home: Scaffold(
          body: Center(
            child: HoldToTalkButton(
              phase: phase,
              enabled: enabled,
              onPressStart: onStart ?? () {},
              onPressEnd: onEnd ?? () {},
              onPressCancel: onCancel ?? () {},
            ),
          ),
        ),
      );

  testWidgets('pointer down starts; release outside still ends the take',
      (tester) async {
    var starts = 0;
    var ends = 0;
    await tester.pumpWidget(
      host(
        phase: VoiceSessionPhase.idle,
        onStart: () => starts++,
        onEnd: () => ends++,
      ),
    );

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(HoldToTalkButton)));
    await tester.pump();
    expect(starts, 1);
    expect(ends, 0);

    // Leaving the widget must not lose the release.
    await gesture.moveTo(const Offset(2, 2));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(ends, 1);
  });

  testWidgets('pointer cancel reports a cancel, not a release', (tester) async {
    var ends = 0;
    var cancels = 0;
    await tester.pumpWidget(
      host(
        phase: VoiceSessionPhase.recording,
        onEnd: () => ends++,
        onCancel: () => cancels++,
      ),
    );

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(HoldToTalkButton)));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();

    expect(cancels, 1);
    expect(ends, 0);
  });

  testWidgets('a disabled button never starts a session', (tester) async {
    var starts = 0;
    await tester.pumpWidget(
      host(
        phase: VoiceSessionPhase.executing,
        enabled: false,
        onStart: () => starts++,
      ),
    );

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(HoldToTalkButton)));
    await gesture.up();
    await tester.pump();

    expect(starts, 0);
  });

  testWidgets('release still ends the take when enabled flips false while held',
      (tester) async {
    // Regression: the real Assistant passes `enabled: canStart`, which becomes
    // false as soon as the session is busy. Previously that cleared onEnd on
    // the live recognizer, so releasing the button never stopped the recording.
    var starts = 0;
    var ends = 0;
    var enabled = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildWalseyTheme(),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                return HoldToTalkButton(
                  phase: enabled
                      ? VoiceSessionPhase.idle
                      : VoiceSessionPhase.recording,
                  enabled: enabled,
                  onPressStart: () {
                    starts++;
                    setState(() => enabled = false);
                  },
                  onPressEnd: () => ends++,
                  onPressCancel: () {},
                );
              },
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToTalkButton)),
    );
    await tester.pump();
    expect(starts, 1);
    expect(enabled, isFalse);

    await gesture.up();
    await tester.pump();
    expect(ends, 1);
  });

  testWidgets('phases have distinct labels and do not use a fake meter',
      (tester) async {
    for (final entry in const {
      VoiceSessionPhase.idle: 'Hold to talk',
      VoiceSessionPhase.recording: 'Recording — release to decode',
      VoiceSessionPhase.processing: 'Transcribing…',
      VoiceSessionPhase.interpreting: 'Interpreting…',
      VoiceSessionPhase.executing: 'Executing…',
      VoiceSessionPhase.success: 'Hold to talk',
      VoiceSessionPhase.answered: 'Hold to talk',
      VoiceSessionPhase.failure: 'Hold to talk',
    }.entries) {
      await tester.pumpWidget(host(phase: entry.key));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('removal while held cancels instead of leaving it open',
      (tester) async {
    var starts = 0;
    var ends = 0;
    var cancels = 0;
    await tester.pumpWidget(
      host(
        phase: VoiceSessionPhase.recording,
        onStart: () => starts++,
        onEnd: () => ends++,
        onCancel: () => cancels++,
      ),
    );

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(HoldToTalkButton)));
    await tester.pump();
    expect(starts, 1);

    // Navigation away disposes the button while the pointer is down.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(cancels, 1);
    expect(ends, 0);

    await gesture.up();
    await tester.pump();
    expect(ends, 0);
  });
}
