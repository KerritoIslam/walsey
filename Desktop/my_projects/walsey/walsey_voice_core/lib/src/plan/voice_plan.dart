import '../domain/voice_intent.dart';
import '../domain/voice_parameters.dart';
import '../domain/voice_result.dart';

/// Which device a plan step should use.
///
/// Every target is resolved against real scan results at execution time; the
/// plan itself never names a device that was not discovered.
enum VoiceDeviceTarget {
  /// First *supported* LEDDMX device in the current scan results (RSSI order).
  firstAvailable,

  /// Last supported device in the current scan results.
  lastAvailable,

  /// The device that is already connected or was connected last; falls back to
  /// the first supported scan result only when neither exists.
  knownOrFirst,

  /// A device whose advertised name matches [SelectDeviceStep.name].
  named;

  String get label => switch (this) {
        VoiceDeviceTarget.firstAvailable => 'first available device',
        VoiceDeviceTarget.lastAvailable => 'last available device',
        VoiceDeviceTarget.knownOrFirst => 'known device',
        VoiceDeviceTarget.named => 'named device',
      };
}

/// One ordered, typed action in a [VoicePlan].
///
/// Pure data: a step can be described, validated and rendered, but nothing here
/// can execute anything. Execution lives in the host application, which maps
/// each step onto the existing LED services.
sealed class VoicePlanStep {
  const VoicePlanStep();

  /// One-line description used by the UI and diagnostics.
  String get summary;
}

/// Ask the transport to discover nearby BLE peripherals.
final class ScanDevicesStep extends VoicePlanStep {
  const ScanDevicesStep();

  @override
  String get summary => 'Scan for nearby devices';
}

/// Choose one device from the current scan results.
final class SelectDeviceStep extends VoicePlanStep {
  const SelectDeviceStep({required this.target, this.name});

  final VoiceDeviceTarget target;

  /// Only set for [VoiceDeviceTarget.named]; matched against advertised names.
  final String? name;

  @override
  String get summary => target == VoiceDeviceTarget.named
      ? 'Select the device named "$name"'
      : 'Select the ${target.label}';
}

/// Connect to the device chosen by a preceding [SelectDeviceStep].
final class ConnectDeviceStep extends VoicePlanStep {
  const ConnectDeviceStep();

  @override
  String get summary => 'Connect to the selected device';
}

/// Release the current Bluetooth link.
final class DisconnectDeviceStep extends VoicePlanStep {
  const DisconnectDeviceStep();

  @override
  String get summary => 'Disconnect from the current device';
}

/// Reconnect to the device that was connected most recently.
final class ReconnectLastDeviceStep extends VoicePlanStep {
  const ReconnectLastDeviceStep();

  @override
  String get summary => 'Reconnect to the last connected device';
}

/// Turn the controller on or off.
final class SetPowerStep extends VoicePlanStep {
  const SetPowerStep({required this.on});

  final bool on;

  @override
  String get summary => on ? 'Turn the LED on' : 'Turn the LED off';
}

/// Set a named colour from the controlled list.
final class SetColorStep extends VoicePlanStep {
  const SetColorStep(this.color);

  final VoiceColor color;

  @override
  String get summary => 'Set the color to ${color.label}';
}

/// Set an absolute brightness percentage (0..100).
final class SetBrightnessStep extends VoicePlanStep {
  const SetBrightnessStep(this.brightness);

  final VoiceBrightness brightness;

  @override
  String get summary => 'Set brightness to ${brightness.percent}%';
}

/// Apply one documented built-in effect id.
final class ApplyEffectStep extends VoicePlanStep {
  const ApplyEffectStep(this.effect);

  final VoiceEffect effect;

  @override
  String get summary => 'Apply effect ${effect.id}';
}

/// Save the current look as a scene.
///
/// Scenes do not exist in the app yet, so this is deliberately a recognized but
/// not executable step: the executor reports that honestly instead of
/// pretending to save anything.
final class SaveSceneStep extends VoicePlanStep {
  const SaveSceneStep({this.name});

  final String? name;

  @override
  String get summary =>
      name == null ? 'Save the current scene' : 'Save the scene "$name"';
}

/// Ask about the current state.
///
/// The controller protocol has no state read-back, so this step can never
/// report a device state. It exists so a status question is recognized and
/// answered honestly instead of being misread as an action.
final class QueryStatusStep extends VoicePlanStep {
  const QueryStatusStep();

  @override
  String get summary => 'Query the current LED state';
}

/// An ordered sequence of actions derived from one spoken sentence.
final class VoicePlan {
  const VoicePlan({required this.sourceText, required this.steps});

  /// Exactly what the user said, before normalization.
  final String sourceText;

  final List<VoicePlanStep> steps;

  /// One-line descriptions in execution order.
  List<String> get summary => [for (final step in steps) step.summary];

  /// True when a plan needs no BLE work beyond the current connection.
  bool get isSingleLightingStep =>
      steps.length == 1 && steps.single is! ScanDevicesStep &&
      steps.single is! SelectDeviceStep &&
      steps.single is! ConnectDeviceStep &&
      steps.single is! DisconnectDeviceStep &&
      steps.single is! ReconnectLastDeviceStep;
}

/// Outcome of planning one sentence.
sealed class VoicePlanResult {
  const VoicePlanResult({required this.sourceText});

  final String sourceText;
}

/// A validated, ordered plan. Nothing has been executed.
final class VoicePlanReady extends VoicePlanResult {
  const VoicePlanReady({required super.sourceText, required this.plan});

  final VoicePlan plan;
}

/// The sentence could not be turned into a plan. The explanation is
/// user-facing and mirrors the Stage 1 failure taxonomy.
final class VoicePlanFailure extends VoicePlanResult {
  const VoicePlanFailure({
    required super.sourceText,
    required this.kind,
    required this.explanation,
    this.intent,
  });

  final VoiceFailureKind kind;
  final String explanation;

  /// Set when an action was recognized but could not be planned.
  final VoiceIntent? intent;
}
