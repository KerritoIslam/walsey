import '../domain/voice_intent.dart';

/// Explicit, small, expiring conversation memory for voice follow-ups.
///
/// It answers exactly one question: "which device did the last successful
/// action target, and is that memory still safe to use?". It never stores LED
/// state — the controller protocol has no state read-back, so remembering
/// "the lights are blue" would be a guess.
///
/// Rules:
/// * memory is written only after an action actually ran;
/// * it expires after [staleAfter];
/// * [invalidate] clears it immediately (disconnect, new scan, ambiguity);
/// * a consumer may use it only to *propose* a target; the normal parser,
///   capability checks and executor prerequisites still decide what runs.
final class VoiceConversation {
  VoiceConversation({
    DateTime Function()? clock,
    this.staleAfter = const Duration(minutes: 10),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// How long a remembered target stays usable.
  final Duration staleAfter;

  String? _deviceName;
  VoiceIntent? _lastIntent;
  DateTime? _recordedAt;
  int _turn = 0;

  /// Advertised name of the last successfully targeted device, or `null` when
  /// there is no fresh memory.
  String? get deviceName => _fresh ? _deviceName : null;

  /// Intent of the last successful action, or `null` when the memory is stale.
  VoiceIntent? get lastIntent => _fresh ? _lastIntent : null;

  /// Monotonic counter, so a UI can tell whether a follow-up used memory.
  int get turn => _turn;

  /// Whether a device from a recent action may be reused.
  bool get hasFreshTarget => _fresh && _deviceName != null;

  bool get _fresh {
    final at = _recordedAt;
    if (at == null) return false;
    return _clock().difference(at) <= staleAfter;
  }

  /// Records a completed action. [deviceName] may be `null` when the action
  /// needed no device (for example a refused status inquiry), in which case
  /// the previous target is dropped rather than silently kept.
  void record({
    required VoiceIntent intent,
    String? deviceName,
  }) {
    _deviceName = deviceName;
    _lastIntent = intent;
    _recordedAt = _clock();
    _turn++;
  }

  /// Drops everything. Called on disconnect, a new scan, cancellation and any
  /// ambiguity that makes the old target unsafe.
  void invalidate() {
    _deviceName = null;
    _lastIntent = null;
    _recordedAt = null;
    _turn++;
  }

  @override
  String toString() => 'VoiceConversation(target: $_deviceName, '
      'intent: ${_lastIntent?.name}, fresh: $_fresh)';
}
