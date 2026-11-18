import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/control/led_control_service.dart';
import 'package:walsey/voice/voice_command_executor.dart';
import 'package:walsey_led_core/walsey_led_core.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

final class _FakeTransport implements LedTransport {
  final writes = <Uint8List>[];
  final _notifications = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get notifications => _notifications.stream;

  @override
  Future<void> write(Uint8List frame, {required bool withResponse}) async {
    writes.add(Uint8List.fromList(frame));
  }

  @override
  Future<void> close() => _notifications.close();
}

void main() {
  late _FakeTransport transport;
  late LeddmxDriver driver;
  late LedControlService controls;
  late VoiceCommandExecutor executor;

  setUp(() {
    transport = _FakeTransport();
    driver = LeddmxDriver(
      transport: transport,
      minGap: Duration.zero,
      delay: (_) async {},
    )..attach(resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);
    controls = LedControlService(
      driver: driver,
      layout: LeddmxLayout.filler,
      log: (_) {},
    );
    executor = VoiceCommandExecutor(controls);
  });

  tearDown(() async {
    controls.dispose();
    await driver.dispose();
    await transport.close();
  });

  test('routes supported parsed speech commands to the LED facade', () async {
    final parser = VoiceCommandParser();
    final commands = [
      parser.parse('turn the lights on'),
      parser.parse('turn the lights off'),
      parser.parse('set the color to blue'),
      parser.parse('set brightness to 50 percent'),
      parser.parse('apply effect 1'),
    ];

    for (final result in commands) {
      expect(result, isA<VoiceCommandResult>());
      final outcome = await executor.execute(
        (result as VoiceCommandResult).command,
      );
      expect(outcome.success, isTrue, reason: outcome.message);
    }

    expect(transport.writes, hasLength(5));
  });

  test('does not execute relative brightness without device state', () async {
    final result = VoiceCommandParser().parse('increase brightness');
    final outcome = await executor.execute(
      (result as VoiceCommandResult).command,
    );

    expect(outcome.success, isFalse);
    expect(transport.writes, isEmpty);
  });
}
