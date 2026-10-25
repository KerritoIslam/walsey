import 'dart:async';
import 'dart:typed_data';

import '../domain/capabilities.dart';
import '../domain/led_command.dart';
import '../domain/values.dart';
import '../protocol/leddmx_frames.dart';
import '../protocol/leddmx_variant.dart';
import '../queue/write_queue.dart';
import '../transport/led_transport.dart';

/// How a frame was written to FFE1.
///
/// The vendor app never sets a write type explicitly, so the documented default
/// is "with response". The adapter must report the mode it actually used.
enum WriteMode { withResponse, withoutResponse }

/// Outcome of one command. There is deliberately no "maybe": either the write
/// completed, the variant cannot express the command, or the write failed.
sealed class CommandResult {
  const CommandResult();
}

/// The frame was handed to the transport successfully.
///
/// This confirms a BLE write, NOT that the LEDs responded: the protocol has no
/// state read-back.
final class CommandSent extends CommandResult {
  const CommandSent({
    required this.command,
    required this.frame,
    required this.writeMode,
    this.redactedIndices = const <int>{},
  });

  final String command;
  final Uint8List frame;
  final WriteMode writeMode;

  /// Byte positions whose values must not be logged (handshake password).
  final Set<int> redactedIndices;

  /// Hex representation safe for logs and the UI.
  String get hex => frameToHex(frame, redact: redactedIndices);
}

/// The resolved variant has no documented frame for this command.
final class CommandUnsupported extends CommandResult {
  const CommandUnsupported(this.reason);
  final String reason;
}

/// The frame was not written (disconnected, timeout, platform error).
final class CommandFailed extends CommandResult {
  const CommandFailed(this.message, [this.cause]);
  final String message;
  final Object? cause;
}

/// Documented meaning of the controller's answer to the password query.
///
/// LED_UNION documents the reply as `2A 05 <status>` (1 wrong password,
/// 2 all-same-digit, 3 resend). Exact padding inside the 9-byte envelope is not
/// documented, so anything else maps to [unknown] instead of being guessed.
enum PasswordStatus {
  wrongPassword,
  allSameDigits,
  resendRequested,
  unknown,
}

/// Last command sent over the link. Never a claim about the controller's
/// actual state: LEDDMX has no state read-back.
final class DeviceState {
  const DeviceState({
    this.attached = false,
    this.handshakeSent = false,
    this.lastCommand,
    this.lastFrameHex,
    this.lastWriteMode,
    this.lastSentAt,
    this.lastPasswordStatus,
    this.lastNotificationHex,
  });

  final bool attached;

  /// A handshake write completed. It does NOT prove the controller accepted
  /// the password; only a password-query reply can speak to that.
  final bool handshakeSent;

  final String? lastCommand;
  final String? lastFrameHex;
  final WriteMode? lastWriteMode;
  final DateTime? lastSentAt;

  final PasswordStatus? lastPasswordStatus;
  final String? lastNotificationHex;

  DeviceState copyWith({
    bool? attached,
    bool? handshakeSent,
    String? lastCommand,
    String? lastFrameHex,
    WriteMode? lastWriteMode,
    DateTime? lastSentAt,
    PasswordStatus? lastPasswordStatus,
    String? lastNotificationHex,
  }) =>
      DeviceState(
        attached: attached ?? this.attached,
        handshakeSent: handshakeSent ?? this.handshakeSent,
        lastCommand: lastCommand ?? this.lastCommand,
        lastFrameHex: lastFrameHex ?? this.lastFrameHex,
        lastWriteMode: lastWriteMode ?? this.lastWriteMode,
        lastSentAt: lastSentAt ?? this.lastSentAt,
        lastPasswordStatus: lastPasswordStatus ?? this.lastPasswordStatus,
        lastNotificationHex: lastNotificationHex ?? this.lastNotificationHex,
      );
}

/// Result of [LeddmxDriver.checkPasswordStatus].
///
/// [status] is null when the write failed or no documented reply arrived inside
/// the timeout. A missing reply is never treated as success.
final class PasswordQueryOutcome {
  const PasswordQueryOutcome({required this.write, this.status});

  final CommandResult write;
  final PasswordStatus? status;

  bool get replied => status != null;
}

/// Typed command API over an attached [LedTransport].
///
/// - Every frame comes from the pure encoders in `leddmx_frames.dart`.
/// - All writes (including the handshake) go through one [WriteQueue], so they
///   are serialised and paced.
/// - The driver refuses commands when detached or when the resolved variant
///   does not document the capability.
/// - Nothing is ever sent automatically: [attach] only opens the notification
///   stream. [authenticate] is an explicit call.
final class LeddmxDriver {
  LeddmxDriver({
    required LedTransport transport,
    this.minGap = const Duration(milliseconds: 50),
    this.writeTimeout = const Duration(seconds: 5),
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  }) : _transport = transport {
    _queue = WriteQueue(
      transport: transport,
      minGap: minGap,
      writeTimeout: writeTimeout,
      delay: delay ?? _defaultDelay,
      clock: clock ?? DateTime.now,
    );
  }

  final LedTransport _transport;
  late final WriteQueue _queue;

  final Duration minGap;
  final Duration writeTimeout;

  final StreamController<DeviceState> _stateController =
      StreamController<DeviceState>.broadcast();

  DeviceState _state = const DeviceState();
  SupportedVariant? _variant;
  StreamSubscription<Uint8List>? _notificationSub;
  Completer<PasswordStatus>? _passwordReply;

  DeviceState get state => _state;

  /// Stream of last-sent state changes (not device state).
  Stream<DeviceState> get stateChanges => _stateController.stream;

  /// The variant attached to this link, or null when detached.
  SupportedVariant? get variant => _variant;

  bool get isAttached => _variant != null;

  /// Binds the driver to a GATT-validated link.
  ///
  /// Call after FFE0/FFE1 validation. Does not send anything.
  void attach(SupportedVariant variant) {
    _variant = variant;
    _queue.reset();
    _emit(_state.copyWith(attached: true));
    unawaited(_notificationSub?.cancel());
    _notificationSub = _transport.notifications.listen(
      _handleNotification,
      onError: (Object error, StackTrace stackTrace) {
        // A notification-stream error is not a command result; the app's
        // connection layer owns link-loss handling.
      },
    );
  }

  /// Unbinds from the link and drops the notification subscription.
  ///
  /// Does not close [LedTransport]; the connection layer owns the link.
  Future<void> detach() async {
    _variant = null;
    await _notificationSub?.cancel();
    _notificationSub = null;
    _queue.reset();
    _emit(_state.copyWith(attached: false));
  }

  /// Releases driver resources. Call [detach] first if the link is still open.
  Future<void> dispose() async {
    await detach();
    await _stateController.close();
  }

  Future<CommandResult> setPower({required bool on}) =>
      send(PowerCommand(on: on));

  Future<CommandResult> setColor(RgbColor color) =>
      send(SetColorCommand(color));

  Future<CommandResult> setBrightness(BrightnessLevel brightness) =>
      send(SetBrightnessCommand(brightness));

  Future<CommandResult> applyEffect(LedEffect effect) =>
      send(ApplyEffectCommand(effect));

  /// Sends the documented authentication handshake.
  ///
  /// Explicit on purpose: the vendor app sends it automatically ~300 ms after
  /// connecting, but this app requires a deliberate user action for the first
  /// hardware tests. Side effect documented by LED_UNION: it sets the
  /// controller's clock.
  Future<CommandResult> authenticate({
    DateTime? now,
    List<int> password = defaultPassword,
  }) =>
      _sendFrame(
        command: 'handshake',
        frame: encodeHandshake(now ?? DateTime.now(), password: password),
        redactedIndices: const {2, 3, 4, 5},
      );

  /// Sends `2A 05 FF×6 AF` and waits for the documented password-status reply
  /// notification (if any) for up to [replyTimeout].
  ///
  /// The returned write result proves only that the query frame was written.
  /// A non-null [PasswordQueryOutcome.status] proves the controller answered;
  /// a null status means the query was sent but no documented reply arrived.
  Future<PasswordQueryOutcome> checkPasswordStatus({
    Duration replyTimeout = const Duration(seconds: 2),
  }) async {
    final completer = Completer<PasswordStatus>();
    _passwordReply = completer;

    final result = await _sendFrame(
      command: 'password query',
      frame: encodePasswordQuery(),
    );
    if (result is! CommandSent) {
      if (identical(_passwordReply, completer)) _passwordReply = null;
      return PasswordQueryOutcome(write: result);
    }

    try {
      final status = await completer.future
          .then<PasswordStatus?>((value) => value)
          .timeout(replyTimeout, onTimeout: () => null);
      return PasswordQueryOutcome(write: result, status: status);
    } finally {
      if (identical(_passwordReply, completer)) _passwordReply = null;
    }
  }

  /// Maps one [LedCommand] to the existing pure encoder and writes it.
  Future<CommandResult> send(LedCommand command) {
    final variant = _variant;
    if (variant == null) {
      return Future.value(
        const CommandFailed('not attached: connect and validate first'),
      );
    }

    final capability = switch (command) {
      PowerCommand() => Capability.power,
      SetColorCommand() => Capability.color,
      SetBrightnessCommand() => Capability.brightness,
      ApplyEffectCommand() => Capability.effect,
    };
    final support = variant.capabilities.of(capability);
    if (!support.isSupported) {
      return Future.value(CommandUnsupported(
        support.unsupportedReason ?? 'capability not modelled',
      ));
    }

    final (name, frame) = switch (command) {
      PowerCommand(:final on) => (
          on ? 'power on' : 'power off',
          encodePower(variant.layout, on: on),
        ),
      SetColorCommand(:final color) => (
          'color ${color.r} ${color.g} ${color.b}',
          encodeRgb(variant.layout, color),
        ),
      SetBrightnessCommand(:final brightness) => (
          'brightness ${brightness.percent}%',
          encodeBrightness(variant.layout, brightness),
        ),
      ApplyEffectCommand(:final effect) => (
          'effect ${effect.id}',
          encodeEffect(variant.layout, effect),
        ),
    };

    return _sendFrame(command: name, frame: frame, redactedIndices: const {});
  }

  Future<CommandResult> _sendFrame({
    required String command,
    required Uint8List frame,
    Set<int> redactedIndices = const <int>{},
  }) async {
    if (_variant == null) {
      return const CommandFailed('not attached: connect and validate first');
    }

    final mode = WriteMode.withResponse;
    try {
      await _queue.write(frame, withResponse: mode == WriteMode.withResponse);
    } catch (error) {
      return CommandFailed('$error', error);
    }

    _emit(_state.copyWith(
      handshakeSent: _state.handshakeSent || command == 'handshake',
      lastCommand: command,
      lastFrameHex: frameToHex(frame, redact: redactedIndices),
      lastWriteMode: mode,
      lastSentAt: DateTime.now(),
    ));
    return CommandSent(
      command: command,
      frame: frame,
      writeMode: mode,
      redactedIndices: redactedIndices,
    );
  }

  void _handleNotification(Uint8List frame) {
    final text = frameToHex(frame);
    final status = parsePasswordStatus(frame);
    _emit(_state.copyWith(
      lastNotificationHex: text,
      lastPasswordStatus: status ?? _state.lastPasswordStatus,
    ));

    final reply = _passwordReply;
    if (reply != null && !reply.isCompleted && status != null) {
      reply.complete(status);
    }
  }

  void _emit(DeviceState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);
}

/// Parses the documented password-status reply.
///
/// Accepts a 9-byte `2A 05 … AF` envelope with exactly one non-padding byte
/// after the opcode. Returns null when the frame is not a password reply;
/// returns [PasswordStatus.unknown] when it is one but the status is not in the
/// documented 1..3 set.
PasswordStatus? parsePasswordStatus(Uint8List frame) {
  if (frame.length < 4 || frame[0] != 0x2A || frame[1] != 0x05) return null;

  final candidates = <int>[];
  for (var i = 2; i < frame.length - 1; i++) {
    final byte = frame[i];
    if (byte != 0xFF) candidates.add(byte);
  }
  if (candidates.length != 1) return PasswordStatus.unknown;

  return switch (candidates.single) {
    1 => PasswordStatus.wrongPassword,
    2 => PasswordStatus.allSameDigits,
    3 => PasswordStatus.resendRequested,
    _ => PasswordStatus.unknown,
  };
}

/// `7b ff 07 …` — lowercase, space separated. Bytes in [redact] become `**`.
String frameToHex(Uint8List frame, {Set<int> redact = const <int>{}}) => [
      for (var i = 0; i < frame.length; i++)
        redact.contains(i)
            ? '**'
            : frame[i].toRadixString(16).padLeft(2, '0'),
    ].join(' ');
