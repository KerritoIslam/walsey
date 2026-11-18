import 'package:flutter_test/flutter_test.dart';
import 'package:walsey/connection/led_connection_service.dart';
import 'package:walsey/voice/voice_plan_executor.dart';
import 'package:walsey_led_ble/walsey_led_ble.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import 'fakes.dart';

void main() {
  late FakeCentral central;
  late LedConnectionService service;
  late VoicePlanExecutor executor;
  late List<String> logs;

  void build({List<GattServiceSnapshot>? gatt}) {
    central = FakeCentral(gatt: gatt ?? const [leddmxGatt]);
    logs = <String>[];
    service = LedConnectionService(
      central: central,
      connectionTimeout: const Duration(seconds: 1),
      discoveryTimeout: const Duration(seconds: 1),
      disconnectTimeout: const Duration(seconds: 1),
      onLog: logs.add,
    );
    executor = VoicePlanExecutor(
      service: service,
      scanTimeout: const Duration(milliseconds: 200),
      connectTimeout: const Duration(seconds: 2),
      disconnectTimeout: const Duration(seconds: 2),
    );
  }

  setUp(build);
  tearDown(() async => service.dispose());

  VoicePlan plan(List<VoicePlanStep> steps) =>
      VoicePlan(sourceText: 'test', steps: steps);

  /// Starts the plan, lets the scan begin, then emits the given devices.
  Future<VoicePlanExecution> runWithDevices(
    VoicePlan plan,
    List<ScannedPeripheral> devices,
  ) {
    final future = executor.execute(plan);
    return Future<void>.delayed(Duration.zero, () async {
      for (final device in devices) {
        central.emitDevice(device);
      }
    }).then((_) => future);
  }

  test('scan, select the first supported device, connect, turn on', () async {
    final result = await runWithDevices(
      plan(const [
        ScanDevicesStep(),
        SelectDeviceStep(target: VoiceDeviceTarget.firstAvailable),
        ConnectDeviceStep(),
        SetPowerStep(on: true),
      ]),
      const [unsupportedDevice, supportedDevice],
    );

    expect(result.success, isTrue, reason: result.message);
    expect(result.steps[0].status, VoicePlanStepStatus.done);
    expect(result.steps[1].status, VoicePlanStepStatus.done);
    expect(result.steps[2].status, VoicePlanStepStatus.done);
    expect(result.steps[3].status, VoicePlanStepStatus.done);
    expect(result.steps[2].detail, contains('LEDDMX-03-6B4A'));
    expect(central.connectCalls, 1);
    expect(central.writes, hasLength(1));
    expect(result.message, contains('not confirmed'));
  });

  test('no compatible device reports honestly and never connects', () async {
    final result = await runWithDevices(
      plan(const [
        ScanDevicesStep(),
        SelectDeviceStep(target: VoiceDeviceTarget.firstAvailable),
        ConnectDeviceStep(),
        SetPowerStep(on: true),
      ]),
      const [unsupportedDevice],
    );

    expect(result.success, isFalse);
    expect(result.message, contains('No compatible LEDDMX device'));
    expect(central.connectCalls, 0);
    expect(central.writes, isEmpty);
    // The scan itself is the step that fails: it never found a usable device.
    expect(result.steps[0].status, VoicePlanStepStatus.failed);
    expect(result.steps[1].status, VoicePlanStepStatus.pending);
    expect(result.steps[2].status, VoicePlanStepStatus.pending);
    expect(result.steps[3].status, VoicePlanStepStatus.pending);
  });

  test('connection failure stops dependent actions', () async {
    await service.dispose();
    build(gatt: const [gattWithoutFfe1]);

    final result = await runWithDevices(
      plan(const [
        ScanDevicesStep(),
        SelectDeviceStep(target: VoiceDeviceTarget.firstAvailable),
        ConnectDeviceStep(),
        SetPowerStep(on: true),
      ]),
      const [supportedDevice],
    );

    expect(result.success, isFalse);
    expect(result.steps[2].status, VoicePlanStepStatus.failed);
    expect(result.steps[3].status, VoicePlanStepStatus.pending);
    expect(central.writes, isEmpty);
  });

  test('named selection ignores an unrelated peripheral', () async {
    final result = await runWithDevices(
      plan(const [
        ScanDevicesStep(),
        SelectDeviceStep(
          target: VoiceDeviceTarget.named,
          name: 'leddmx 03 6b4a',
        ),
        ConnectDeviceStep(),
        SetPowerStep(on: false),
      ]),
      const [unsupportedDevice, supportedDevice],
    );

    expect(result.success, isTrue, reason: result.message);
    expect(central.connectCalls, 1);
    expect(central.writes, hasLength(1));
  });

  test('unknown name is refused without inventing a device', () async {
    final result = await runWithDevices(
      plan(const [
        ScanDevicesStep(),
        SelectDeviceStep(
          target: VoiceDeviceTarget.named,
          name: 'not here',
        ),
        ConnectDeviceStep(),
      ]),
      const [supportedDevice],
    );

    expect(result.success, isFalse);
    expect(result.message, contains('No discovered device matches'));
    expect(central.connectCalls, 0);
  });

  test('link loss during the plan stops the remaining steps', () async {
    await service.connect(supportedDevice);
    late VoicePlanExecutor watched;
    watched = VoicePlanExecutor(
      service: service,
      scanTimeout: const Duration(milliseconds: 200),
      connectTimeout: const Duration(seconds: 2),
      onProgress: (steps) {
        if (steps.length > 1 &&
            steps[0].status == VoicePlanStepStatus.done &&
            steps[1].status == VoicePlanStepStatus.pending) {
          central.emitConnection(
            const BleConnectionEvent(
              peripheralId: 'peripheral-1',
              connected: false,
            ),
          );
        }
      },
    );

    final result = await watched.execute(
      plan(const [SetPowerStep(on: true), SetColorStep(VoiceColor.blue)]),
    ).timeout(const Duration(seconds: 5));

    expect(result.success, isFalse);
    expect(result.steps[0].status, VoicePlanStepStatus.done);
    expect(result.steps[1].status, VoicePlanStepStatus.failed);
    expect(result.message, contains('no longer connected'));
    expect(central.writes, hasLength(1));
  });

  test('scene step is recognized but reports that scenes do not exist',
      () async {
    final result = await executor.execute(
      plan(const [SaveSceneStep()]),
    );

    expect(result.success, isFalse);
    expect(result.message, contains('Scenes are not implemented'));
    expect(central.writes, isEmpty);
  });

  test('scan is skipped when the link is already connected', () async {
    await service.connect(supportedDevice);
    final result = await executor.execute(plan(const [ScanDevicesStep()]));

    expect(result.success, isTrue);
    expect(result.steps.single.status, VoicePlanStepStatus.skipped);
    expect(result.steps.single.detail, contains('Already connected'));
  });

  test('disconnect without a link is reported, not faked', () async {
    final result = await executor.execute(plan(const [DisconnectDeviceStep()]));

    expect(result.success, isTrue);
    expect(result.steps.single.status, VoicePlanStepStatus.skipped);
    expect(result.message, contains('Plan completed'));
  });

  test('a status query writes nothing and reports that honestly', () async {
    final result = await executor.execute(plan(const [QueryStatusStep()]));

    expect(result.success, isTrue);
    expect(result.wroteNothing, isTrue);
    expect(result.steps.single.status, VoicePlanStepStatus.skipped);
    expect(result.message, contains('Nothing was sent'));
    expect(
      result.message,
      contains('cannot report its current state'),
      reason: 'the answer must name the protocol limit',
    );
    expect(central.writes, isEmpty);
  });

  test('a plan that wrote a frame is not reported as write-free', () async {
    await service.connect(supportedDevice);
    final result = await executor.execute(plan(const [SetPowerStep(on: true)]));

    expect(result.success, isTrue);
    expect(result.wroteNothing, isFalse);
    expect(central.writes, hasLength(1));
  });

  test('reconnect uses the last connected device, not a scan', () async {
    await service.connect(supportedDevice);
    await service.disconnect();
    expect(service.current.isConnected, isFalse);

    final result = await executor.execute(
      plan(const [ReconnectLastDeviceStep(), SetPowerStep(on: true)]),
    );

    expect(result.success, isTrue, reason: result.message);
    expect(result.steps[0].status, VoicePlanStepStatus.done);
    expect(result.steps[0].detail, contains('LEDDMX-03-6B4A'));
    expect(central.connectCalls, 2);
    expect(central.startDiscoveryCalls, 0);
    expect(central.writes, hasLength(1));
  });

  test('reconnect without a known device fails honestly', () async {
    final result = await executor.execute(
      plan(const [ReconnectLastDeviceStep()]),
    );

    expect(result.success, isFalse);
    expect(result.message, contains('nothing to reconnect to'));
    expect(central.connectCalls, 0);
  });

  test('cancellation stops before the next step', () async {
    final resultFuture = executor.execute(
      plan(const [SetPowerStep(on: true), SetColorStep(VoiceColor.blue)]),
    );
    executor.cancel();
    final result = await resultFuture;

    expect(result.success, isFalse);
    expect(result.message, contains('cancelled'));
  });

  test('logs every step and never turns a write into a device confirmation',
      () async {
    final result = await runWithDevices(
      plan(const [
        ScanDevicesStep(),
        SelectDeviceStep(target: VoiceDeviceTarget.firstAvailable),
        ConnectDeviceStep(),
        SetPowerStep(on: true),
      ]),
      const [supportedDevice],
    );

    expect(result.success, isTrue, reason: result.message);
    expect(
      logs.any((line) => line.contains('PLAN START: 4 steps')),
      isTrue,
      reason: logs.join('\n'),
    );
    for (var step = 1; step <= 4; step++) {
      expect(
        logs.any(
          (line) =>
              line.contains('PLAN STEP $step/4') &&
              line.contains('started'),
        ),
        isTrue,
        reason: 'step $step started line missing:\n${logs.join('\n')}',
      );
    }
    expect(
      logs.any(
        (line) => line.contains('PLAN STEP 4/4') && line.contains('done'),
      ),
      isTrue,
    );
    // Write-level evidence exists, but the LED reaction is explicitly unknown.
    expect(
      logs.any(
        (line) =>
            line.contains('BLE WRITE OK') &&
            line.contains('LED response NOT confirmed'),
      ),
      isTrue,
      reason: logs.join('\n'),
    );
    expect(
      logs.any((line) => line.contains('HARDWARE RESPONSE')),
      isFalse,
    );
  });
}
