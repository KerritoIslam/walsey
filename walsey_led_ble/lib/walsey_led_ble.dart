/// Stage 2 BLE transport for Walsey LED controllers.
///
/// Pure-interface port ([BleCentral]) + `bluetooth_low_energy` adapter + a
/// [LedTransport] bridge for the pure core. Protocol encoding lives only in
/// `walsey_led_core`.
library;

export 'src/ble_port.dart';
export 'src/gatt_profile.dart';
export 'src/plugin_central.dart';
export 'src/plugin_led_transport.dart';
