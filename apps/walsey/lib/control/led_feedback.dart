// Private named parameters cannot be initializing formals; the constructor's
// public names are the package API.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import '../control/led_control_service.dart';

/// The last LED state **the app commanded**. This is not device state: the
/// protocol has no read-back, so it can never represent what the controller
/// actually shows.
@immutable
final class CommandedLedState {
  const CommandedLedState({required this.color, this.brightness});

  final RgbColor color;
  final BrightnessLevel? brightness;
}

/// Voice-assistant moments that could be indicated on the LEDs.
enum LedFeedbackMoment { listening, success, failure }

/// One LED write pair used by [LedFeedbackController].
///
/// Deliberately tiny: the controller can be tested with an in-memory sink and
/// never needs a driver, a transport or hardware.
abstract interface class LedFeedbackSink {
  /// Returns true only when the frame was written. Never claims the LEDs
  /// changed.
  Future<bool> setColor(RgbColor color);

  Future<bool> setBrightness(BrightnessLevel brightness);
}

/// [LedFeedbackSink] over the existing typed command facade.
final class LedControlFeedbackSink implements LedFeedbackSink {
  LedControlFeedbackSink(this._control);

  final LedControlService _control;

  @override
  Future<bool> setColor(RgbColor color) async =>
      await _control.setColor(color) is CommandSent;

  @override
  Future<bool> setBrightness(BrightnessLevel brightness) async =>
      await _control.setBrightness(brightness) is CommandSent;
}

/// Outcome of a cue, stated honestly.
enum LedFeedbackOutcome {
  /// The cue frames were written. The LED reaction is unknown.
  sent,
  restored,
  disabled,
  busy,
  nothingToRestore,
  failed;

  bool get wroteFrames => this == sent || this == restored;
}

/// Opt-in LED indication for the voice assistant.
///
/// Safety properties:
///  - **off by default**; nothing is sent until a caller sets [enabled];
///  - never sends on construction, on remember, or on a settings change;
///  - one cue at a time ([LedFeedbackOutcome.busy] otherwise), so it cannot
///    interleave with itself;
///  - "restore" re-sends the cached *commanded* colour/brightness. With no
///    cached state it returns [LedFeedbackOutcome.nothingToRestore] instead of
///    guessing;
///  - [LedFeedbackOutcome.sent] means "frame written", never "LEDs changed".
///
/// No shipped code path enables or calls it: this is the documented abstraction
/// requested for the voice work, and it stays dormant until the hardware
/// checklist allows LED-frame testing.
final class LedFeedbackController {
  LedFeedbackController({
    required LedFeedbackSink sink,
    this.enabled = false,
  }) : _sink = sink;

  /// Fixed cue colours. Amber = taking input, green = written, red = refused.
  static final RgbColor listeningColor = RgbColor(0xFF, 0xB0, 0x20);
  static final RgbColor successColor = RgbColor(0x00, 0xC8, 0x53);
  static final RgbColor failureColor = RgbColor(0xD5, 0x00, 0x00);

  final LedFeedbackSink _sink;
  bool enabled;
  bool _inFlight = false;

  CommandedLedState? _commanded;
  CommandedLedState? _preCue;

  /// Records a state the app just commanded. Does not send anything.
  void rememberCommanded({
    required RgbColor color,
    BrightnessLevel? brightness,
  }) {
    _commanded = CommandedLedState(color: color, brightness: brightness);
  }

  /// Writes the cue for [moment].
  Future<LedFeedbackOutcome> cue(LedFeedbackMoment moment) async {
    if (!enabled) return LedFeedbackOutcome.disabled;
    if (_inFlight) return LedFeedbackOutcome.busy;
    _inFlight = true;
    try {
      // Keep the last commanded state so a caller can restore it explicitly.
      // There is no read-back, so an unknown state stays unknown.
      _preCue = _commanded;
      final wrote = await _write(
        switch (moment) {
          LedFeedbackMoment.listening => listeningColor,
          LedFeedbackMoment.success => successColor,
          LedFeedbackMoment.failure => failureColor,
        },
      );
      return wrote ? LedFeedbackOutcome.sent : LedFeedbackOutcome.failed;
    } finally {
      _inFlight = false;
    }
  }

  /// Re-sends the state cached before the last cue.
  Future<LedFeedbackOutcome> restore() async {
    if (!enabled) return LedFeedbackOutcome.disabled;
    if (_inFlight) return LedFeedbackOutcome.busy;
    final previous = _preCue;
    if (previous == null) return LedFeedbackOutcome.nothingToRestore;
    _inFlight = true;
    try {
      final wrote = await _write(previous.color);
      if (!wrote) return LedFeedbackOutcome.failed;
      final brightness = previous.brightness;
      if (brightness != null) {
        final levelWrote = await _sink.setBrightness(brightness);
        if (!levelWrote) return LedFeedbackOutcome.failed;
      }
      _preCue = null;
      return LedFeedbackOutcome.restored;
    } finally {
      _inFlight = false;
    }
  }

  Future<bool> _write(RgbColor color) async {
    try {
      return await _sink.setColor(color);
    } on Object {
      return false;
    }
  }
}
