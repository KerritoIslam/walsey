import 'dart:async';

import 'package:walsey_led_ble/walsey_led_ble.dart';
import 'package:walsey_led_core/walsey_led_core.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

import '../connection/led_connection_service.dart';

/// Status of one step in a running plan.
enum VoicePlanStepStatus { pending, running, done, skipped, failed }

/// Immutable progress snapshot for one step.
final class VoicePlanStepProgress {
  const VoicePlanStepProgress({
    required this.index,
    required this.label,
    required this.status,
    this.detail,
  });

  final int index;
  final String label;
  final VoicePlanStepStatus status;

  /// What actually happened, from the service result. `null` while pending.
  final String? detail;

  VoicePlanStepProgress copyWith({
    VoicePlanStepStatus? status,
    String? detail,
  }) =>
      VoicePlanStepProgress(
        index: index,
        label: label,
        status: status ?? this.status,
        detail: detail ?? this.detail,
      );
}

/// Final result of executing a plan.
final class VoicePlanExecution {
  const VoicePlanExecution({
    required this.success,
    required this.message,
    required this.steps,
    this.wroteNothing = false,
  });

  final bool success;

  /// User-facing summary. Never claims device state the services cannot prove.
  final String message;

  final List<VoicePlanStepProgress> steps;

  /// True when the plan finished without writing a single BLE frame — a status
  /// answer, a scan-only plan or a connect-only plan.
  ///
  /// The controller uses this to avoid labelling such a run "Executed": no LED
  /// command reached the controller, so nothing can have changed.
  final bool wroteNothing;
}

/// Port between a validated [VoicePlan] and the real BLE services.
///
/// Implementations execute strictly in order and report per-step outcomes;
/// they never invent a device, a step result or a confirmed LED state.
abstract interface class CommandExecutor {
  /// Called with an immutable snapshot after every step status change.
  void Function(List<VoicePlanStepProgress> steps)? onProgress;

  Future<VoicePlanExecution> execute(VoicePlan plan);

  /// Stops between steps; the in-flight step is allowed to finish.
  void cancel();
}

/// Executes a [VoicePlan] step by step over the real connection and command
/// services.
///
/// Rules:
/// * steps run strictly in order; a dependent step never starts in parallel;
/// * each step is validated and its prerequisites re-checked immediately before
///   it runs, so a link that dropped mid-plan stops the rest;
/// * the first failed step stops the plan and is reported as failed;
/// * device selection only ever uses real scan results, and a supported
///   `LEDDMX-NN` variant is required before any command is attempted;
/// * a successful BLE write is reported as a write, never as a confirmed LED
///   change.
final class VoicePlanExecutor implements CommandExecutor {
  VoicePlanExecutor({
    required this.service,
    this.scanTimeout = const Duration(seconds: 10),
    this.connectTimeout = const Duration(seconds: 50),
    this.disconnectTimeout = const Duration(seconds: 15),
    this.onProgress,
  });

  final LedConnectionService service;

  /// How long a scan may run before it is declared empty.
  final Duration scanTimeout;

  /// Upper bound for connect + GATT discovery.
  final Duration connectTimeout;

  final Duration disconnectTimeout;

  /// Called with a fresh immutable list after every status change.
  @override
  void Function(List<VoicePlanStepProgress> steps)? onProgress;

  ScannedPeripheral? _selected;
  bool _cancelled = false;

  /// Stops the plan between steps. The in-flight step still finishes.
  @override
  void cancel() => _cancelled = true;

  @override
  Future<VoicePlanExecution> execute(VoicePlan plan) async {
    _cancelled = false;
    _selected = null;
    final progress = [
      for (var i = 0; i < plan.steps.length; i++)
        VoicePlanStepProgress(
          index: i,
          label: plan.steps[i].summary,
          status: VoicePlanStepStatus.pending,
        ),
    ];
    _emit(progress);
    service.log(
      'PLAN START: ${plan.steps.length} '
      'step${plan.steps.length == 1 ? '' : 's'} — '
      '${plan.summary.join(' → ')}',
    );

    for (var i = 0; i < plan.steps.length; i++) {
      // Let service events (link loss, discovery) settle before the next step
      // checks its prerequisites.
      await Future<void>.delayed(Duration.zero);
      if (_cancelled) {
        service.log('PLAN CANCELLED: stopped before step ${i + 1}');
        return _finish(
          progress,
          success: false,
          message: 'The plan was cancelled before step ${i + 1}.',
        );
      }
      progress[i] = progress[i].copyWith(
        status: VoicePlanStepStatus.running,
      );
      service.log(
        'PLAN STEP ${i + 1}/${plan.steps.length} '
        '"${progress[i].label}": started',
      );
      _emit(progress);

      _StepOutcome outcome;
      try {
        outcome = await _runStep(plan.steps[i]);
      } on Object catch (error) {
        outcome = _StepOutcome.failed('Unexpected failure: $error');
      }

      progress[i] = progress[i].copyWith(
        status: outcome.status,
        detail: outcome.detail,
      );
      service.log(
        'PLAN STEP ${i + 1}/${plan.steps.length}: '
        '${outcome.status.name}${outcome.detail == null ? '' : ' — ${outcome.detail}'}',
      );
      _emit(progress);

      if (outcome.status == VoicePlanStepStatus.failed) {
        return _finish(
          progress,
          success: false,
          message: outcome.detail ??
              'The plan stopped at step ${i + 1}; nothing after it ran.',
        );
      }
    }

    return _finish(
      progress,
      success: true,
      message: _successMessage(progress),
      wroteNothing: !_wroteAnything(progress),
    );
  }

  // --------------------------------------------------------------------------
  // Steps
  // --------------------------------------------------------------------------

  Future<_StepOutcome> _runStep(VoicePlanStep step) async {
    switch (step) {
      case ScanDevicesStep():
        return _scan();
      case SelectDeviceStep():
        return _select(step);
      case ConnectDeviceStep():
        return _connectSelected();
      case ReconnectLastDeviceStep():
        return _reconnectLast();
      case DisconnectDeviceStep():
        return _disconnect();
      case SetPowerStep():
        return _command(() => service.controls!.setPower(on: step.on));
      case SetColorStep():
        return _command(
          () => service.controls!.setColor(
            RgbColor(step.color.r, step.color.g, step.color.b),
          ),
        );
      case SetBrightnessStep():
        return _command(
          () => service.controls!.setBrightness(
            BrightnessLevel(step.brightness.percent),
          ),
        );
      case ApplyEffectStep():
        return _command(
          () => service.controls!.applyEffect(LedEffect(step.effect.id)),
        );
      case SaveSceneStep():
        return const _StepOutcome.failed(
          'Scenes are not implemented in this app yet, so nothing was saved.',
        );
      case QueryStatusStep():
        return const _StepOutcome.skipped(
          'The controller protocol has no state read-back, so the current LED '
          'state is unknown. Nothing was sent.',
        );
    }
  }

  Future<_StepOutcome> _scan() async {
    final current = service.current;
    if (current.isConnected) {
      return _StepOutcome.skipped(
        'Already connected to ${_deviceLabel(current.selected)}; no scan was '
        'needed.',
      );
    }
    if (current.isScanning) {
      // A scan started outside the plan is reused, never restarted.
      final found = await _waitForSupportedDevice(scanTimeout);
      if (found == null) {
        await service.stopScan();
        return _noDevice(
          'No compatible LEDDMX device was found in the ${scanTimeout.inSeconds}s '
          'scan window.',
        );
      }
      await service.stopScan();
      return _StepOutcome.done('Discovered ${_deviceLabel(found)}.');
    }

    await service.startScan();
    final failure = service.current.phase == AppConnectionPhase.failed
        ? service.current.error
        : null;
    if (failure != null) {
      return _StepOutcome.failed(failure);
    }
    final found = await _waitForSupportedDevice(scanTimeout);
    if (found == null) {
      await service.stopScan();
      final error = service.current.error;
      return _noDevice(
        error ??
            'No compatible LEDDMX device was found in the '
                '${scanTimeout.inSeconds}s scan window.',
      );
    }
    // Stop discovery as soon as a usable device exists: the following select /
    // connect steps use the published results, and a failed plan must not leave
    // the radio scanning in the background.
    await service.stopScan();
    return _StepOutcome.done('Discovered ${_deviceLabel(found)}.');
  }

  Future<_StepOutcome> _select(SelectDeviceStep step) async {
    final current = service.current;
    if (current.isConnected) {
      _selected = current.selected;
      return _StepOutcome.skipped(
        'Already connected to ${_deviceLabel(current.selected)}; keeping the '
        'current link.',
      );
    }

    final supported = [
      for (final device in current.devices)
        if (_isSupported(device)) device,
    ];
    switch (step.target) {
      case VoiceDeviceTarget.firstAvailable:
        if (supported.isEmpty) return _noDevice(_noResultsMessage);
        _selected = supported.first;
      case VoiceDeviceTarget.lastAvailable:
        if (supported.isEmpty) return _noDevice(_noResultsMessage);
        _selected = supported.last;
      case VoiceDeviceTarget.named:
        final wanted = _compact(step.name ?? '');
        final matches = [
          for (final device in supported)
            if (_compact(device.name ?? '') == wanted) device,
        ];
        if (matches.isEmpty) {
          return _StepOutcome.failed(
            'No discovered device matches "${step.name}". Nothing was '
            'connected.',
          );
        }
        _selected = matches.first;
      case VoiceDeviceTarget.knownOrFirst:
        final last = _selected ?? service.lastConnectedDevice;
        if (last != null && _isSupported(last)) {
          _selected = last;
        } else if (supported.isNotEmpty) {
          _selected = supported.first;
        } else {
          return const _StepOutcome.failed(
            'No device is connected and no previous device is known. Ask '
            'Walsey to scan for devices first.',
          );
        }
    }
    return _StepOutcome.done('Selected ${_deviceLabel(_selected)}.');
  }

  Future<_StepOutcome> _connectSelected() async {
    final current = service.current;
    if (current.isConnected) {
      return _StepOutcome.skipped(
        'Already connected to ${_deviceLabel(current.selected)}.',
      );
    }
    final device = _selected ?? _firstSupported() ?? service.lastConnectedDevice;
    if (device == null) return _noDevice(_noResultsMessage);
    if (!_isSupported(device)) {
      return _StepOutcome.failed(
        '"${_deviceLabel(device)}" is not a documented LEDDMX variant, so no '
        'command format is implemented for it. Nothing was connected.',
      );
    }
    return _connectTo(device);
  }

  Future<_StepOutcome> _reconnectLast() async {
    if (service.current.isConnected) {
      return _StepOutcome.skipped(
        'Already connected to ${_deviceLabel(service.current.selected)}.',
      );
    }
    final device = service.lastConnectedDevice;
    if (device == null) {
      return const _StepOutcome.failed(
        'No device has been connected in this session yet, so there is '
        'nothing to reconnect to. Ask Walsey to scan first.',
      );
    }
    if (!_isSupported(device)) {
      return _StepOutcome.failed(
        '"${_deviceLabel(device)}" is not a documented LEDDMX variant, so it '
        'cannot be reconnected for commands.',
      );
    }
    return _connectTo(device);
  }

  Future<_StepOutcome> _connectTo(ScannedPeripheral device) async {
    final connectFuture = service.connect(device);
    final reached = await _waitForPhase(
      const {AppConnectionPhase.connected, AppConnectionPhase.failed},
      connectTimeout,
    );
    await connectFuture;
    final current = service.current;
    if (!reached || !current.isConnected) {
      return _StepOutcome.failed(
        current.error ?? 'Connection failed; the remaining steps were stopped.',
      );
    }
    if (!current.controlsAvailable) {
      await service.disconnect();
      return _StepOutcome.failed(
        'The link opened but no supported LEDDMX command channel was '
        'validated, so nothing can be sent. The link was released.',
      );
    }
    _selected = device;
    final variant = current.variant?.advertisedName ?? _deviceLabel(device);
    return _StepOutcome.done(
      'Connected to $variant. No LED state is known yet.',
    );
  }

  Future<_StepOutcome> _disconnect() async {
    final current = service.current;
    if (!current.isConnected) {
      return const _StepOutcome.skipped('Not connected; nothing to release.');
    }
    await service.disconnect();
    final reached = await _waitForPhase(
      const {AppConnectionPhase.disconnected, AppConnectionPhase.failed},
      disconnectTimeout,
    );
    final after = service.current;
    if (!reached || after.isConnected) {
      return _StepOutcome.failed(
        after.error ?? 'The connection could not be released.',
      );
    }
    return const _StepOutcome.done('Disconnected.');
  }

  Future<_StepOutcome> _command(
    Future<CommandResult> Function() send,
  ) async {
    final current = service.current;
    if (!current.isConnected || !current.controlsAvailable) {
      return _StepOutcome.failed(
        current.isConnected
            ? 'The connected device has no supported command channel, so the '
                'rest of the plan was stopped.'
            : 'The controller is no longer connected, so the remaining steps '
                'were stopped.',
      );
    }
    final controls = service.controls;
    if (controls == null) {
      return const _StepOutcome.failed(
        'The command channel is not available; the remaining steps were '
        'stopped.',
      );
    }
    final result = await send();
    return switch (result) {
      CommandSent() => const _StepOutcome.done(
          'BLE write completed; the LED response is not confirmed.',
        ),
      CommandUnsupported(:final reason) => _StepOutcome.failed(
          'The controller does not support this command: $reason',
        ),
      CommandFailed(:final message) => _StepOutcome.failed(
          'The BLE write failed: $message',
        ),
    };
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  String get _noResultsMessage =>
      'No compatible LEDDMX device was found in the scan results. Nothing was '
      'connected.';

  _StepOutcome _noDevice(String message) => _StepOutcome.failed(message);

  ScannedPeripheral? _firstSupported() {
    for (final device in service.current.devices) {
      if (_isSupported(device)) return device;
    }
    return null;
  }

  bool _isSupported(ScannedPeripheral device) =>
      resolveVariant(device.name) is SupportedVariant;

  String _deviceLabel(ScannedPeripheral? device) =>
      device == null ? '(no device)' : (device.name ?? device.id);

  /// Lowercases *first*, then drops separators: doing it in the other order
  /// would delete every uppercase character of `LEDDMX-03-6B4A`.
  String _compact(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  Future<ScannedPeripheral?> _waitForSupportedDevice(Duration timeout) {
    return _waitFor(
      timeout,
      (state) {
        for (final device in state.devices) {
          if (_isSupported(device)) return device;
        }
        return null;
      },
      onFailedPhase: true,
    );
  }

  Future<bool> _waitForPhase(
    Set<AppConnectionPhase> phases,
    Duration timeout,
  ) {
    final current = service.current;
    if (phases.contains(current.phase)) return Future.value(true);
    return _waitFor<bool>(timeout, (state) {
      if (phases.contains(state.phase)) return true;
      return null;
    }).then((value) => value == true);
  }

  /// Waits for the first non-null value produced by [check].
  ///
  /// Completes with `null` on timeout, or immediately when the connection state
  /// moves to `failed` and [onFailedPhase] is set.
  Future<T?> _waitFor<T>(
    Duration timeout,
    T? Function(AppConnectionState state) check, {
    bool onFailedPhase = false,
  }) {
    final completer = Completer<T?>();
    void evaluate(AppConnectionState state) {
      if (completer.isCompleted) return;
      final value = check(state);
      if (value != null) {
        completer.complete(value);
        return;
      }
      if (onFailedPhase && state.phase == AppConnectionPhase.failed) {
        completer.complete(null);
      }
    }

    evaluate(service.current);
    void listener() => evaluate(service.current);
    service.state.addListener(listener);
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    return completer.future.whenComplete(() {
      timer.cancel();
      service.state.removeListener(listener);
    });
  }

  void _emit(List<VoicePlanStepProgress> steps) {
    onProgress?.call(List<VoicePlanStepProgress>.unmodifiable(steps));
  }

  VoicePlanExecution _finish(
    List<VoicePlanStepProgress> steps, {
    required bool success,
    required String message,
    bool wroteNothing = false,
  }) =>
      VoicePlanExecution(
        success: success,
        message: message,
        steps: List<VoicePlanStepProgress>.unmodifiable(steps),
        wroteNothing: wroteNothing,
      );

  /// Whether at least one step actually completed a BLE frame write.
  bool _wroteAnything(List<VoicePlanStepProgress> steps) =>
      steps.any((s) => (s.detail ?? '').contains('BLE write completed'));

  String _successMessage(List<VoicePlanStepProgress> steps) {
    final writes = steps.where(
      (s) => (s.detail ?? '').contains('BLE write completed'),
    );
    final connected = steps.any(
      (s) => (s.detail ?? '').startsWith('Connected to'),
    );
    final statusAsked = steps.any(
      (s) => (s.detail ?? '').contains('no state read-back'),
    );
    if (writes.isEmpty && statusAsked) {
      return 'Nothing was sent. The controller protocol cannot report its '
          'current state, so the LED state is unknown.';
    }
    if (writes.isEmpty) {
      return connected
          ? 'Plan completed. Connected only; no LED command was sent.'
          : 'Plan completed.';
    }
    return 'Plan completed. ${writes.length} BLE write'
        '${writes.length == 1 ? '' : 's'} succeeded; the LED response is not '
        'confirmed by the protocol.';
  }
}

final class _StepOutcome {
  const _StepOutcome._(this.status, this.detail);

  const _StepOutcome.done(String? detail)
      : this._(VoicePlanStepStatus.done, detail);

  const _StepOutcome.skipped(String? detail)
      : this._(VoicePlanStepStatus.skipped, detail);

  const _StepOutcome.failed(String detail)
      : this._(VoicePlanStepStatus.failed, detail);

  final VoicePlanStepStatus status;
  final String? detail;
}
