import 'dart:typed_data';

import 'package:walsey_led_core/walsey_led_core.dart';

import 'ble_port.dart';
import 'gatt_profile.dart';

/// [LedTransport] implementation over [BleCentral].
///
/// The app's connection layer creates one of these per validated link and
/// passes it to [LeddmxDriver]. Frames are checked to be complete 9-byte
/// LEDDMX envelopes before they reach the platform.
final class PluginLedTransport implements LedTransport {
  PluginLedTransport({
    required BleCentral central,
    required String peripheralId,
    String characteristicUuid = ffe1CharacteristicUuid,
  })  : _central = central,
        _peripheralId = peripheralId,
        _characteristicUuid = characteristicUuid;

  /// LEDDMX frames are always 9 bytes (research.md §4).
  static const int frameLength = 9;

  final BleCentral _central;
  final String _peripheralId;
  final String _characteristicUuid;

  @override
  Future<void> write(Uint8List frame, {required bool withResponse}) async {
    if (frame.length != frameLength) {
      throw LedTransportException(
        'refusing to write a ${frame.length}-byte value: LEDDMX frames are '
        'always $frameLength bytes',
      );
    }
    await _central.writeCharacteristic(
      _peripheralId,
      _characteristicUuid,
      frame,
      withResponse: withResponse,
    );
  }

  /// Enables the FFE1 notification stream (CCCD) on the live link.
  ///
  /// Receive-only: no command frame is sent. Called by the connection layer
  /// after GATT validation so password-status replies can arrive.
  Future<void> enableNotifications() => _central.setNotify(
        _peripheralId,
        _characteristicUuid,
        enabled: true,
      );

  @override
  Stream<Uint8List> get notifications => _central.notifications
      .where((notification) =>
          notification.peripheralId == _peripheralId &&
          uuidMatches(notification.characteristicUuid, _characteristicUuid))
      .map((notification) => notification.value);

  /// Disables notifications and releases the link.
  @override
  Future<void> close() async {
    try {
      await _central.setNotify(
        _peripheralId,
        _characteristicUuid,
        enabled: false,
      );
    } on Object {
      // Disabling notifications may fail if the link is already gone; the
      // disconnect below is what matters.
    }
    await _central.disconnect(_peripheralId);
  }
}
