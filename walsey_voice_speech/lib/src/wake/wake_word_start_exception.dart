/// Thrown when a wake detector's `start()` is called before `prepare()` reports
/// a ready capability.
///
/// Starting is an explicit user action, so a failure is surfaced instead of
/// being turned into a silent "maybe listening" state.
final class WakeWordStartException implements Exception {
  const WakeWordStartException(this.message);

  final String message;

  @override
  String toString() => 'WakeWordStartException: $message';
}
