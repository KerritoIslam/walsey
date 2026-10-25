# Walsey app (Stage 2)

Main app: connect to the LEDDMX controller over BLE, validate FFE0/FFE1, then
send **one explicitly requested LEDDMX frame per button press**.

**No frame in this app has ever been sent to real hardware yet.** Everything
below the BLE connection itself is decompiled-app evidence
(`Evidence.decompiledApp`), not hardware-confirmed. The protocol has **no state
read-back**, so the app only ever reports "last command sent", never "the LEDs
are green now".

## Run it

Android is the only platform with verified BLE connectivity
(`LEDDMX-03-6B4A`, 2026-10-23). Windows currently does not build — see
"Known build blocker" below.

```bash
cd apps/walsey
flutter pub get
flutter analyze
flutter test

# Android (minSdk 24)
flutter devices                    # find the device id
flutter run -d <android-device-id>
# or build + install without attaching a debugger:
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Diagnostics: every line is printed as `[WalseyApp] <time>  <text>` and also
written with `developer.log(name: 'WalseyApp')`.

```bash
adb logcat -s flutter:D | Select-String WalseyApp     # PowerShell
adb logcat -s flutter:D | grep WalseyApp              # bash
```

The same lines appear in the log pane at the bottom of the app.

### Android setup

- `minSdk = 24` in `android/app/build.gradle.kts`.
- `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT`, and
  `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` for API ≤ 30 are declared in
  `android/app/src/main/AndroidManifest.xml`.
- Grant **Nearby devices** when asked. A permanently denied permission is
  reported in the log and opens app settings instead of silently failing.

## First hardware test (do it in this order)

1. Power the strip from the correct supply; confirm the vendor app (LED LAMP)
   still controls it.
2. **Force-close the vendor app.** These controllers typically accept one
   central at a time.
3. App → *Connection* → **Start scan** → tap `LEDDMX-03-6B4A`.
   Expected log: `SELECTED TARGET … layout=LeddmxLayout.filler`, then
   `GATT TRANSPORT RESULT: FFE0/FFE1 validated`, then
   `CONTROL API BOUND …`. No frame is written during connect.
4. App → *Hardware test*, press **Send** on one step at a time and watch the
   strip:

   | Step | Frame | Expected |
   |---|---|---|
   | 1. Authenticate | `2a 02 ** ** ** ** <tb> <min> af` (password redacted in logs) | No LED change; sets the controller clock |
   | 2. Password status | `2a 05 ff ff ff ff ff ff af` | Only documented reply; may print `wrongPassword`, `allSameDigits`, `resendRequested`, `unknown` or "no reply" |
   | 3. Power OFF | `7b 04 04 00 ff ff ff ff bf` | Strip turns off (never observed yet) |
   | 4. Power ON | `7b 04 04 01 ff ff ff ff bf` | Strip turns on |
   | 5. RED | `7b ff 07 ff 00 00 00 ff bf` | Strip turns red |

5. Tell the app what you saw (*LEDs changed* / *No visible change*) so it is in
   the log next to the write result. That entry is manual evidence and does not
   automatically raise the protocol's evidence level.
6. **If step 3 or 4 produces no change, stop.** Do not try random frames or the
   other layout. Capture the log and investigate `docs/research.md` first.
7. *ALL OFF* (bottom of the Hardware test tab) sends the same power-off frame and
   is always available as the escape hatch.

Controls tab: power, RGB presets + per-channel sliders, brightness 0–100 %
(filler layout sends `floor(v*32/100)`), effects by id (1–210, 255). Preset
effect names exist only for ids 3, 4 and 255 — the repository has no names for
the others, so no names are invented.

## Guarantees the app enforces

- One scan at a time, one connection attempt at a time; scanning is refused
  while connected.
- The link stays open after validation until *Disconnect*, link loss, or app
  exit. No connect timer, retry loop, automatic rescan or auto-reconnect.
- No frame is sent automatically, not even the handshake.
- Commands are serialised (one in flight, ≥ 50 ms gap, 5 s write timeout; a
  timed-out write blocks further writes until reconnect).
- Writes use `withResponse`, matching the vendor app's default.
- A write failure or timeout is reported as `FAILED`, never as success.
- Controls stay disabled for any advertised name that is not a documented
  `LEDDMX-NN` variant; a `FAIL:` GATT finding aborts the connection.

## Known build blocker (Windows)

`flutter build windows --debug` fails inside third-party plugin code, not in this
app:

```
experimental\coroutine(37,1): error C2338: static assertion failed: 'error STL1011:
The /await compiler option ... are deprecated by Microsoft and will be REMOVED SOON'
  [build\windows\x64\plugins\bluetooth_low_energy_windows\...vcxproj]
  [build\windows\x64\plugins\permission_handler_windows\...vcxproj]
```

Reproduced identically in the untouched Stage 1 `tools/ble_probe` with the same
MSVC toolset (14.51) and `bluetooth_low_energy 6.2.1`, so it predates this app.
Windows BLE was never hardware-verified either; use Android for hardware tests.
