import 'dart:typed_data';

/// Reassembles arbitrary byte chunks into complete little-endian PCM16
/// samples. Recorders are allowed to split a sample across stream events.
final class Pcm16Assembler {
  int? _pendingByte;

  /// Adds a chunk and returns only complete samples.
  Uint8List add(Uint8List chunk) {
    if (chunk.isEmpty && _pendingByte == null) {
      return Uint8List(0);
    }
    final extra = _pendingByte == null ? 0 : 1;
    final combined = Uint8List(extra + chunk.length);
    if (_pendingByte case final pending?) {
      combined[0] = pending;
    }
    combined.setRange(extra, combined.length, chunk);
    final usable = combined.length - (combined.length % 2);
    if (usable != combined.length) {
      _pendingByte = combined.last;
    } else {
      _pendingByte = null;
    }
    return Uint8List.sublistView(combined, 0, usable);
  }

  /// Completes the stream, rejecting a truncated final sample.
  void finish() {
    if (_pendingByte != null) {
      _pendingByte = null;
      throw const FormatException(
        'audio stream ended with an incomplete PCM16 sample',
      );
    }
  }
}
