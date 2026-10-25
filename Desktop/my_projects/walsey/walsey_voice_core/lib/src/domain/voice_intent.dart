/// The closed set of actions the voice layer can currently express.
///
/// `intent.name` is the stable action identifier returned to the UI and used
/// by the command registry. Adding an action is a deliberate source change:
/// the parser, the registry and (in a later stage) the executor must all know
/// about it, so an arbitrary string can never become an executable action.
enum VoiceIntent {
  powerOn,
  powerOff,
  setColor,
  setBrightness,
  increaseBrightness,
  decreaseBrightness,
  applyEffect,
}

extension VoiceIntentLabel on VoiceIntent {
  /// Human-readable action name for the Stage 1 interpretation panel.
  String get label => switch (this) {
        VoiceIntent.powerOn => 'Power on',
        VoiceIntent.powerOff => 'Power off',
        VoiceIntent.setColor => 'Set color',
        VoiceIntent.setBrightness => 'Set brightness',
        VoiceIntent.increaseBrightness => 'Increase brightness',
        VoiceIntent.decreaseBrightness => 'Decrease brightness',
        VoiceIntent.applyEffect => 'Apply effect',
      };
}
