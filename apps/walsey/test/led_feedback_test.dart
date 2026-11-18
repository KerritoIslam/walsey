import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/control/led_feedback.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

class _FakeSink implements LedFeedbackSink {
  final List<RgbColor> colors = [];
  final List<BrightnessLevel> levels = [];
  bool colorResult = true;
  bool levelResult = true;
  Completer<void>? gate;

  @override
  Future<bool> setColor(RgbColor color) async {
    colors.add(color);
    final waiting = gate;
    if (waiting != null) await waiting.future;
    return colorResult;
  }

  @override
  Future<bool> setBrightness(BrightnessLevel brightness) async {
    levels.add(brightness);
    return levelResult;
  }
}

/// In-memory only: no driver, no transport, no frame and no hardware.
/// "sent" means the sink accepted a write, never that an LED changed.
void main() {
  late _FakeSink sink;

  setUp(() => sink = _FakeSink());

  test('off by default and never sends on construction or remember', () async {
    final feedback = LedFeedbackController(sink: sink);
    feedback.rememberCommanded(
      color: RgbColor(0, 0, 255),
      brightness: BrightnessLevel(70),
    );
    expect(await feedback.cue(LedFeedbackMoment.listening),
        LedFeedbackOutcome.disabled);
    expect(await feedback.restore(), LedFeedbackOutcome.disabled);
    expect(sink.colors, isEmpty);
    expect(sink.levels, isEmpty);
  });

  test('each moment maps to its fixed cue colour', () async {
    final feedback = LedFeedbackController(sink: sink, enabled: true);
    expect(await feedback.cue(LedFeedbackMoment.listening),
        LedFeedbackOutcome.sent);
    expect(await feedback.cue(LedFeedbackMoment.success), LedFeedbackOutcome.sent);
    expect(await feedback.cue(LedFeedbackMoment.failure), LedFeedbackOutcome.sent);
    expect(sink.colors, [
      LedFeedbackController.listeningColor,
      LedFeedbackController.successColor,
      LedFeedbackController.failureColor,
    ]);
  });

  test('a cue is single-flight', () async {
    sink.gate = Completer<void>();
    final feedback = LedFeedbackController(sink: sink, enabled: true);
    final first = feedback.cue(LedFeedbackMoment.listening);
    await Future<void>.delayed(Duration.zero);
    expect(await feedback.cue(LedFeedbackMoment.success), LedFeedbackOutcome.busy);
    sink.gate!.complete();
    expect(await first, LedFeedbackOutcome.sent);
    expect(sink.colors, hasLength(1));
  });

  test('restore is refused when nothing was commanded before the cue', () async {
    final feedback = LedFeedbackController(sink: sink, enabled: true);
    await feedback.cue(LedFeedbackMoment.listening);
    expect(await feedback.restore(), LedFeedbackOutcome.nothingToRestore);
    expect(sink.colors, hasLength(1));
  });

  test('restore re-sends the cached commanded colour and brightness', () async {
    final feedback = LedFeedbackController(sink: sink, enabled: true);
    feedback.rememberCommanded(
      color: RgbColor(10, 20, 30),
      brightness: BrightnessLevel(65),
    );
    await feedback.cue(LedFeedbackMoment.listening);
    expect(await feedback.restore(), LedFeedbackOutcome.restored);
    expect(sink.colors.last, RgbColor(10, 20, 30));
    expect(sink.levels.single, BrightnessLevel(65));

    // A second restore has nothing left to do.
    expect(await feedback.restore(), LedFeedbackOutcome.nothingToRestore);
  });

  test('restore without a cached brightness still restores the colour', () async {
    final feedback = LedFeedbackController(sink: sink, enabled: true);
    feedback.rememberCommanded(color: RgbColor(1, 2, 3));
    await feedback.cue(LedFeedbackMoment.failure);
    expect(await feedback.restore(), LedFeedbackOutcome.restored);
    expect(sink.colors.last, RgbColor(1, 2, 3));
    expect(sink.levels, isEmpty);
  });

  test('a refused write is reported as failed, not confirmed', () async {
    sink.colorResult = false;
    final feedback = LedFeedbackController(sink: sink, enabled: true);
    expect(await feedback.cue(LedFeedbackMoment.success),
        LedFeedbackOutcome.failed);
  });

  test('an exception in the sink is a failure, never a success', () async {
    final throwing = _ThrowingSink();
    final feedback = LedFeedbackController(sink: throwing, enabled: true);
    expect(await feedback.cue(LedFeedbackMoment.success),
        LedFeedbackOutcome.failed);
  });
}

class _ThrowingSink implements LedFeedbackSink {
  @override
  Future<bool> setColor(RgbColor color) async => throw StateError('no link');

  @override
  Future<bool> setBrightness(BrightnessLevel brightness) async => false;
}
