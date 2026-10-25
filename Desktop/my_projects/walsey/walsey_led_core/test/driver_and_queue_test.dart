import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

import 'test_utils.dart';

/// In-memory transport that records every write and can be held open.
final class FakeTransport implements LedTransport {
  final List<Uint8List> writes = [];
  final List<bool> modes = [];
  final StreamController<Uint8List> _notifications =
      StreamController<Uint8List>.broadcast();

  Object? writeError;
  Duration? writeDelay;
  Completer<void>? gate;
  int concurrentWrites = 0;
  int maxConcurrentWrites = 0;
  bool closed = false;

  @override
  Future<void> write(Uint8List frame, {required bool withResponse}) async {
    concurrentWrites++;
    if (concurrentWrites > maxConcurrentWrites) {
      maxConcurrentWrites = concurrentWrites;
    }
    try {
      if (writeDelay != null) await Future<void>.delayed(writeDelay!);
      if (gate != null) await gate!.future;
      final error = writeError;
      if (error != null) throw error;
      writes.add(Uint8List.fromList(frame));
      modes.add(withResponse);
    } finally {
      concurrentWrites--;
    }
  }

  @override
  Stream<Uint8List> get notifications => _notifications.stream;

  void notify(List<int> bytes) =>
      _notifications.add(Uint8List.fromList(bytes));

  @override
  Future<void> close() async {
    closed = true;
    await _notifications.close();
  }
}

void main() {
  group('WriteQueue serialisation', () {
    test('only one write is in flight at a time, in call order', () async {
      final transport = FakeTransport();
      final queue = WriteQueue(
        transport: transport,
        minGap: Duration.zero,
        delay: (_) async {},
      );

      final firstGate = Completer<void>();
      transport.gate = firstGate;

      final first = queue.write(Uint8List.fromList([1]), withResponse: true);
      final second = queue.write(Uint8List.fromList([2]), withResponse: true);
      final third = queue.write(Uint8List.fromList([3]), withResponse: true);

      await Future<void>.delayed(Duration.zero);
      expect(transport.writes, isEmpty);

      firstGate.complete();
      await Future.wait([first, second, third]);

      expect(transport.writes.map((f) => f.single), [1, 2, 3]);
      expect(transport.maxConcurrentWrites, 1);
    });

    test('waits at least minGap between writes', () async {
      var now = DateTime(2026, 1, 1);
      final delays = <Duration>[];
      final transport = FakeTransport();
      final queue = WriteQueue(
        transport: transport,
        minGap: const Duration(milliseconds: 50),
        clock: () => now,
        delay: (duration) async {
          delays.add(duration);
          now = now.add(duration);
        },
      );

      await queue.write(Uint8List.fromList([1]), withResponse: true);
      await queue.write(Uint8List.fromList([2]), withResponse: true);
      await queue.write(Uint8List.fromList([3]), withResponse: true);

      // The first write has no predecessor; every later write must wait the
      // full gap because the fake clock only advances inside the delay.
      expect(delays, [
        const Duration(milliseconds: 50),
        const Duration(milliseconds: 50),
      ]);
      expect(transport.writes.length, 3);
    });

    test('a failed write is reported and does not block the next one',
        () async {
      final transport = FakeTransport();
      final queue = WriteQueue(
        transport: transport,
        minGap: Duration.zero,
        delay: (_) async {},
      );

      transport.writeError = StateError('gatt error');
      await expectLater(
        queue.write(Uint8List.fromList([1]), withResponse: true),
        throwsA(isA<StateError>()),
      );
      expect(queue.isBlocked, isFalse);

      transport.writeError = null;
      await queue.write(Uint8List.fromList([2]), withResponse: true);
      expect(transport.writes.single.single, 2);
    });

    test('a timeout blocks further writes until reset', () async {
      final transport = FakeTransport()..gate = Completer<void>();
      final queue = WriteQueue(
        transport: transport,
        minGap: Duration.zero,
        writeTimeout: const Duration(milliseconds: 20),
        delay: (_) async {},
      );

      await expectLater(
        queue.write(Uint8List.fromList([1]), withResponse: true),
        throwsA(isA<LedTransportException>()),
      );
      expect(queue.isBlocked, isTrue);

      await expectLater(
        queue.write(Uint8List.fromList([2]), withResponse: true),
        throwsA(isA<LedTransportException>()),
      );
      expect(transport.writes, isEmpty);

      queue.reset();
      transport.gate!.complete();
      await queue.write(Uint8List.fromList([3]), withResponse: true);
      // The abandoned write may still land after its timeout; what matters is
      // that the post-reset frame is written, serially.
      expect(transport.writes.map((frame) => frame.single), contains(3));
    });
  });

  group('LeddmxDriver', () {
    late FakeTransport transport;
    late LeddmxDriver driver;

    setUp(() {
      transport = FakeTransport();
      driver = LeddmxDriver(
        transport: transport,
        minGap: Duration.zero,
        writeTimeout: const Duration(milliseconds: 100),
        delay: (_) async {},
      );
    });

    tearDown(() async {
      await driver.dispose();
      if (!transport.closed) await transport.close();
    });

    test('attaching and detaching send nothing', () async {
      final variant = resolveVariant('LEDDMX-03-6B4A');
      driver.attach(variant as SupportedVariant);
      expect(driver.isAttached, isTrue);
      expect(transport.writes, isEmpty);
      await driver.detach();
      expect(driver.isAttached, isFalse);
      expect(transport.writes, isEmpty);
    });

    test('detached driver refuses commands without writing', () async {
      final result = await driver.setPower(on: false);
      expect(result, isA<CommandFailed>());
      expect(transport.writes, isEmpty);
    });

    test('setPower uses the filler frame and withResponse mode', () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);

      final result = await driver.setPower(on: false);

      expect(hex(transport.writes.single), '7b 04 04 00 ff ff ff ff bf');
      expect(transport.modes.single, isTrue);
      expect(result, isA<CommandSent>());
      final sent = result as CommandSent;
      expect(sent.writeMode, WriteMode.withResponse);
      expect(sent.command, 'power off');
      expect(driver.state.lastCommand, 'power off');
      expect(driver.state.handshakeSent, isFalse);
    });

    test('setColor maps to the filler RGB frame', () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);

      final result = await driver.setColor(RgbColor(0x11, 0x22, 0x33));

      expect(hex(transport.writes.single), '7b ff 07 11 22 33 00 ff bf');
      expect(result, isA<CommandSent>());
    });

    test('setBrightness maps to the filler brightness frame (floor scaling)',
        () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);

      await driver.setBrightness(BrightnessLevel(30));

      expect(hex(transport.writes.single), '7b ff 01 09 1e 00 ff ff bf');
    });

    test('applyEffect maps to the filler effect frame', () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);

      await driver.applyEffect(LedEffect(3));

      expect(hex(transport.writes.single), '7b ff 03 03 ff ff ff ff bf');
    });

    test('a write failure is reported, never recorded as sent', () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);
      transport.writeError = StateError('gatt write failed');

      final result = await driver.setPower(on: true);

      expect(result, isA<CommandFailed>());
      expect(driver.state.lastCommand, isNull);
    });

    test('handshake frame is written but password bytes are redacted in logs',
        () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);

      final result = await driver.authenticate(
        now: DateTime(2026, 10, 19, 14, 30),
      );

      expect(hex(transport.writes.single), '2a 02 a1 23 45 67 2e 1e af');
      expect(result, isA<CommandSent>());
      expect((result as CommandSent).hex, '2a 02 ** ** ** ** 2e 1e af');
      expect(driver.state.lastFrameHex, '2a 02 ** ** ** ** 2e 1e af');
      expect(driver.state.handshakeSent, isTrue);
      expect(driver.state.lastCommand, 'handshake');
    });

    test('password query reply updates state and is returned', () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);

      final pending = driver.checkPasswordStatus(
        replyTimeout: const Duration(seconds: 1),
      );
      transport.notify([0x2a, 0x05, 0x03, 0xff, 0xff, 0xff, 0xff, 0xff, 0xaf]);

      final outcome = await pending;

      expect(outcome.write, isA<CommandSent>());
      expect(outcome.status, PasswordStatus.resendRequested);
      expect(transport.writes.single.first, 0x2a);
      expect(hex(transport.writes.single),
          '2a 05 ff ff ff ff ff ff af');
      expect(driver.state.lastPasswordStatus, PasswordStatus.resendRequested);
      expect(driver.state.lastNotificationHex,
          '2a 05 03 ff ff ff ff ff af');
    });

    test('absent password reply is reported as no reply, not success',
        () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);

      final outcome = await driver.checkPasswordStatus(
        replyTimeout: const Duration(milliseconds: 20),
      );

      expect(outcome.write, isA<CommandSent>());
      expect(outcome.status, isNull);
      expect(outcome.replied, isFalse);
    });

    test('timed-out write fails and blocks until reattach', () async {
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);
      transport.gate = Completer<void>();

      final first = await driver.setPower(on: true);
      expect(first, isA<CommandFailed>());

      final second = await driver.setPower(on: false);
      expect(second, isA<CommandFailed>());
      expect(transport.writes, isEmpty);

      // Reattaching (what the app does after reconnect) clears the block.
      await driver.detach();
      driver.attach(
          resolveVariant('LEDDMX-03-6B4A') as SupportedVariant);
      transport.gate!.complete();
      transport.gate = null;
      final third = await driver.setPower(on: false);
      expect(third, isA<CommandSent>());
      // The abandoned write may land late; the newest frame must be power off.
      expect(hex(transport.writes.last), '7b 04 04 00 ff ff ff ff bf');
    });
  });

  group('password status parsing', () {
    test('recognises the three documented statuses', () {
      Uint8List frame(int status) => Uint8List.fromList(
          [0x2a, 0x05, status, 0xff, 0xff, 0xff, 0xff, 0xff, 0xaf]);

      expect(parsePasswordStatus(frame(1)), PasswordStatus.wrongPassword);
      expect(parsePasswordStatus(frame(2)), PasswordStatus.allSameDigits);
      expect(parsePasswordStatus(frame(3)), PasswordStatus.resendRequested);
    });

    test('non password frames return null', () {
      expect(
        parsePasswordStatus(
            Uint8List.fromList([0x7b, 0xff, 0x01, 0x09, 0x1e, 0, 0xff, 0xff, 0xbf])),
        isNull,
      );
    });

    test('undocumented status maps to unknown', () {
      expect(
        parsePasswordStatus(
            Uint8List.fromList([0x2a, 0x05, 0x07, 0xff, 0xff, 0xff, 0xff, 0xff, 0xaf])),
        PasswordStatus.unknown,
      );
    });
  });
}
