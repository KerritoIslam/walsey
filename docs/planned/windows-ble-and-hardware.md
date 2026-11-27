# Plan: Windows BLE validation and first hardware sign-off

**Status: both apps build on Windows, but Windows BLE has never been run
against a controller, and no LEDDMX frame has been sent on any platform.**
Android BLE connectivity alone was hardware-confirmed on 2026-10-23.

Reference: [`../hardware_checklist.md`](../hardware_checklist.md) and
[`../research.md`](../research.md).

## What is already true

- `tools/ble_probe` (read-only) validated the connection flow.
- The Stage 2 app reuses the same port/adapter shape, adds writes and
  notifications.
- Android hardware result: `LEDDMX-03-6B4A`, service FFE0, FFE1
  read/write/writeWithoutResponse/notify, FFE2 notify-only.
- The Windows debug build passes with:
  - `nuget.exe` on `PATH` (for `flutter_tts`/CppWinRT);
  - the app-side CMake workaround that builds two BLE plugins as C++20 without
    `/await`.
- The Windows build passing is **not** evidence that BLE works on Windows.

## Step 1 — Windows BLE connectivity (probe first)

Use `tools/ble_probe` before the main app. It is read-only and cannot send a
frame.

1. Confirm Windows Bluetooth LE is on and the controller is not connected to the
   vendor app or a phone.
2. Run the probe on Windows, scan, connect, record the advertised name.
3. Record the full GATT tree and properties.
4. If the name is not `LEDDMX-NN`, **stop**: no layout is documented.
5. Re-run H1/H2/H3 from the checklist and record the result in its Result column.

Expected: the same FFE0/FFE1/FFE2 shape as Android. If Windows exposes different
properties or cannot discover FFE1, record it and do not proceed to writes.

## Step 2 — main app, no frame

1. Run `flutter run -d windows` from `apps/walsey`.
2. Connect and validate FFE0/FFE1.
3. Confirm the log shows `GATT TRANSPORT RESULT: FFE0/FFE1 validated` and
   `CONTROL API BOUND`, with no frame written.
4. Leave it connected for several minutes; confirm no timer/reconnect loop.

## Step 3 — controlled first frame (Android first)

Do this on Android first because it is the hardware-validated platform, then
repeat on Windows.

Follow [`../../apps/walsey/README.md`](../../apps/walsey/README.md):

1. Handshake (explicit button). No LED change expected.
2. Password status (`2A 05`). The only documented device reply.
3. Power OFF.
4. Power ON.
5. Red.

Stop if power off/on does nothing. Do not try random frames or the other layout.
Record each frame, write mode and result. Record the human observation
separately as `USER OBSERVATION:`.

## Step 4 — complete the checklist

Run H4–H14 and V1–V12 on Android, then repeat on Windows (H12/V12). Important
groups:

- brightness floor vs round (H7);
- shifted-layout white channel (H5/H6);
- effects 1, 3, 72, 73, 100, 210, 255 (H8);
- burst pacing: 50/30/100 ms gaps (H10);
- link loss/unplug (H11, H14);
- notification/password reply (H13/V9);
- full voice → plan → write path (V1–V12).

## Step 5 — evidence sign-off

A capability may move from `Evidence.decompiledApp` to
`Evidence.hardwareConfirmed` only when the matching rows pass on **both**
Windows and Android. A successful build, a unit test, or "BLE write OK" is not a
pass.

Update:

- [`../hardware_checklist.md`](../hardware_checklist.md) result columns;
- [`../research.md`](../research.md) evidence notes;
- the capability/evidence values in `walsey_led_core`;
- [`../../README.md`](../../README.md) and the app README if a claim changes.

## Failure handling to verify

- A failed/timed-out write is reported `FAILED`.
- A timeout blocks further writes until reconnect.
- Link loss disables controls and never auto-reconnects.
- No automatic frame is sent on connect, reconnect, startup or lifecycle change.
- The handshake password stays redacted in logs and UI.

## Acceptance

- Windows BLE connectivity is recorded (pass or fail) with the exact GATT
  findings.
- The first controlled frames are observed on Android and Windows.
- The checklist result columns are filled in, not inferred.
- No documentation claims LED control until both platforms pass.
