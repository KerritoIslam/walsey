# Package structure and dependencies

## Packages

```
walsey/
  walsey_led_core/        PURE DART. No Flutter, no BLE plugin.
  walsey_led_ble/         (Stage 2) Flutter plugin package: LedTransport over bluetooth_low_energy
  walsey_voice_core/      PURE DART. Voice parser + SpeechRecognizer port; no Flutter, BLE or engine.
  walsey_voice_speech/    Voice Stage 2 Flutter adapter: Vosk FFI, microphone, model setup.
  apps/walsey/            (Stage 2) main app: connection UI + typed controls + first-hardware-test tab
  apps/walsey_voice_test/ Voice Stage 2 testbed: speech/typed command -> interpretation, no execution
  tools/ble_probe/        (Stage 1) read-only discovery/connection prototype, frozen
```

The voice packages form an independent stack: `walsey_voice_speech` implements
the `SpeechRecognizer` port from `walsey_voice_core` and feeds recognized text
to the same `VoiceCommandParser` as typed input. Neither voice package imports
`walsey_led_core` or `walsey_led_ble`, so no voice code path can emit a frame.
`docs/voice_stage2.md` documents the recognition pipeline.

Why `walsey_led_ble` is separate: `bluetooth_low_energy` is a Flutter plugin, so
depending on it would make the core non-pure and untestable with `dart test`.
The core owns an abstract `LedTransport`; the adapter implements it; tests use a
fake.

The Stage 1 probe in `tools/ble_probe/lib/ble/` stays a **read-only** workflow
(`BleCentral` port, `PluginBleCentral`, pure GATT validation,
`LedProbeService`). It exposes no writes, handshake or notification
subscription, so it is not the Stage 2 transport. Stage 2 deliberately **copies**
that port/adapter shape into `walsey_led_ble` instead of importing the probe or
editing it, so the probe remains a trustworthy reference and cannot send a frame
by accident.

Layer split in Stage 2 (no shortcut between layers):

```
UI (apps/walsey/lib/ui, main.dart)
  ↓ typed calls only: setPower / setColor / setBrightness / applyEffect / authenticate
App service (apps/walsey/lib/control/led_control_service.dart)
  ↓ LeddmxDriver + logging + one-command-at-a-time guard
Protocol driver (walsey_led_core/lib/src/controller/leddmx_driver.dart)
  ↓ encode*() pure functions + WriteQueue
Transport port (walsey_led_core/lib/src/transport/led_transport.dart)
  ↓ implemented by walsey_led_ble/lib/src/plugin_led_transport.dart
BLE adapter (walsey_led_ble/lib/src/plugin_central.dart)
  ↓ bluetooth_low_energy
```

Connection state machine (`apps/walsey/lib/connection/led_connection_service.dart`)
owns scan/connect/discover/validate/disconnect, keeps the probe's guarantee set,
and binds the driver after FFE0/FFE1 validation. It sends nothing.

## Inside `walsey_led_core`

```
lib/src/
  domain/      RgbColor, BrightnessLevel, LedEffect, LedCommand (sealed),
               DeviceCapabilities, Evidence, InvalidCommandException,
               LedTransportException                                     [1 + 2, done]
  protocol/    leddmx_variant.dart   name -> SupportedVariant | UnsupportedVariant
               leddmx_frames.dart    pure 9-byte encoders, no I/O          [1, done]
  controller/  leddmx_driver.dart    LeddmxDriver, CommandResult,
               DeviceState, PasswordStatus, WriteMode, frameToHex        [2, done]
  queue/       write_queue.dart      serial writes, min-gap, timeout,
               block-after-timeout                                    [2, done]
  transport/   led_transport.dart    abstract write/notifications/close  [2, done]
  scenes/      Scene, SceneValidator, SceneStore, in-memory + JSON stores [3]
```

### Implemented API (Stage 2, as built)

```dart
abstract interface class LedTransport {
  Future<void> write(Uint8List frame, {required bool withResponse});
  Stream<Uint8List> get notifications;
  Future<void> close();
}

sealed class CommandResult { }
final class CommandSent     extends CommandResult { frame, hex, writeMode, redactedIndices }
final class CommandUnsupported extends CommandResult { reason }
final class CommandFailed   extends CommandResult { message, cause }

final class LeddmxDriver {
  void attach(SupportedVariant variant);        // no frame sent
  Future<void> detach(); Future<void> dispose();
  Future<CommandResult> setPower({required bool on});
  Future<CommandResult> setColor(RgbColor color);
  Future<CommandResult> setBrightness(BrightnessLevel brightness);
  Future<CommandResult> applyEffect(LedEffect effect);
  Future<CommandResult> authenticate({DateTime? now, List<int> password});
  Future<PasswordQueryOutcome> checkPasswordStatus({Duration replyTimeout});
  DeviceState get state;                        // last command *sent*, never device state
}
```

Design rules that follow from the research:

- `send` returns `CommandUnsupported(reason)` for any capability the resolved
  variant lacks; there is no code path that logs success without writing.
- `DeviceState` records `lastCommand`, `lastFrameHex`, `lastWriteMode`,
  `lastSentAt`, `handshakeSent`, `lastPasswordStatus`, `lastNotificationHex`.
  There is **no** field that claims the device's actual state, because the
  protocol has no read-back.
- Frame encoders stay free functions with no I/O; the driver is the only place
  that maps a command to a frame and sequences it.
- The queue serialises all writes (including the handshake), enforces ≥ 50 ms
  between writes, applies a 5 s per-write timeout, and surfaces errors per
  command. A timed-out write sets a block that only reattaching/`reset()` clears,
  because the underlying platform write cannot be cancelled.
- `attach` only subscribes to notifications; the handshake is an explicit call.
- Handshake password bytes (indices 2–5) are redacted by `frameToHex`, so logs
  and UI show `2a 02 ** ** ** ** <tb> <min> af`.

## Dependencies

| Package | Where | Why | Status |
|---|---|---|---|
| `bluetooth_low_energy ^6.2.1` | `walsey_led_ble`, `tools/ble_probe` | Android + Windows central role, writes + notifications | Android connection verified 2026-10-23; **Windows does not compile** with MSVC 14.51 (`/await` deprecation inside the plugin) |
| `device_info_plus`, `permission_handler` | `walsey_led_ble` | Android SDK detection and runtime permission preflight | Analyzer/tests only; same permission flow that worked in the probe |
| `test`, `lints` | core dev | unit tests, analysis | present |
| `flutter_lints` | Flutter packages | analysis | present |

Platform setup: Android `minSdk 24`, manifest BLE permissions per the plugin docs
(copied from the probe). Windows needs a working Bluetooth adapter *and* a
toolchain the plugin supports.
