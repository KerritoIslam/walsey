# Hardware test checklist

Record every result (pass / fail / observed value) next to the item. Nothing in this project may be called "working on the controller" until the relevant row says pass.

## Before you start
- [ ] Power the controller from a supply that matches its rating and the strip's voltage. Check V+/V− polarity before applying power. Don't hot-swap the LED output (GND/DAT/VCC) while powered.
- [ ] Confirm the **vendor app (LED LAMP)** controls the strip. This is the baseline.
- [ ] **Force-close the vendor app** (and disconnect it) before every test below; BLE peripherals of this kind typically accept one connection. *(Assumption, not verified.)*
- [ ] Note: `Windows` PC has Bluetooth LE on; `Android` phone ≥ Android 7 (minSdk 24) with Bluetooth and nearby-device permission granted.

## Stage 1 tests (runnable now with `tools/ble_probe`, no frames are sent)

| ID | Test | Expected | Result |
|---|---|---|---|
| H1 | Scan on **Android**, then **Windows**. Record the exact advertised name(s) of the controller. | A name like `LEDDMX-NN-XXXX`. The probe prints `variant by name`. If it prints UNSUPPORTED, **stop**; the driver cannot be targeted yet. | Android: **PASS (2026-10-23)** — advertised name `LEDDMX-03-6B4A`, resolves to `filler`. Windows: not run. |
| H2 | Tap *connect*. Record all services/characteristics and properties. | Service `ffe0…`, char `ffe1…` with write (and notify). Record whether `ffe2` exists and what it allows. | Android: **PASS (2026-10-23)** — FFE0 present; FFE1 read/write/writeWithoutResponse/notify; FFE2 present with notify only. Transport only: no frames were sent. Windows: not run. |
| H3 | Connect, leave it ≥60 s, then press **Disconnect**. Repeat 10 times, each platform. | Exactly one connect + discovery per attempt and no periodic connect/disconnect lines while connected. Disconnect releases the link. 10/10 with no hang. Record timeouts. | |
| H3b | After disconnect, open vendor app. | It connects normally (we did not leave the controller locked). | |

**2026-10-23 Android observation (pre-fix):** the probe was reported to repeat
connect/discover/disconnect every 5–10 s. The old workflow disconnected
unconditionally after every successful validation, and each new scan re-armed
auto-connect; no timer or retry loop exists in the app or the BLE plugin.
The current workflow keeps the link open, refuses scans while connected, and
tags every attempt `origin=auto (scan #N)` / `origin=manual`. Re-run H2/H3 and
confirm one connection per scan in `adb logcat -s WalseyBleProbe:D`.

## Stage 2 tests (`apps/walsey` — driver implemented, nothing run on hardware yet)

Run these from `apps/walsey` on **Android** first; Windows is blocked by a
third-party build failure (see H13). Every frame below is decompiled-app
evidence until the row passes. The app sends exactly one frame per press and
logs `variant`, `command`, `frame`, `write mode`, `result`; the handshake
password is logged redacted.

Suggested order in the *Hardware test* tab: (1) handshake, (2) `2A 05` password
status, (3) power off, (4) power on, (5) red. Stop if (3)/(4) does nothing.

| ID | Test | Expected | Result |
|---|---|---|---|
| H4 | Connect, then press **Authenticate** (handshake), then **Power OFF**. Then repeat a fresh connection and press **Power OFF** *without* handshake. | Light responds only after handshake (confirms the "ignored until auth" claim). Also record the `2A 05` reply, if any, from step 2. If the handshake appears rejected, check whether the vendor app changed the password. | |
| H5 | Power on/off ×10. Colors: pure R, G, B, white. | Strip follows. If only part of the strip/outputs react, record which (byte-7 selector hypothesis). If colors are permuted, suspect channel-order config (H9), not the frame. | |
| H6 | Wrong-layout check: send the *other* layout's power frame. | Record outcome. (Informative only; confirms layout choice matters.) | |
| H7 | Brightness at 10, 30, 50, 70, 100 %. Compare visually and repeat with a round-based scale byte (temporary build). | Smooth monotonic change. Note any visible difference between floor and round for 30 %. | |
| H8 | Effects 1, 3, 72, then 73, 100, 210, 255. Record what plays. Repeat on a known `-03` vs non-`-03` if both exist. | Ids 1–72 match `dmx_model.tsv` names. Ids ≥ 73 may differ from the table. Record the true behavior. | |
| H9 | Pixel count / color order. Compare strip behaviour with vendor-app settings. | Record what the vendor app had configured; only then decide whether the config frame is needed. | |
| H10 | Write burst: 20 color changes at 50 ms, 30 ms, 100 ms gaps, each platform. | All apply in order, none dropped, no disconnect. Record the smallest reliable gap per platform. | |
| H11 | Pull power / walk out of range mid-write, then return. | Library reports a failure (no silent success). Reconnect works. | |
| H12 | Parity: repeat H4–H8 on Windows and Android. | Same visible results. | **Blocked:** Windows debug build currently fails inside `bluetooth_low_energy_windows` / `permission_handler_windows` (MSVC 14.51 `/await` deprecation). |
| H13 | App-only checks on Android: connect (no frame written), `GATT TRANSPORT RESULT`, notification enable, then 10× command presses with logs. | `COMMAND …`/`RESULT …` pairs with the expected hex; failed/timed-out writes reported as `FAILED`; no automatic frames at any point; link stays open between presses. | |
| H14 | Link loss during a command (walk out of range / power off the strip). | `FAILED` result for the in-flight command, `CONNECTION LOST` state, controls disabled, **no** automatic reconnect. Reconnect must be a new manual scan. | |

## Sign-off rule
A capability's `Evidence` may be raised from `decompiledApp` to `hardwareConfirmed` only when the matching rows pass on **both** Windows and Android.
