import 'package:walsey_led_ble/walsey_led_ble.dart';

import '../connection/led_connection_service.dart';
import '../design/widgets.dart';

String deviceLabel(ScannedPeripheral? device) =>
    device?.name ?? device?.id ?? 'LED controller';

/// Short phase label used in badges. Labels describe the app's knowledge, not
/// assumed hardware state.
String connectionPhaseLabel(AppConnectionState state) => switch (state.phase) {
  AppConnectionPhase.disconnected => 'Offline',
  AppConnectionPhase.scanning => 'Scanning',
  AppConnectionPhase.connecting => 'Connecting',
  AppConnectionPhase.discovering => 'Validating',
  AppConnectionPhase.connected =>
    state.controlsAvailable ? 'Online' : 'Connected',
  AppConnectionPhase.disconnecting => 'Disconnecting',
  AppConnectionPhase.failed => 'Unavailable',
};

WBadgeTone connectionTone(AppConnectionState state) => switch (state.phase) {
  AppConnectionPhase.connected =>
    state.controlsAvailable ? WBadgeTone.online : WBadgeTone.connecting,
  AppConnectionPhase.scanning ||
  AppConnectionPhase.connecting ||
  AppConnectionPhase.discovering ||
  AppConnectionPhase.disconnecting => WBadgeTone.connecting,
  AppConnectionPhase.failed => WBadgeTone.error,
  AppConnectionPhase.disconnected => WBadgeTone.offline,
};

/// Long-form status text. Kept deliberately explicit about what "connected"
/// does and does not mean.
String connectionDetail(AppConnectionState state) {
  final name = deviceLabel(state.selected);
  return switch (state.phase) {
    AppConnectionPhase.disconnected =>
      state.adapterState == BleAdapterState.poweredOn
          ? 'Disconnected. Bluetooth adapter is on.'
          : 'Disconnected. Adapter state: ${state.adapterState.name}.',
    AppConnectionPhase.scanning => 'Scanning for LED devices…',
    AppConnectionPhase.connecting => 'Connecting to $name…',
    AppConnectionPhase.discovering =>
      'Discovering GATT and validating FFE0/FFE1…',
    AppConnectionPhase.connected => state.controlsAvailable
        ? 'Link open to ${state.variant?.advertisedName ?? name}. '
              'Commands are available; the protocol has no state read-back, '
              'so Walsey never claims the LEDs changed.'
        : 'Connected to $name. Controls are disabled: '
              '${state.controlsBlockedReason ?? 'transport not usable'}.',
    AppConnectionPhase.disconnecting => 'Disconnecting…',
    AppConnectionPhase.failed => state.error ?? 'Connection failed.',
  };
}

String formatShortDate(DateTime date) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${weekdays[date.weekday - 1]}, ${date.day} ${months[date.month - 1]}';
}
