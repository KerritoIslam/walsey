# Walsey LED Control

Reusable Dart/Flutter packages for controlling a Bluetooth "LED DMX" neon
controller (vendor app: LED LAMP) from Flutter Windows and Android apps.

**Current stage: 2 of 4** for the LED track. Stage 1 (research, frame encoders,
validation, read-only BLE probe) is done. Stage 2 adds the typed command driver,
the BLE transport package and the main app — **but no frame has been sent to a
real controller yet.** BLE transport connectivity is hardware-verified on Android
(2026-10-23); frame acceptance and LED control are not. Read `docs/research.md`
before touching protocol code.

A separate **voice assistant** track now exists: `walsey_voice_core` (offline
text → intent + the speech port), `walsey_voice_speech` (offline whisper.cpp
with a Vosk fallback, model setup) and `apps/walsey_voice_test` (speech/typed
interpretation UI). The main app adds hold-to-talk that plans and (only when
valid) executes commands. Recognition is offline, model downloads are explicit,
and nothing is executed in either voice package;
see `docs/voice_stage1.md` and `docs/voice_stage2.md`.

| Doc | Contents |
|---|---|
| `docs/research.md` | Sources, variant analysis, evidence levels, uncertainties |
| `docs/architecture.md` | Package layout, API shape, dependencies |
| `docs/hardware_checklist.md` | What must be tested on the real device |
| `docs/voice_stage1.md` | Voice Stage 1: command grammar, validation, registry, testing UI |
| `docs/voice_stage2.md` | Voice Stage 2: Whisper/Vosk decision, offline semantics, models, manual checklist |
| `docs/voice_accuracy.md` | Measured recognition accuracy, decoder bias, fallback comparison |
| `docs/voice_assistant_report.md` | Hold-to-talk fix, failure analysis, wake word, background listening, builds |
| `docs/wake_word.md` | Wake-word benchmarks and why detection stays disabled |
| `docs/music_mode.md`, `docs/led_segments.md` | Analysed-but-unsupported features |
| `apps/walsey/README.md` | How to run the app and the controlled first hardware test |

## Packages

| Path | What | State |
|---|---|---|
| `walsey_led_core/` | Pure Dart: value objects, sealed `LedCommand`, variant resolution, 9-byte encoders, `LedTransport` port, serialised `WriteQueue`, typed `LeddmxDriver` | Stage 2 code complete, `dart test` green |
| `walsey_led_ble/` | Flutter package: `BleCentral` port, `bluetooth_low_energy` adapter + Android permissions, `PluginLedTransport` (writes complete 9-byte frames to FFE1) | Stage 2 code complete, unit tests green |
| `apps/walsey/` | Main app: scan → connect → validate FFE0/FFE1 → explicit commands (power, RGB, brightness, effects), hold-to-talk assistant, devices/studio/settings UI | Stage 2 code complete, Android APK builds |
| `walsey_voice_core/` | Pure Dart voice: normalization, deterministic parser, sealed intents/parameters/results, command registry, `SpeechRecognizer` port | Stages 1–2 code complete, `dart test` green |
| `walsey_voice_speech/` | Flutter voice adapter: whisper.cpp FFI in a worker isolate (primary) with a Vosk fallback, `record` capture, explicit model download/extract, two disabled wake-word detectors | Stage 2 code complete, unit tests green |
| `apps/walsey_voice_test/` | Flutter voice testbed: speak offline or type, inspect intent/parameters/validation; no BLE and no execution | Stage 2 code complete, widget tests green |
| `tools/ble_probe/` | Stage 1 read-only probe. Frozen as a reference; it sends no frames and does not depend on the new packages | Unchanged |

## Verification status (be honest about this)

| Check | Status |
|---|---|
| Expected frame bytes in tests vs. an independent Python model of the spec | **19/19 agree** (run in authoring sandbox) |
| `walsey_led_core`: `dart analyze` / `dart test` | **PASS (2026-10-24):** analysis clean, **57/57 tests** pass |
| `walsey_led_ble`: `flutter analyze` / `flutter test` | **PASS (2026-10-24):** analysis clean, **7/7 tests** pass |
| `apps/walsey`: `flutter analyze` / `flutter test` | **PASS (2026-11-06):** analysis clean, **128/128 tests** pass |
| `apps/walsey`: Android debug APK | **PASS (2026-11-04):** `flutter build apk --debug` → 213 MB debug APK; contains `libwhisper.so`, `libggml*.so` and `libvosk.so` for all three ABIs, plus the microphone foreground service |
| `walsey_voice_core`: `dart analyze` / `dart test` | **PASS (2026-11-06):** analysis clean, **154/154 tests** pass |
| `walsey_voice_speech`: `flutter analyze` / `flutter test` | **PASS (2026-11-06):** analysis clean, **213/213 tests** pass (fake engine/capture, loopback HTTP; no microphone or internet) |
| `apps/walsey_voice_test`: `flutter analyze` / `flutter test` | **PASS (2026-11-06):** analysis clean, **21/21 widget tests** pass |
| `apps/walsey_voice_test`: Android debug APK | **PASS (2026-10-26):** contains `lib/{arm64-v8a,armeabi-v7a,x86_64}/libvosk.so` and the whisper JNI libs; declares `RECORD_AUDIO`, `INTERNET`, minSdk 24 |
| `apps/walsey_voice_test`: Windows debug build | **PASS (2026-10-26):** `flutter build windows --debug` → `build/windows/x64/runner/Debug/walsey_voice_test.exe`; the Vosk DLLs and `models/ggml-base.en.bin` are copied next to the exe, and the build also succeeds when `windows/vosk/` is absent (speech then reports a native-library error) |
| `apps/walsey`: Windows debug build | **PASS (2026-11-06)** with `nuget.exe` on `PATH` and the checked-in app-side CMake `/await` workaround for the BLE plugins |
| `tools/ble_probe`: `flutter analyze` / `flutter test` | **PASS (2026-10-24):** analysis clean, 30 tests pass + 1 skipped widget test |
| Speech recognition / microphone | **PARTIAL.** Windows capture was measured (16 kHz mono PCM16, tail intact, ambient audio at −11.45 dBFS); no person has spoken a command through the Assistant, and Android capture, permissions, the foreground service and a real model download remain **NOT TESTED**. Follow the checklist in `docs/voice_stage2.md` |
| BLE connection, GATT discovery, link stays open | **Hardware-confirmed on Android only (2026-10-23)** with the Stage 1 probe (`LEDDMX-03-6B4A`: FFE0 + FFE1 read/write/writeWithoutResponse/notify, FFE2 notify-only). The Stage 2 app reuses the same adapter logic but has **not** been run against hardware |
| Command API on hardware, first-frame behaviour, LED response | **UNKNOWN.** No LEDDMX frame has been transmitted. Unit tests prove frame construction and serialisation, never device behaviour |
| Windows BLE | **NOT RUN against a controller.** The app's Windows build now passes with the `/await` workaround; Android remains the hardware-testing platform |

Unit tests are not hardware proof. A capability's `Evidence` stays
`decompiledApp` until the matching rows in `docs/hardware_checklist.md` pass on
**both** Windows and Android.

## Commands

There is no workspace manifest; run commands inside each package.

```bash
# 1. Core: pure Dart, no hardware
cd walsey_led_core
dart pub get
dart analyze
dart test                     # 57 tests

# 2. BLE transport package: fake central, no hardware
cd ../walsey_led_ble
flutter pub get
flutter analyze
flutter test                  # 7 tests

# 3. Main app
cd ../apps/walsey
flutter pub get
flutter analyze
flutter test                  # 128 tests
flutter run -d <android-device-id>
adb logcat -s flutter:D       # diagnostics are tagged [WalseyApp]

# 4. Stage 1 probe (read-only; sends no frames)
cd ../../tools/ble_probe
flutter analyze
flutter test                  # 30 pass, 1 skipped

# 5. Voice: pure Dart core, Flutter adapter, testbed
cd ../../walsey_voice_core
dart pub get
dart analyze
dart test                     # 154 tests
cd ../walsey_voice_speech
flutter pub get
flutter analyze
flutter test                  # 213 tests
cd ../apps/walsey_voice_test
flutter pub get
flutter analyze
flutter test                  # 21 widget tests

# Windows speech needs the native DLLs and the model once (explicit, gitignored):
powershell -ExecutionPolicy Bypass -File ../../tools/fetch_whisper_windows.ps1
powershell -ExecutionPolicy Bypass -File ../../tools/fetch_vosk_windows.ps1   # fallback
```

Run Flutter commands **sequentially**; parallel runs race on the shared Flutter
build cache.

## Safety rules the code enforces

- No frame is ever sent automatically — the handshake included. The vendor app
  authenticates ~300 ms after connecting; this project requires a deliberate
  button press for every frame.
- Scans are refused while connected; one connection attempt at a time; the link
  stays open after validation until an explicit disconnect, link loss or
  disposal. No connect timer, retry loop, auto-reconnect or auto-disconnect.
- All writes are serialised with a ≥ 50 ms gap and a 5 s timeout; a timed-out
  write blocks further writes until reconnect.
- Write failures, timeouts and disconnects are surfaced per command. Nothing is
  reported as success without a completed write.
- The app never claims device state: it reports the last frame sent and the
  manual observation you record.
