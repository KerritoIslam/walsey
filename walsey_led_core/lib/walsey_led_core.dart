/// Pure Dart core for Walsey LED control.
///
/// Stage 1: domain + frame encoding.
/// Stage 2: transport port, serialised write queue and the typed LEDDMX driver.
/// No Flutter, no BLE plugin.
library;

export 'src/controller/leddmx_driver.dart';
export 'src/domain/capabilities.dart';
export 'src/domain/errors.dart';
export 'src/domain/led_command.dart';
export 'src/domain/values.dart';
export 'src/protocol/leddmx_frames.dart';
export 'src/protocol/leddmx_variant.dart';
export 'src/queue/write_queue.dart';
export 'src/transport/led_transport.dart';
