import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/control/led_control_service.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

final class FakeTransport implements LedTransport {
  final List<Uint8List> writes = [];
  final StreamController<Uint8List> _notifications =
      StreamController<Uint8List>.broadcast();
  Completer<void>? gate;
  Object? writeError;

  @override
  Future<void> write(Uint8List frame, {required bool withResponse}) async {
    final gate = this.gate;
    if (gate != null) await gate.future;
    final error = writeError;
    if (error != null) throw error;
    writes.add(Uint8List.fromList(frame));
  }

  @override
  Stream<Uint8List> get notifications => _notifications.stream;

  void send(List<int> bytes) =>
      _notifications.add(Uint8List.fromList(bytes));

  @override
  Future<void> close() async {
    await _notifications.close();
  }
}

String hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

void main() {
  late FakeTransport transport;
  late LeddmxDriver driver;
  late List<String> logs;
  late LedControlService controls;

  setUp(() {
    transport = FakeTransport();
    driver = LeddmxDriver(
      transport: transport,
      minGap: Duration.zero,
      delay: (_) async {},
    );
    driver.attach(resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);
    logs = [];
    controls = LedControlService(
      driver: driver,
      layout: LeddmxLayout.filler,
      log: logs.add,
    );
  });

  tearDown(() async {
    controls.dispose();
    await driver.dispose();
    await transport.close();
  });

  test('logs variant, frame hex, mode and BLE result for a power frame',
      () async {
    final result = await controls.setPower(on: false);

    expect(result, isA<CommandSent>());
    expect(hex(transport.writes.single), '7b 04 04 00 ff ff ff ff bf');
    expect(
      logs,
      contains('COMMAND power off | variant=LEDDMX-03-6B4A | '
          'layout=filler | write=withResponse'),
    );
    expect(
      logs.any((line) =>
          line.contains('RESULT power off: BLE WRITE OK') &&
          line.contains('mode=withResponse') &&
          line.contains('frame=7b 04 04 00 ff ff ff ff bf') &&
          line.contains('LED response NOT confirmed')),
      isTrue,
    );
  });

  test('handshake logs redact the password bytes', () async {
    final result = await controls.authenticate(
      now: DateTime(2026, 10, 19, 14, 30),
    );
    expect(result, isA<CommandSent>());
    expect(hex(transport.writes.single), '2a 02 a1 23 45 67 2e 1e af');

    final all = logs.join('\n');
    expect(all, contains('frame=2a 02 ** ** ** ** '));
    expect(all, isNot(contains('a1 23 45 67')));
  });

  test('write failure is logged as failed, never as BLE success', () async {
    transport.writeError = StateError('gatt write failed');

    final result = await controls.setPower(on: true);

    expect(result, isA<CommandFailed>());
    expect(logs.any((line) => line.contains('RESULT power on: FAILED')), isTrue);
    expect(logs.any((line) => line.contains('BLE WRITE OK')), isFalse);
  });

  test('a second command is refused while one is in flight', () async {
    transport.gate = Completer<void>();
    final first = controls.setPower(on: true);
    await Future<void>.delayed(Duration.zero);

    final second = await controls.setPower(on: false);
    expect(second, isA<CommandFailed>());
    expect(
      logs.any((line) => line.contains('COMMAND IGNORED (power off)')),
      isTrue,
    );

    transport.gate!.complete();
    await first;
    expect(transport.writes.length, 1);
  });

  test('password query reports reply status separately from the write',
      () async {
    final pending = controls.checkPasswordStatus();
    await Future<void>.delayed(Duration.zero);
    // Deliver the documented reply through the driver's subscription.
    transport.send(
        [0x2a, 0x05, 0x02, 0xff, 0xff, 0xff, 0xff, 0xff, 0xaf]);

    final outcome = await pending;
    expect(outcome.status, PasswordStatus.allSameDigits);
    expect(
      logs.any((line) =>
          line.contains('PASSWORD REPLY: allSameDigits') &&
          line.contains('only protocol response')),
      isTrue,
    );
  });
}
