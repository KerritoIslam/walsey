# AGENTS.md

## Project

Walsey Stage 2: pure-Dart protocol core, a BLE transport package, the main
Flutter app, and the frozen Stage 1 read-only probe, for a Bluetooth "LED DMX"
controller. Voice and scenes do not exist yet (see `docs/architecture.md`).

- `walsey_led_core/` — pure Dart package: validated value objects, sealed
  `LedCommand`, LEDDMX variant resolution, 9-byte frame encoders, plus the Stage 2
  `LedTransport` port, serialised `WriteQueue` and typed `LeddmxDriver`. Must stay
  free of Flutter and BLE plugins so `dart test` works.
- `walsey_led_ble/` — Flutter package implementing transport: `lib/src/ble_port.dart`
  (port + DTOs), `lib/src/plugin_central.dart` (`bluetooth_low_energy` adapter +
  Android permissions), `lib/src/gatt_profile.dart` (pure FFE0/FFE1 validation),
  `lib/src/plugin_led_transport.dart` (`LedTransport` over FFE1, 9-byte check).
  Deliberately a copy of the probe's port/adapter shape, extended with writes and
  notifications. Do not make the probe depend on it.
- `walsey_voice_core/` — pure Dart voice Stage 1: normalization, deterministic
  text→`VoiceIntent` parser, sealed parameters/results and the `CommandRegistry`
  allowlist, plus the Stage 2 `SpeechRecognizer` port and session events. No
  Flutter, BLE, microphone, network, LLM or execution.
- `walsey_voice_speech/` — Flutter voice Stage 2 adapter: Vosk C API through
  hand-written `dart:ffi` in a worker isolate, `record` microphone capture,
  explicit model download/extract, and the single-session
  `PushToTalkController`. Must not import `walsey_led_core`/`walsey_led_ble`,
  copy the parser, or execute commands.
- `apps/walsey_voice_test/` — Flutter voice testbed: speak (offline Vosk) or
  type, then inspect the same parser's interpretation. Imports only the two
  voice packages (no BLE), so it also builds on Windows.
- `apps/walsey/` — main app: `lib/connection/led_connection_service.dart`
  (scan/connect/validate/disconnect state machine + driver binding),
  `lib/control/led_control_service.dart` (typed UI facade + logging),
  `lib/ui/` (Connection, Controls, Hardware test, log pane). See its README for
  the controlled first-hardware-test procedure.
- `tools/ble_probe/` — Stage 1 Flutter Windows/Android scan + GATT inspector. It
  never writes characteristics/descriptors, reads values, or subscribes to
  notifications. Keep it read-only and unchanged.
- `docs/` — protocol research, architecture, and the hardware checklist. Read
  `docs/research.md` before protocol changes.

## Commands

There is no workspace manifest; run commands inside each package. Run Flutter
commands **sequentially** — parallel runs race on the shared Flutter cache.

```bash
cd walsey_led_core
dart pub get
dart analyze                         # clean as of 2026-10-24
dart test                            # 57 tests pass as of 2026-10-24
dart test test/leddmx_frames_test.dart
dart test -n "filler scaling"
```

```bash
cd walsey_led_ble
flutter pub get
flutter analyze                      # clean as of 2026-10-24
flutter test                         # 7 tests pass as of 2026-10-24
```

```bash
cd apps/walsey
flutter pub get
flutter analyze                      # clean as of 2026-10-24
flutter test                         # 13 tests pass as of 2026-10-24
flutter build apk --debug            # PASS as of 2026-10-24
flutter run -d <android-device-id>
adb logcat -s flutter:D              # app diagnostics are tagged [WalseyApp]
flutter build windows --debug        # FAILS in third-party plugin code (see below)
```

```bash
cd tools/ble_probe
flutter pub get
flutter analyze                      # clean as of 2026-10-24
flutter test                         # 30 pass, 1 skipped (widget_test) as of 2026-10-24
flutter run -d <android-device-id>
adb logcat -s WalseyBleProbe:D       # Android diagnostic tag
```

```bash
cd walsey_voice_core
dart pub get
dart analyze                         # clean as of 2026-10-24
dart test                            # 124 tests pass as of 2026-10-24
dart test test/parser_safety_test.dart

cd ../walsey_voice_speech
flutter pub get
flutter analyze                      # clean as of 2026-10-24
flutter test                         # 68 tests pass as of 2026-10-25

cd ../apps/walsey_voice_test
flutter pub get
flutter analyze                      # clean as of 2026-10-24
flutter test                         # 21 widget tests pass as of 2026-10-25
flutter run -d <device-id>           # speech needs a mic + one explicit model install

# Windows native Vosk DLLs (explicit, once, gitignored):
powershell -ExecutionPolicy Bypass -File ../../tools/fetch_vosk_windows.ps1
flutter build windows --debug
```

No CI, formatter config, codegen, or root test runner. `flutter create` was
already run for `tools/ble_probe` and `apps/walsey`; rerunning it can overwrite
the runner files. `test` and `lints` are already in `walsey_led_core/pubspec.yaml`,
so skip the README's `dart pub add` step.

**Known environment blocker (LED app, not voice):** `flutter build windows
--debug` fails in `apps/walsey` inside `bluetooth_low_energy_windows` and
`permission_handler_windows` (MSVC 14.51 rejects the experimental `/await`
coroutine headers). It reproduces identically in the untouched probe, so it is a
toolchain/plugin issue, not app code. Do not "fix" it by patching the pub cache.
The voice testbed does not use those plugins: `flutter build windows --debug`
PASSes there (2026-10-24) with `record_windows` + the Vosk DLLs next to the exe.
Android is the hardware-testing platform.

## Protocol and evidence rules

- Every frame layout is decompiled-app evidence (LED_UNION, MIT), **not**
  observed on this target controller. Raise `Evidence.decompiledApp` to
  `hardwareConfirmed` only after the matching `docs/hardware_checklist.md` rows
  pass on **both** Windows and Android.
- Frames are always 9 bytes, `7B … BF`, no checksum, never fragmented. The
  handshake (`2A 02 … AF`) must precede commands; the protocol has **no state
  read-back**, so never add APIs or docs that claim confirmed device state.
  "BLE write OK" ≠ "the LEDs changed".
- Layout is chosen only from an advertised `LEDDMX-NN[-suffix]` name:
  `00/01/03` → filler, `02/04` → shifted. `"LED DMX"`, LEDBLE/LEDCAR names, and
  unknown numbers must remain `UnsupportedVariant`; do not loosen the regex.
- Documented unknowns are intentionally pinned: brightness scaling uses floor
  (`(v*32) ~/ 100`, not round); shifted RGB sends white `0`; effect ids ≥ 73 are
  variant-dependent. Do not silently "fix" these — update the comment,
  `docs/research.md`, the relevant hardware-checklist item, and tests together.
- Encoders are pure free functions: keep I/O, handshake timing, pacing, and
  queueing out of the frame encoders. Writes go through `WriteQueue` (serial,
  ≥ 50 ms gap, 5 s timeout, block-after-timeout until reattach).
- Never send a frame automatically. The handshake is an explicit user action in
  this project even though the vendor app does it on connect.
- Probe connection rules: one auto-connect per scan; one connection attempt at a
  time; the link stays open after FFE0/FFE1 validation until an explicit
  `disconnect()`, link loss, or `dispose()`. Never add a connect timer, retry
  loop, automatic rescan/reconnect, or auto-disconnect after validation. Scan
  must be refused while connected. The app's
  `led_connection_service.dart` keeps the same rules (it refuses scans while
  connected and tags connection attempts); logs tag attempts
  `origin=auto (scan #N)` / `origin=manual` in the probe.
- The app enables FFE1 notifications after validation (receive-only, used for the
  password-status reply). Do not treat other notifications as command
  acknowledgements.
- Handshake password bytes must stay redacted in logs/UI
  (`2a 02 ** ** ** ** <tb> <min> af`).

## Voice Stage 1 rules

- The voice core stays pure Dart: no Flutter, BLE, speech plugin, network, LLM or
  `walsey_led_core` dependency. A future adapter maps `VoiceColor` →
  `RgbColor`, `VoiceBrightness` → `BrightnessLevel`, `VoiceEffect` → `LedEffect`.
- Parsing is never execution. `VoiceResult.executionStatus` stays
  `notExecuted`; no executor exists in either voice package.
- Only intents present in `CommandRegistry` may become valid commands; the
  registry is the authorization allowlist.
- Do not invent colours, effect names, effect ids or brightness values.
  Brightness is a whole 0..100 percent and is never clamped. Effects are the
  documented ids 1..210/255 only. Relative brightness/effect selection needs
  device state the protocol cannot read — keep it recognized but unexecutable.
- Negated, question, statement, contradictory, compound and unregistered-domain
  sentences stay explicit failures. Do not add fuzzy guessing.

## Voice Stage 2 rules

- Engine is Vosk (Apache License 2.0), called through hand-written `dart:ffi`
  in `walsey_voice_speech/lib/src/vosk/`. Do not replace it with a cloud/paid
  recognizer or add a mandatory network fallback. A different engine must
  implement the core `SpeechRecognizer` port and keep typed input working.
- Recognition is offline once a model is installed. Nothing is downloaded
  implicitly: `ModelStore.install` runs only from the explicit model-manager
  action, with no startup prefetch, retry loop or background download. The
  catalogue is verified (id, archive size, published MD5, licence); adding an
  entry requires checking all four against Alpha Cephei's published list.
- Recognition outcomes (`empty`, `cancelled`, permission, model, native-library,
  platform/language) and parser outcomes (`unsupported`, `invalidParameter`,
  `ambiguous`, …) stay separate. Never loosen the parser so a poor transcription
  "passes"; a recognized sentence may legitimately end as a parser failure.
- One session at a time, started only by explicit user action (tap-to-start /
  tap-to-stop). Stop, cancel and dispose close the microphone; a 10 s watchdog
  prevents a hung engine from pinning the UI. No wake word, no auto-start, no
  background listening.
- The voice testbed must not import `walsey_led_ble` or `walsey_led_core`, and
  no voice code path may send a frame. Typed input must keep working when the
  microphone, model or native library is unavailable.
- Android ships the native library via
  `implementation("com.alphacephei:vosk-android:0.3.75@aar")` and declares
  `RECORD_AUDIO` (plus `INTERNET` only for the explicit model download).
  Windows needs `tools/fetch_vosk_windows.ps1`; the DLLs are gitignored and
  copied next to the exe by `windows/runner/CMakeLists.txt`. Never commit model
  archives or DLLs.

## Tests

- Expected bytes in `leddmx_frames_test.dart` are hand-written from the spec, not
  computed with the encoder. Preserve that property; add literal `hex()` strings
  for new frames rather than deriving expectations from implementation logic.
- Value objects validate in their constructors and throw `InvalidCommandException`
  (channels 0..255, brightness 0..100, effect 1..210 or 255). Tests assert this.
- `walsey_led_core/test/driver_and_queue_test.dart` covers serialisation, pacing,
  timeouts, variant refusal, write failures, redaction and the password reply.
  Its `FakeTransport` is in-memory.
- `walsey_led_ble/test/plugin_led_transport_test.dart` uses a fake `BleCentral`
  and asserts FFE1 routing, the 9-byte guard, error propagation and notify state.
- `apps/walsey/test/` covers connection guarantees (`led_connection_service_test`),
  command logging/redaction/single-flight (`led_control_service_test`) and the
  widget shell. A plain `testWidgets` body that creates/disposes a service hangs on
  fake-async stream futures — create and dispose it inside `tester.runAsync`.
- `tools/ble_probe/test/widget_test.dart` is skipped; real probe behavior needs
  physical BLE hardware. The service/state-machine tests use a fake `BleCentral`
  (`test/led_probe_service_test.dart`); GATT validation is pure
  (`test/gatt_profile_test.dart`).
- `walsey_voice_core/test/` is pure `dart test` (no microphone/network/hardware):
  normalization, power, colour, brightness, effect, safety/ambiguity and registry
  suites. Expectations are literal, not derived from the parser.
- `walsey_voice_speech/test/` must stay microphone-, native-library- and
  internet-free: `FakeEngine`/`FakeCapture` drive the recognizer, a fake
  `SpeechRecognizer` drives the controller, and model installs run against a
  loopback `HttpServer`. Do not add tests that need a model archive, a real
  `record` channel or the Vosk DLL.
- `apps/walsey_voice_test/test/widget_test.dart` covers typed Stage 1 flows;
  `test/speech_widget_test.dart` covers Stage 2 with a fake recognizer/model
  store, and must keep asserting that no execution control exists. The Stage 2
  page is taller than the default 800x600 surface: set `tester.view.physicalSize`
  before pumping or taps miss off-screen chips. Stream events need
  `pumpAndSettle`, and status text can appear both in the chip and on the button
  (use `findsWidgets`).
- Windows microphone capture **has** been exercised (2026-10-25): the production
  `record` path delivers 16 kHz mono PCM16 at the requested rate, with a ~750 ms
  first-chunk delay and no tail loss, but this machine's microphones return
  digital silence, so level/clipping could not be checked. Android capture and
  model download are still unexercised. Do not claim Android or real-speech
  accuracy results before the checklist in `docs/voice_stage2.md` passes.
- Measured accuracy (synthetic SAPI corpus, both Vosk configurations and
  whisper.cpp) is in `docs/voice_accuracy.md`; reproduce it with
  `walsey_voice_speech/bin/voice_accuracy.dart` and `tools/voice_accuracy/`.
  The shipped configuration stays `vosk-model-small-en-us-0.15` unconstrained;
  the constrained grammar is opt-in only because the invented wake word is not
  in the model vocabulary.
- Android BLE transport was confirmed on 2026-10-23 (`LEDDMX-03-6B4A`; FFE0 +
  FFE1 read/write/writeWithoutResponse/notify; FFE2 notify-only). Windows and
  **all** frame/LED-control claims remain unverified; no LEDDMX frame has been
  sent to hardware.

## Generated files

Do not hand-edit `tools/ble_probe/windows/flutter/ephemeral/**`,
`apps/walsey/windows/flutter/ephemeral/**`,
`apps/walsey_voice_test/windows/flutter/ephemeral/**`, `build/**`,
`.dart_tool/**`, `*.iml`, or generated plugin registrants. Real edit points are
`lib/`, `pubspec.yaml`, `analysis_options.yaml`,
`android/app/src/main/AndroidManifest.xml`, and
`android/app/build.gradle.kts`. `tools/ble_probe` consumes the core through a
path dependency (`../../walsey_led_core`); `apps/walsey` depends on both
`../../walsey_led_core` and `../../walsey_led_ble`; `apps/walsey_voice_test`
depends on `../../walsey_voice_core` and `../../walsey_voice_speech`. Do not
`flutter create` over the voice testbed runner files, and never commit
`windows/vosk/` (DLLs), model archives or `build/`.
