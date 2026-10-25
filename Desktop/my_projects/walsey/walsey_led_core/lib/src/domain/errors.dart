/// Thrown when a command or value is outside what the protocol can express.
///
/// Validation happens when a value object is constructed, so an invalid
/// command can never reach the encoder or the transport.
class InvalidCommandException implements Exception {
  InvalidCommandException(this.message);
  final String message;

  @override
  String toString() => 'InvalidCommandException: $message';
}

/// Thrown when a BLE transport operation fails or times out.
///
/// This is deliberately separate from [InvalidCommandException]: a failure here
/// means "the frame could not be delivered", never "the value was invalid".
class LedTransportException implements Exception {
  LedTransportException(this.message, [this.cause]);

  final String message;

  /// Underlying platform error, when one exists.
  final Object? cause;

  @override
  String toString() =>
      'LedTransportException: $message${cause == null ? '' : ' ($cause)'}';
}
