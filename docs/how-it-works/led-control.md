# LED control: protocol, transport and evidence

This is the working explanation of the LED stack. The authoritative evidence
log is [`../research.md`](../research.md); the pass/fail matrix is
[`../hardware_checklist.md`](../hardware_checklist.md).

## 1. What the controller is

The vendor app is **LED LAMP**. The controller advertises as
`LEDDMX-NN-XXXX` (for example `LEDDMX-03-6B4A`) and exposes service **FFE0**:

| Characteristic | Confirmed properties (2026-10-23, Android) | Use |
|---|---|---|
| FFE1 | read, write, writeWithoutResponse, notify | Commands are written here. Notifications carry the password reply |
| FFE2 | notify only | Present, not used as a command channel |

The Android probe confirmed connectivity and these properties. It did **not**
write anything. The app writes `withResponse` by default, matching the vendor
app's default; the transport reports the mode it actually used.

## 2. Variant resolution

The layout is chosen **only** from an advertised name matching
`^LEDDMX-(\d{2})(?!\d)` (case-insensitive):

| Advertised number | Layout | Meaning |
|---|---|---|
| `00`, `01`, `03` | `filler` | `7B FF <cmd> … BF` |
| `02`, `04` | `shifted` | `7B <cmd> … BF`, parameters one byte left |
| anything else | `UnsupportedVariant` | No documented layout; controls stay disabled |

`"LED DMX"`, LEDBLE/LEDCAR names, a bare number and unknown suffixes are not
accepted. The regex is deliberately strict: a false match could send a valid
frame to the wrong layout.

The resolved `SupportedVariant` marks power, colour, brightness and effect as
**supported but `Evidence.decompiledApp`**. That word matters: every byte below
comes from LED_UNION's decompilation, not from this controller.

## 3. Frame encoders

All encoders are pure free functions in
`walsey_led_core/lib/src/protocol/leddmx_frames.dart`. No I/O, no timing, no
state. Every frame is exactly 9 bytes, starts `7B`, ends `BF`, has no checksum
and is never fragmented.

| Command | Filler (`00/01/03`) | Shifted (`02/04`) |
|---|---|---|
| Power off/on | `7B 04 04 <00/01> FF FF FF FF BF` | `7B 04 <00/01> FF FF FF FF FF BF` |
| RGB | `7B FF 07 R G B 00 FF BF` | `7B 07 R G B 00 FF FF BF` |
| Brightness | `7B FF 01 <(v*32)~/100> <v> 00 FF FF BF` | `7B 01 <v> 00 FF FF FF FF BF` |
| Effect | `7B FF 03 <id> FF FF FF FF BF` (opcode `03` = built-in) | `7B 03 <id> FF FF FF FF FF BF` |
| Handshake | `2A 02 <p0..p3> <tb> <min> AF` | same (layout-independent) |
| Password query | `2A 05 FF FF FF FF FF FF AF` | same |

Documented-but-pinned unknowns:

- **Brightness scaling uses floor** (`(v * 32) ~/ 100`). LED_UNION's driver uses
  `Math.round`; the decompiled Java formula uses integer division. Hardware
  checklist H7 is the deciding test.
- **Shifted RGB sends white `0`.** LED_UNION sends 0 "to keep it out of the
  mix"; this is an assumption until verified.
- **Effect ids 1–210 and 255** are exposed. Ids ≥ 73 are variant-dependent, so
  their visual behaviour cannot be promised.
- **The handshake also sets the controller clock**:
  `tb = (weekday << 5) | hour24` with Monday = 1. Password bytes 2–5 are redacted
  from every log and UI string.

Do not "fix" any of these silently. Changing one requires updating the code
comment, `research.md`, the hardware checklist row and the literal-byte tests
together.

## 4. Layer split

```
UI / Assistant plan
  │ typed calls: setPower / setColor / setBrightness / applyEffect / authenticate
  ▼
LedControlService (apps/walsey/lib/control)
  │ logging, one-command-at-a-time guard, redaction, activity entry
  ▼
LeddmxDriver (walsey_led_core/lib/src/controller)
  │ choose the encoder for the attached layout
  ▼
WriteQueue (walsey_led_core/lib/src/queue)
  │ serialise, pace, timeout, block-after-timeout
  ▼
LedTransport port (walsey_led_core)
  ▼
PluginLedTransport (walsey_led_ble)
  │ 9-byte guard, FFE1 routing
  ▼
PluginBleCentral → bluetooth_low_energy
```

Why the split: the core must stay pure enough for `dart test`. The BLE plugin
only knows how to write bytes and expose notifications; it does not know what a
frame means. The driver only knows documented commands; it never invents a byte.
The app service only owns UI-facing behaviour and logging.

### `LeddmxDriver`

- `attach(variant)` subscribes to notifications and records the layout. It sends
  nothing.
- `authenticate(...)` is an explicit handshake call. The vendor app does this
  automatically ~300 ms after connecting; Walsey never does.
- `setPower`, `setColor`, `setBrightness`, `applyEffect` return
  `CommandSent`, `CommandUnsupported` or `CommandFailed`.
- `checkPasswordStatus(...)` writes `2A 05` and waits for a documented reply.
  A timeout is "no documented reply", never success.
- `DeviceState` records the **last command sent** and the last password status.
  There is no field that claims the current LED state.

### `WriteQueue`

| Guarantee | Value |
|---|---|
| Concurrent writes | at most one |
| Gap between writes | ≥ 50 ms, measured from the previous write's completion |
| Per-write timeout | 5 s |
| After a timeout | further writes are refused until `reset()` / reattach |

A timed-out platform write cannot be cancelled, so allowing another write could
overlap frames on FFE1. The queue therefore blocks instead of guessing. The app
reattaches only after a fresh connection.

## 5. Connection state machine

`apps/walsey/lib/connection/led_connection_service.dart` owns:

1. scan (refused while connected);
2. select one advertised target;
3. resolve the variant (unsupported → stop);
4. connect and discover services;
5. validate FFE0 + FFE1 properties;
6. enable FFE1 notifications (receive-only, for the password reply);
7. bind the driver;
8. keep the link open until an explicit disconnect, link loss or dispose.

There is no connect timer, retry loop, automatic rescan or auto-disconnect after
validation. Those rules are inherited from the Stage 1 probe and are covered by
tests.

## 6. What is actually evidence

| Claim | Evidence level |
|---|---|
| Android can connect and discover FFE0/FFE1/FFE2 with these properties | **hardware-confirmed** (probe, 2026-10-23) |
| Windows can connect and write | **not run** |
| Frame layouts and byte meanings | `decompiledApp` (LED_UNION) |
| Brightness floor vs round | unknown; H7 |
| Shifted white channel value | assumption; H5/H6 |
| Effects ≥ 73 | variant-dependent; H8 |
| A frame changes the LEDs | **never observed** |

Rules that follow:

- "BLE write OK" is not an LED change.
- Only `USER OBSERVATION:` records a human seeing a change.
- `Evidence.hardwareConfirmed` requires the matching rows to pass on **both**
  Windows and Android.
- No API or doc may claim "the LEDs are now X".

## 7. How to change protocol code safely

1. Read [`../research.md`](../research.md) and find the exact decompiled bytes.
2. Add or change a **pure** encoder in `leddmx_frames.dart`.
3. Add literal expected hex strings to
   `walsey_led_core/test/leddmx_frames_test.dart` (hand-written from the spec,
   never computed with the encoder).
4. If validation changes, update the value object, its constructor checks and
   the `InvalidCommandException` tests.
5. If the drive path changes, extend `driver_and_queue_test.dart` (serialisation,
   pacing, timeout, block-after-timeout, variant refusal, redaction).
6. Update the matching hardware-checklist row and `research.md`. Never flip an
   evidence level without hardware.
7. Update the app service/UI only through typed calls; do not add a second
   command path.
