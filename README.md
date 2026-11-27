# Walsey

Offline LED control and an offline voice assistant for a Bluetooth "LED DMX"
neon controller (vendor app: LED LAMP), built as reusable Dart/Flutter packages
plus Flutter apps for Windows and Android.

Two tracks live here:

- **LED / BLE** — protocol research, validated value objects, pure 9-byte frame
  encoders, a serialised write queue, a typed driver, a BLE transport package,
  the main app, and the frozen Stage 1 read-only probe.
- **Voice** — a pure-Dart deterministic parser and command registry, an offline
  speech adapter (whisper.cpp primary, Vosk fallback), a voice testbed, and
  hold-to-talk + plan execution wired into the main app.

The most important honesty rule: **no LEDDMX frame has ever been sent to the
target controller.** Android BLE connectivity alone was hardware-confirmed on
2026-10-23 (`LEDDMX-03-6B4A`). Frame layouts remain `decompiledApp` evidence
until the rows in `docs/hardware_checklist.md` pass on both Windows and Android.
The protocol has **no state read-back**, so the app never claims a device state.

## Documentation

Start at [`docs/README.md`](docs/README.md). It is the index, with a reading
order for each track.

| Area | Where |
|---|---|
| How the system works | [`docs/how-it-works/`](docs/how-it-works/README.md) |
| LED protocol and hardware evidence | [`docs/research.md`](docs/research.md), [`docs/hardware_checklist.md`](docs/hardware_checklist.md) |
| Package boundaries and APIs | [`docs/architecture.md`](docs/architecture.md) |
| Voice Stage 1 (parser, registry) | [`docs/voice_stage1.md`](docs/voice_stage1.md) |
| Voice Stage 2 (recognition) | [`docs/voice_stage2.md`](docs/voice_stage2.md) |
| Measured accuracy and reliability | [`docs/voice_accuracy.md`](docs/voice_accuracy.md), [`docs/voice_assistant_report.md`](docs/voice_assistant_report.md) |
| Wake word status and benchmarks | [`docs/wake_word.md`](docs/wake_word.md) |
| Planned features and implementation plans | [`docs/planned/`](docs/planned/README.md) |
| Running the main app + first hardware test | [`apps/walsey/README.md`](apps/walsey/README.md) |
| Running the voice testbed | [`apps/walsey_voice_test/README.md`](apps/walsey_voice_test/README.md) |

## Packages

| Path | What | Current state |
|---|---|---|
| `walsey_led_core/` | Pure Dart: value objects, sealed `LedCommand`, variant resolution, 9-byte encoders, `LedTransport` port, serialised `WriteQueue`, typed `LeddmxDriver` | Complete, `dart test` green |
| `walsey_led_ble/` | Flutter package: `BleCentral` port, `bluetooth_low_energy` adapter + Android permissions, `PluginLedTransport` writing complete frames to FFE1 | Complete, unit tests green |
| `apps/walsey/` | Main app: scan → connect → validate FFE0/FFE1 → explicit commands, hold-to-talk Assistant with plan execution, Devices/Studio/Activity/Settings, honest planned pages | Complete, Android + Windows debug builds pass |
| `walsey_voice_core/` | Pure Dart voice: normalization, deterministic parser, sealed intents/parameters/results, `CommandRegistry` allowlist, plan parser, `SpeechRecognizer` port | Complete, `dart test` green |
| `walsey_voice_speech/` | Flutter voice adapter: whisper.cpp through `dart:ffi` in a worker isolate (primary), Vosk fallback, `record` capture, explicit model install, VAD + wake pipeline | Complete, unit tests green; wake backend not shipped |
| `apps/walsey_voice_test/` | Flutter voice testbed: speak or type, inspect the same parser's interpretation; no BLE, no execution | Complete, widget tests green |
| `tools/ble_probe/` | Stage 1 read-only scan + GATT inspector. Sends no frames and does not depend on the Stage 2 packages | Frozen reference |
| `tools/voice_intent_ml/` | Python audio feature extraction (log-Mel); no classifier yet | Phase 1 |

### Track status

| Track | Done | Not done / blocked |
|---|---|---|
| LED protocol + transport | Research, encoders, driver, queue, BLE package, Windows/Android app builds | **No frame sent to hardware.** Windows BLE unrun. `hardwareConfirmed` raises only after the checklist passes on both platforms |
| Voice input | Parser/registry, offline Whisper + Vosk, hold-to-talk, preview + typed input | No human-speech accuracy run through the Assistant; Android capture/model installs unverified |
| Voice execution | Plans over the real `LedConnectionService`, step-by-step, stop-on-failure | Real LED response unverified (same no-frame-on-hardware rule) |
| Hands-free / wake word | Detector ports, VAD, pre-roll → decode loop, opt-in app wiring, Android FGS shell | **No trained "Walsey" model and no ONNX scorer ships.** Measured Vosk approach: 0/36 positives. See [`docs/planned/onnx-wake-word.md`](docs/planned/onnx-wake-word.md) |
| Scenes / Automations / Phone↔PC / Music / Segments | Honest placeholder pages and investigations | Not implemented; plans in [`docs/planned/`](docs/planned/README.md) |

## Verification status

Run Flutter commands **sequentially** — parallel runs race on the shared Flutter
cache. Counts below were re-run on 2026-11-27 unless a different date is shown.

| Check | Status |
|---|---|
| `walsey_led_core`: `dart analyze` / `dart test` | **PASS:** clean, **57/57 tests** |
| `walsey_led_ble`: `flutter analyze` / `flutter test` | **PASS:** clean, **7/7 tests** |
| `walsey_voice_core`: `dart analyze` / `dart test` | **PASS:** clean, **191/191 tests** |
| `walsey_voice_speech`: `flutter analyze` / `flutter test` | **PASS:** clean, **229/229 tests** (fakes + loopback HTTP; no microphone, model or internet) |
| `apps/walsey`: `flutter analyze` / `flutter test` | **PASS:** clean, **143/143 tests** |
| `apps/walsey_voice_test`: `flutter analyze` / `flutter test` | **PASS:** clean, **21/21 widget tests** |
| `tools/ble_probe`: `flutter analyze` / `flutter test` | **PASS:** clean, **30 pass + 1 skipped** (widget test needs physical BLE) |
| `tools/voice_intent_ml`: Python tests | **PASS (2026-11-25):** 72 tests; log-Mel feature extraction only, no labeled corpus or classifier |
| `apps/walsey`: Android debug APK | **PASS (2026-11-04):** 213 MB debug APK with `libwhisper.so`, `libggml*.so`, `libvosk.so` for all three ABIs and the microphone foreground service |
| `apps/walsey`: Windows debug build | **PASS (2026-11-06)** with `nuget.exe` on `PATH` and the app-side `/await` CMake workaround for two BLE plugins |
| `apps/walsey_voice_test`: Windows / Android debug builds | **PASS (2026-10-26)** |
| BLE connection + GATT discovery | **Android hardware-confirmed (2026-10-23)** with the Stage 1 probe: FFE0 + FFE1 read/write/writeWithoutResponse/notify, FFE2 notify-only. The Stage 2 app reuses the adapter but has not been run on hardware |
| Command API, first frame, LED response | **UNKNOWN.** No LEDDMX frame has been transmitted. Unit tests prove frame construction and serialisation, not device behaviour |
| Windows BLE | **NOT RUN against a controller.** Windows remains a build target, not a hardware-validated platform |
| Microphone capture | **PARTIAL.** Windows recording was measured (16 kHz mono PCM16, tail intact, ambient audio at −11.45 dBFS). No spoken command through the Assistant; Android capture, permissions, FGS and a real model download are unverified |
| Wake word | **BLOCKED.** Pipeline and opt-in wiring exist; no model/backend ships. Assistant reports `notConfigured` |

Build dates are the last measured runs. The worktree currently adds an unused,
untracked `sherpa_onnx` dependency and KWS model assets for the planned wake
word (see [`docs/planned/onnx-wake-word.md`](docs/planned/onnx-wake-word.md)).
No APK or Windows build has been re-measured with them, so re-run the builds and
re-check the packaged native libraries before quoting APK/exe size or shipping
that dependency.

Unit tests are not hardware proof. See
[`docs/hardware_checklist.md`](docs/hardware_checklist.md) for the sign-off
rule and every required row.

## Commands

There is no workspace manifest; run commands inside each package.

```bash
# LED core: pure Dart, no hardware
cd walsey_led_core
dart pub get
dart analyze
dart test                     # 57 tests

# BLE transport: fake central, no hardware
cd ../walsey_led_ble
flutter pub get
flutter analyze
flutter test                  # 7 tests

# Main app
cd ../apps/walsey
flutter pub get
flutter analyze
flutter test                  # 143 tests
flutter run -d <android-device-id>
adb logcat -s flutter:D       # app diagnostics are tagged [WalseyApp]
flutter build windows --debug # needs nuget.exe on PATH

# Stage 1 probe: read-only, sends no frames
cd ../../tools/ble_probe
flutter analyze
flutter test                  # 30 pass, 1 skipped

# Voice core: pure Dart
cd ../../walsey_voice_core
dart pub get
dart analyze
dart test                     # 191 tests

# Voice speech adapter
cd ../walsey_voice_speech
flutter pub get
flutter analyze
flutter test                  # 229 tests

# Voice testbed
cd ../apps/walsey_voice_test
flutter pub get
flutter analyze
flutter test                  # 21 widget tests

# Windows speech needs the native libraries and a model once (explicit, gitignored):
powershell -ExecutionPolicy Bypass -File ../../tools/fetch_whisper_windows.ps1
powershell -ExecutionPolicy Bypass -File ../../tools/fetch_vosk_windows.ps1   # fallback

# Android whisper.cpp from source, once (NDK + SDK cmake/ninja):
powershell -ExecutionPolicy Bypass -File ../../tools/build_whisper_android.ps1
```

Android is the hardware-testing platform today. The Windows LED build needs
`nuget.exe` for `flutter_tts` and the checked-in CMake workaround for
`bluetooth_low_energy` / `permission_handler` compiling C++/WinRT coroutines as
C++17. Full details are in
[`docs/how-it-works/development.md`](docs/how-it-works/development.md).

## Safety rules the code enforces

- No frame is ever sent automatically — the handshake included. Every frame
  needs a deliberate user action (a button press, an explicit plan from a take,
  or an explicitly started automation once that exists).
- Scans are refused while connected; one connection attempt at a time; the link
  stays open after validation until an explicit disconnect, link loss or
  disposal. No connect timer, retry loop, auto-reconnect or auto-disconnect.
- All writes are serialised with a ≥ 50 ms gap and a 5 s timeout. A timed-out
  write blocks further writes until reattach.
- Write failures, timeouts and disconnects are surfaced per command. Nothing is
  reported as success without a completed write.
- The app never claims device state: it reports the last frame sent and the
  manual observation a human recorded.
- Recognition, interpretation and execution stay separate. A parser failure
  never reaches the executor, typed input is interpreted only, and a transcript
  is never "cleaned up" to make it pass.
- Wake word, background listening and music-reactive modes have no fake
  controls: when the required model or backend is absent, the UI says so.
