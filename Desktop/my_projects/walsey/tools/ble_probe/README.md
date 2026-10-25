# ble_probe

Read-only BLE discovery and GATT inspection for Walsey LED controllers. The
probe never reads characteristic values, writes characteristics or descriptors,
sends handshakes, subscribes to notifications, or issues LED commands.

## Structure

- `lib/ble/ble_port.dart` — plugin-free `BleCentral` port and data transfer
  objects. No write API exists by design.
- `lib/ble/plugin_central.dart` — `bluetooth_low_energy` 6.2.1 adapter,
  including Android runtime permissions and plugin authorization.
- `lib/ble/gatt_profile.dart` — pure FFE0/FFE1 validation. FFE2 is recorded but
  not required.
- `lib/ble/led_probe_service.dart` — scan/connect/disconnect state machine.
  One automatic connect per scan, one connection attempt at a time,
  scan-result deduplication, a persistent link after successful FFE0/FFE1
  validation, and no automatic reconnect or retry loop.
- `lib/main.dart` — UI only: scan, connect, connected status, Disconnect.

## Run on Android

Enable Bluetooth and grant the Nearby-devices permission when prompted. Force
close the vendor app first (these controllers normally accept one connection),
then:

```text
flutter pub get
flutter run
```

The on-screen log and terminal contain timestamped entries prefixed with
`[WalseyBleProbe]`. Android Logcat uses the tag `WalseyBleProbe`:

```text
adb logcat -s WalseyBleProbe:D
```

In Android Studio, open **View > Tool Windows > Logcat**, select the device and
the `ble_probe` process, and filter for `WalseyBleProbe`. Logs include scan and
connection lifecycle, advertised service UUIDs, GATT services and
characteristic properties, permission/Bluetooth-state diagnostics, errors with
stack traces, and disconnections. No characteristic payloads or LED commands
are logged or sent.

## Connection behaviour

A scan auto-connects to the preferred controller at most once. After FFE0/FFE1
validate, the link stays open: the UI shows `Connected …` and the log contains
`CONNECTED: keeping the BLE link open until Disconnect, link loss or app
disposal`. Scanning is refused while connected; only **Disconnect** (or link
loss / app disposal) releases the link. If the connection is lost, the probe
shows a `CONNECTION LOST` error and does **not** reconnect automatically.

Connect attempts are logged with their origin:

```text
CONNECT REQUEST origin=auto (scan #1)
CONNECT REQUEST origin=manual
CONNECT REQUEST IGNORED: already connected
```

If more than one connect attempt appears for a single user scan, the origin tag
identifies the trigger. There is no timer, retry loop, or automatic scan restart
in the service or adapter.

## Verify without hardware

```text
flutter analyze
flutter test
```

The GATT and service tests use pure data and a fake central; they do not touch
Bluetooth. Successful transport validation means FFE0/FFE1 are compatible — it
does **not** mean the controller accepts frames or that LED control works.
