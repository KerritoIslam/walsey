// Private named parameters cannot be initializing formals; the constructor's
// public names are the package API.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

/// Typed command facade used by the UI.
///
/// Keeps protocol knowledge out of widgets: the UI only names an operation and
/// valid values; frames come from [LeddmxDriver] → `leddmx_frames.dart`.
///
/// Every send logs: variant + layout, command, frame hex (handshake password
/// redacted), write mode and result. A successful write is logged as a BLE
/// success only — never as confirmed LED behaviour.
final class LedControlService {
  LedControlService({
    required LeddmxDriver driver,
    required LeddmxLayout layout,
    required void Function(String line) log,
  })  : _driver = driver,
        _layout = layout,
        _log = log;

  final LeddmxDriver _driver;
  final LeddmxLayout _layout;
  final void Function(String) _log;

  final ValueNotifier<bool> _busy = ValueNotifier<bool>(false);

  /// True while one command is in flight. The UI disables command buttons.
  ValueListenable<bool> get busy => _busy;

  String get variantLabel =>
      _driver.variant?.advertisedName ?? '(detached)';

  String get layoutLabel => _layout.name;

  /// Appends an input/validation message to the same diagnostic log.
  void log(String line) => _log(line);

  Future<CommandResult> setPower({required bool on}) => _run(
        'power ${on ? 'on' : 'off'}',
        () => _driver.setPower(on: on),
      );

  Future<CommandResult> setColor(RgbColor color) => _run(
        'color ${color.r} ${color.g} ${color.b}',
        () => _driver.setColor(color),
      );

  Future<CommandResult> setBrightness(BrightnessLevel brightness) => _run(
        'brightness ${brightness.percent}%',
        () => _driver.setBrightness(brightness),
      );

  Future<CommandResult> applyEffect(LedEffect effect) => _run(
        'effect ${effect.id}',
        () => _driver.applyEffect(effect),
      );

  /// Sends the authentication handshake once. Never automatic.
  Future<CommandResult> authenticate({DateTime? now}) => _run(
        'handshake',
        () => _driver.authenticate(now: now),
      );

  /// Sends `2A 05` and reports the documented password-status reply, if any.
  Future<PasswordQueryOutcome> checkPasswordStatus() async {
    if (_busy.value) {
      _log('COMMAND IGNORED (password query): another command is in progress');
      return const PasswordQueryOutcome(
        write: CommandFailed('another command is in progress'),
      );
    }

    _busy.value = true;
    try {
      _log('COMMAND password query | variant=$variantLabel | '
          'layout=$layoutLabel | frame=2a 05 ff ff ff ff ff ff af');
      final outcome = await _driver.checkPasswordStatus();
      _logResult('password query', outcome.write);
      _log(outcome.status == null
          ? 'PASSWORD REPLY: none within timeout. The query was sent, but '
              'nothing confirms the controller accepted the password.'
          : 'PASSWORD REPLY: ${outcome.status!.name} '
              '(documented meaning; reply is the only protocol response)');
      return outcome;
    } catch (error) {
      _log('COMMAND password query FAILED unexpectedly: $error');
      return PasswordQueryOutcome(write: CommandFailed('$error', error));
    } finally {
      _busy.value = false;
    }
  }

  Future<CommandResult> _run(
    String name,
    Future<CommandResult> Function() send,
  ) async {
    if (_busy.value) {
      _log('COMMAND IGNORED ($name): another command is in progress');
      return const CommandFailed('another command is in progress');
    }

    _busy.value = true;
    try {
      _log('COMMAND $name | variant=$variantLabel | layout=$layoutLabel | '
          'write=withResponse');
      final result = await send();
      _logResult(name, result);
      return result;
    } catch (error) {
      _log('COMMAND $name FAILED unexpectedly: $error');
      return CommandFailed('$error', error);
    } finally {
      _busy.value = false;
    }
  }

  void _logResult(String name, CommandResult result) {
    switch (result) {
      case CommandSent(:final hex, :final writeMode):
        _log('RESULT $name: BLE WRITE OK | mode=${writeMode.name} | '
            'frame=$hex | LED response NOT confirmed (no protocol read-back)');
      case CommandUnsupported(:final reason):
        _log('RESULT $name: UNSUPPORTED | $reason');
      case CommandFailed(:final message):
        _log('RESULT $name: FAILED | $message');
    }
  }

  void dispose() {
    _busy.dispose();
  }
}
