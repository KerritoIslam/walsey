import 'dart:typed_data';

/// Per-link write path to a connected, GATT-validated LEDDMX controller.
///
/// Pure abstraction: no BLE plugin, no Flutter. The platform adapter lives in
/// `walsey_led_ble`; tests use a fake.
///
/// The transport owns no protocol knowledge. It writes complete 9-byte frames
/// produced by `leddmx_frames.dart` and exposes the controller's notifications.
/// Handshake timing, pacing and command mapping belong to `LeddmxDriver`.
abstract interface class LedTransport {
  /// Writes one complete frame to characteristic FFE1.
  ///
  /// [withResponse] must reflect the write mode the platform actually used;
  /// the driver records it in the result so logs never overstate what happened.
  Future<void> write(Uint8List frame, {required bool withResponse});

  /// Frames received from the controller (FFE1 notifications).
  ///
  /// The protocol has no state read-back. The only documented reply is the
  /// password-status answer to `2A 05 … AF`; do not treat other traffic as a
  /// command acknowledgement.
  Stream<Uint8List> get notifications;

  /// Releases the link. Safe to call more than once.
  Future<void> close();
}
