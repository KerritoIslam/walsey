import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/voice/android_wake_service.dart';

/// The Android foreground service is compile-verified only: these tests exercise
/// the Dart bridge with a mocked channel. No device, service or microphone is
/// involved, and nothing here proves that Android actually keeps the process
/// alive.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidWakeService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'isSupported') return true;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('reports unsupported on a non-Android platform without a channel call',
      () async {
    final bridge = AndroidWakeService(platformSupported: false);
    expect(bridge.isSupportedPlatform, isFalse);
    expect(await bridge.isSupported(), isFalse);
    await expectLater(
      bridge.start(),
      throwsA(isA<AndroidWakeServiceException>()),
    );
    expect(calls, isEmpty);
    await bridge.stop();
    expect(calls, isEmpty);
    await bridge.dispose();
  });

  test('start and stop call the native methods by name', () async {
    final bridge = AndroidWakeService(platformSupported: true);
    expect(await bridge.isSupported(), isTrue);
    await bridge.start();
    await bridge.stop();
    expect(calls.map((call) => call.method), ['isSupported', 'start', 'stop']);
    await bridge.dispose();
  });

  test('a permission failure is surfaced with a clear message', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'permission',
        message: 'Microphone permission is required.',
      );
    });
    final bridge = AndroidWakeService(platformSupported: true);
    await expectLater(
      bridge.start(),
      throwsA(
        isA<AndroidWakeServiceException>().having(
          (error) => error.message,
          'message',
          contains('Microphone permission'),
        ),
      ),
    );
    await bridge.dispose();
  });

  test('a missing plugin is surfaced instead of silently succeeding', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final bridge = AndroidWakeService(platformSupported: true);
    // No mock handler: the platform message falls through to a missing-plugin
    // response in the test binding.
    await expectLater(
      bridge.start(),
      throwsA(isA<AndroidWakeServiceException>()),
    );
    expect(await bridge.isSupported(), isFalse);
    await bridge.dispose();
  });

  test('the notification stop action reaches Dart as a stop request', () async {
    final bridge = AndroidWakeService(platformSupported: true);
    final requests = <void>[];
    final subscription = bridge.stopRequests.listen(requests.add);

    await messenger.handlePlatformMessage(
      AndroidWakeService.channelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onStopRequested'),
      ),
      (_) {},
    );

    expect(requests, hasLength(1));
    await subscription.cancel();
    await bridge.dispose();
  });

  test('dispose stops the service and closes the stream', () async {
    final bridge = AndroidWakeService(platformSupported: true);
    final done = bridge.stopRequests.toList();
    await bridge.dispose();
    expect(calls.map((call) => call.method), contains('stop'));
    await expectLater(done, completes);
  });
}
