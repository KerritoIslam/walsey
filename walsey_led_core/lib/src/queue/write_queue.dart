import 'dart:async';
import 'dart:typed_data';

import '../domain/errors.dart';
import '../transport/led_transport.dart';

/// Serialises frames onto [LedTransport].
///
/// Guarantees:
/// - at most one write is in flight at any time;
/// - consecutive writes are separated by at least [minGap] (measured from the
///   completion of the previous write), matching the family's documented
///   50 ms pacing without *dropping* frames;
/// - every write has a [writeTimeout];
/// - a failed or timed-out write is reported to its caller — never swallowed.
///
/// If a write times out, the underlying platform call may still be running and
/// cannot be cancelled. To rule out overlapping writes the queue blocks until
/// [reset] is called; reconnect in that case rather than sending more frames.
final class WriteQueue {
  WriteQueue({
    required LedTransport transport,
    this.minGap = const Duration(milliseconds: 50),
    this.writeTimeout = const Duration(seconds: 5),
    Future<void> Function(Duration) delay = _defaultDelay,
    DateTime Function() clock = DateTime.now,
  })  : _transport = transport,
        _delay = delay,
        _clock = clock;

  final LedTransport _transport;

  /// Minimum gap between the end of one write and the start of the next.
  final Duration minGap;

  /// Per-write timeout.
  final Duration writeTimeout;

  final Future<void> Function(Duration) _delay;
  final DateTime Function() _clock;

  Future<void> _tail = Future<void>.value();
  DateTime? _lastFinished;
  bool _blockedAfterTimeout = false;

  /// True after a timed-out write; cleared by [reset].
  bool get isBlocked => _blockedAfterTimeout;

  /// Clears the timeout block and pacing history. Call after the link has been
  /// re-established (or when attaching a fresh transport).
  void reset() {
    _blockedAfterTimeout = false;
    _lastFinished = null;
  }

  /// Queues [frame] behind every earlier write.
  Future<void> write(Uint8List frame, {required bool withResponse}) {
    if (_blockedAfterTimeout) {
      return Future<void>.error(
        LedTransportException(
          'write refused: a previous write timed out; the link must be '
          're-established before more frames are sent',
        ),
      );
    }

    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      if (_blockedAfterTimeout) {
        completer.completeError(
          LedTransportException(
            'write refused: a previous write timed out; the link must be '
            're-established before more frames are sent',
          ),
        );
        return;
      }

      final last = _lastFinished;
      if (last != null) {
        final elapsed = _clock().difference(last);
        final remaining = minGap - elapsed;
        if (remaining > Duration.zero) {
          await _delay(remaining);
        }
      }

      try {
        await _transport
            .write(frame, withResponse: withResponse)
            .timeout(writeTimeout);
        completer.complete();
      } on TimeoutException catch (error) {
        _blockedAfterTimeout = true;
        completer.completeError(
          LedTransportException(
            'write timed out after ${writeTimeout.inMilliseconds} ms; '
            'further writes are blocked until reconnect',
            error,
          ),
        );
      } catch (error) {
        completer.completeError(error);
      } finally {
        _lastFinished = _clock();
      }
    });

    // `_tail` is kept error-free by the internal try/catch: the error belongs
    // to `completer`, not to the queue chain.
    return completer.future;
  }

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);
}
