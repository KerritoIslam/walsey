/// Thrown when a voice parameter cannot be represented after validation.
///
/// The parser turns this into an explicit `VoiceFailure`; it is never swallowed
/// and never replaced by a silently clamped value.
final class VoiceParameterException implements Exception {
  const VoiceParameterException(this.message);

  final String message;

  @override
  String toString() => 'VoiceParameterException: $message';
}
