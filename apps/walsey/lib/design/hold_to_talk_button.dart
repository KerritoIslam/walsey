import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../voice/voice_session_controller.dart';
import 'tokens.dart';

/// Hold-to-talk control.
///
/// The session starts on pointer down and ends on pointer up — including a
/// release outside the button — or on pointer cancel. Those are the only
/// transitions: a tap that never becomes a hold is a very short session, not a
/// toggle. There is no simulated audio meter; the rings are a state animation,
/// driven by the phase, never by microphone amplitude.
class HoldToTalkButton extends StatefulWidget {
  const HoldToTalkButton({
    super.key,
    required this.phase,
    required this.enabled,
    required this.onPressStart,
    required this.onPressEnd,
    required this.onPressCancel,
    this.label = 'Hold to talk',
    this.hint = 'Release to decode',
  });

  final VoiceSessionPhase phase;
  final bool enabled;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;
  final VoidCallback onPressCancel;
  final String label;
  final String hint;

  @override
  State<HoldToTalkButton> createState() => _HoldToTalkButtonState();
}

class _HoldToTalkButtonState extends State<HoldToTalkButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  bool get _active =>
      widget.phase == VoiceSessionPhase.pressing ||
      widget.phase == VoiceSessionPhase.recording ||
      widget.phase == VoiceSessionPhase.processing ||
      widget.phase == VoiceSessionPhase.interpreting ||
      widget.phase == VoiceSessionPhase.executing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant HoldToTalkButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) _syncPulse();
  }

  void _syncPulse() {
    final animate = _active && MediaQuery.maybeDisableAnimationsOf(context) != true;
    if (animate) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _Palette.of(context, widget.phase);
    final recording = widget.phase == VoiceSessionPhase.recording;
    final busy = widget.phase == VoiceSessionPhase.processing ||
        widget.phase == VoiceSessionPhase.interpreting ||
        widget.phase == VoiceSessionPhase.executing;
    final enabled = widget.enabled;
    final label = switch (widget.phase) {
      VoiceSessionPhase.idle ||
      VoiceSessionPhase.planned ||
      VoiceSessionPhase.answered ||
      VoiceSessionPhase.notExecuted ||
      VoiceSessionPhase.cancelled ||
      VoiceSessionPhase.success ||
      VoiceSessionPhase.failure =>
        widget.label,
      VoiceSessionPhase.pressing => 'Starting…',
      VoiceSessionPhase.recording => 'Recording — release to decode',
      VoiceSessionPhase.processing => 'Transcribing…',
      VoiceSessionPhase.interpreting => 'Interpreting…',
      VoiceSessionPhase.executing => 'Executing…',
    };
    final hint = switch (widget.phase) {
      VoiceSessionPhase.recording => 'Release anywhere to send this take',
      VoiceSessionPhase.pressing => 'The microphone is opening',
      VoiceSessionPhase.processing ||
      VoiceSessionPhase.interpreting ||
      VoiceSessionPhase.executing =>
        'Working on this device',
      VoiceSessionPhase.failure ||
      VoiceSessionPhase.cancelled ||
      VoiceSessionPhase.notExecuted =>
        'Hold again to try a new command',
      _ => widget.hint,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          enabled: enabled,
          label: label,
          hint: hint,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _HoldGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<_HoldGestureRecognizer>(
                () => _HoldGestureRecognizer(),
                (recognizer) {
                  // Only *starting* is gated by `enabled`. Ending and cancelling
                  // must stay wired: during a take the app sets `enabled` to
                  // false (the session is busy), and clearing `onEnd` here
                  // would leave the microphone recording after the release.
                  recognizer
                    ..onStart = enabled ? widget.onPressStart : null
                    ..onEnd = widget.onPressEnd
                    ..onCancel = widget.onPressCancel;
                },
              ),
            },
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) => SizedBox(
                width: 190,
                height: 190,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_active && enabled)
                      for (final offset in const [0.0, 0.33, 0.66])
                        _Ring(
                          progress: (_pulse.value + offset) % 1,
                          color: palette.ring,
                        ),
                    child!,
                  ],
                ),
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                width: recording ? 116 : 108,
                height: recording ? 116 : 108,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: enabled ? palette.fill : WalseyColors.surface,
                  border: Border.all(color: palette.border, width: 1.5),
                  boxShadow: _active && enabled
                      ? [
                          BoxShadow(
                            color: palette.glow,
                            blurRadius: recording ? 40 : 24,
                            spreadRadius: recording ? 6 : 2,
                          ),
                        ]
                      : null,
                ),
                child: busy
                    ? Center(
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: palette.icon,
                          ),
                        ),
                      )
                    : Icon(
                        recording
                            ? Icons.mic
                            : widget.phase == VoiceSessionPhase.success
                                ? Icons.check
                                : widget.phase == VoiceSessionPhase.failure ||
                                        widget.phase ==
                                            VoiceSessionPhase.notExecuted
                                    ? Icons.error_outline
                                    : Icons.mic_none,
                        size: 42,
                        color: palette.icon,
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: WalseySpacing.md),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(
            label,
            key: ValueKey(label),
            textAlign: TextAlign.center,
            style: recording
                ? WalseyType.body.copyWith(fontWeight: FontWeight.w600)
                : WalseyType.body,
          ),
        ),
        const SizedBox(height: WalseySpacing.xs),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: WalseyType.caption,
        ),
      ],
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final size = 120 + 60 * progress;
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: (1 - progress) * 0.35),
            width: 1.5,
          ),
        ),
      ),
    );
  }
}

/// Colors per phase, all derived from the design tokens. No component default
/// (Material baseline) color is used here.
class _Palette {
  const _Palette({
    required this.fill,
    required this.border,
    required this.icon,
    required this.ring,
    required this.glow,
  });

  factory _Palette.of(BuildContext context, VoiceSessionPhase phase) {
    final primary = Theme.of(context).colorScheme.primary;
    return switch (phase) {
      VoiceSessionPhase.recording ||
      VoiceSessionPhase.pressing =>
        _Palette(
          fill: primary,
          border: primary,
          icon: Colors.white,
          ring: primary,
          glow: primary.withValues(alpha: 0.35),
        ),
      VoiceSessionPhase.processing ||
      VoiceSessionPhase.interpreting ||
      VoiceSessionPhase.executing =>
        _Palette(
          fill: WalseyColors.surfaceRaised,
          border: WalseyColors.accentCyan,
          icon: WalseyColors.accentCyan,
          ring: WalseyColors.accentCyan,
          glow: WalseyColors.accentCyan.withValues(alpha: 0.22),
        ),
      VoiceSessionPhase.success => _Palette(
          fill: WalseyColors.successBg,
          border: WalseyColors.success,
          icon: WalseyColors.successText,
          ring: WalseyColors.success,
          glow: WalseyColors.success.withValues(alpha: 0.20),
        ),
      VoiceSessionPhase.failure ||
      VoiceSessionPhase.notExecuted =>
        _Palette(
          fill: WalseyColors.errorBg,
          border: WalseyColors.error,
          icon: WalseyColors.errorText,
          ring: WalseyColors.error,
          glow: WalseyColors.error.withValues(alpha: 0.20),
        ),
      VoiceSessionPhase.idle ||
      VoiceSessionPhase.cancelled ||
      VoiceSessionPhase.answered ||
      VoiceSessionPhase.planned =>
        _Palette(
          fill: WalseyColors.surfaceRaised,
          border: WalseyColors.border,
          icon: WalseyColors.textSecondary,
          ring: primary,
          glow: primary.withValues(alpha: 0.16),
        ),
    };
  }

  final Color fill;
  final Color border;
  final Color icon;
  final Color ring;
  final Color glow;
}

/// Starts on pointer down and keeps the pointer until up/cancel.
///
/// A plain `Listener` would stop receiving events when the finger leaves the
/// widget; this recognizer keeps tracking, so a release outside the circle
/// still ends the take. Resolving "accepted" immediately means a second finger
/// cannot start a second session, and a cancel (OS gesture, call, navigation)
/// reaches [onCancel] instead of leaving the microphone open.
class _HoldGestureRecognizer extends OneSequenceGestureRecognizer {
  VoidCallback? onStart;
  VoidCallback? onEnd;
  VoidCallback? onCancel;

  int? _pointer;
  bool _started = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    // A null onStart means starting is disabled (busy session or unsupported
    // language). Do not track a pointer at all: otherwise a release would call
    // onEnd for a take that never started.
    if (onStart == null) return;
    if (_pointer != null) return;
    if (event.buttons & kPrimaryButton == 0) return;
    _pointer = event.pointer;
    _started = true;
    startTrackingPointer(event.pointer);
    resolve(GestureDisposition.accepted);
    onStart?.call();
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerUpEvent) {
      _finish();
      onEnd?.call();
    } else if (event is PointerCancelEvent) {
      _finish();
      onCancel?.call();
    }
  }

  void _finish() {
    final pointer = _pointer;
    _pointer = null;
    _started = false;
    if (pointer != null) stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'hold-to-talk';

  @override
  void dispose() {
    if (_started) onCancel?.call();
    _pointer = null;
    _started = false;
    super.dispose();
  }
}
