# Development: commands, native setup and test pitfalls

The root [`../../README.md`](../../README.md) has the short command list. This
document covers the details that repeatedly matter.

## 1. General rules

- There is no workspace manifest. `cd` into the package and run its commands
  there.
- Run Flutter commands **sequentially**. Parallel Flutter runs race on the shared
  build cache and produce confusing failures.
- Do not hand-edit generated files: `.dart_tool/**`, `build/**`, `*.iml`,
  `windows/flutter/ephemeral/**`, plugin registrants.
- Real edit points are `lib/`, `pubspec.yaml`, `analysis_options.yaml`,
  `android/app/src/main/AndroidManifest.xml` and
  `android/app/build.gradle.kts`.
- `flutter create` was already run for the apps; rerunning it can overwrite
  runner files. Do not run it over the voice testbed.

## 2. Package commands

```bash
cd walsey_led_core
dart pub get
dart analyze
dart test

cd ../walsey_led_ble
flutter pub get
flutter analyze
flutter test

cd ../apps/walsey
flutter pub get
flutter analyze
flutter test
flutter run -d <android-device-id>
adb logcat -s flutter:D

cd ../../tools/ble_probe
flutter pub get
flutter analyze
flutter test

cd ../../walsey_voice_core
dart pub get
dart analyze
dart test

cd ../walsey_voice_speech
flutter pub get
flutter analyze
flutter test

cd ../apps/walsey_voice_test
flutter pub get
flutter analyze
flutter test
```

Useful focused runs:

```bash
dart test test/leddmx_frames_test.dart
dart test -n "filler scaling"
flutter test test/assistant_recording_test.dart
```

## 3. Builds

### Android

```bash
cd apps/walsey
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

`minSdk` is 24. The debug APK is large (~213 MB) because it carries three ABIs
plus Whisper and Vosk native libraries. Packaging checks P1–P4 in
[`../hardware_checklist.md`](../hardware_checklist.md) inspect the APK; they do
not prove a native library loads or the microphone works.

### Windows LED app

```bash
cd apps/walsey
flutter build windows --debug
```

Two prerequisites:

1. **`nuget.exe` on `PATH`.** `flutter_tts` runs
   `nuget install Microsoft.Windows.CppWinRT` during CMake configure. Download
   it outside the repo and prepend its folder to `PATH`. It is not committed.
2. **The `/await` workaround.** MSVC 14.51 rejects C++/WinRT coroutines compiled
   as C++17 inside `bluetooth_low_energy_windows_plugin` and
   `permission_handler_windows_plugin`. `apps/walsey/windows/CMakeLists.txt`
   removes `/await` from those targets and builds them as C++20. Keep the pub
   cache untouched; remove the block once the plugins raise their own language
   standard.

Windows BLE has **not** been run against a controller. Android is the
hardware-testing platform.

### Voice testbed

```bash
cd apps/walsey_voice_test
flutter build windows --debug
```

The testbed does not use the BLE plugins, so the `/await` workaround does not
apply. It needs `record_windows` and, for real recognition, the Whisper/Vosk
DLLs and model next to the exe.

## 4. Native speech setup (explicit, gitignored)

Nothing is downloaded implicitly. These scripts run only when you ask:

```powershell
# Windows: whisper.cpp + ggml-base.en model
powershell -ExecutionPolicy Bypass -File tools/fetch_whisper_windows.ps1

# Windows: Vosk fallback DLLs
powershell -ExecutionPolicy Bypass -File tools/fetch_vosk_windows.ps1

# Android: build whisper.cpp from source (NDK + SDK cmake/ninja)
powershell -ExecutionPolicy Bypass -File tools/build_whisper_android.ps1
```

Destination folders are gitignored. The CMake whisper block copies DLLs next to
the exe and the model into `models/`. If a folder is missing, the app still
builds; speech then reports a native-library error and typed input keeps working.

The in-app model manager is the supported path for users: **Manage offline
models** → Install. It verifies size/digest and installs into application
support storage. An installed app-support model wins over a Windows developer
copy.

Never commit model archives, native libraries, `windows/vosk/`,
`windows/whisper/`, `android/app/src/main/jniLibs-whisper/` or `build/`.

## 5. Test pitfalls specific to this repo

- **Fake-async and real services.** A plain `testWidgets` body that creates and
  disposes a service can hang on fake-async stream futures. Create and dispose it
  inside `tester.runAsync`.
- **Drivers in `setUp`.** A `LeddmxDriver` created in `setUp` has write futures in
  another async zone and may never complete under the fake clock. Construct it
  inside the test body.
- **Pulse animations.** Never use `pumpAndSettle` during an active voice take
  (the pulse repeats). Pump a fixed number of frames, for example
  12 × 20 ms.
- **Tall voice testbed page.** The Stage 2 page is taller than the default
  800×600 test surface. Set `tester.view.physicalSize` before pumping, or taps
  miss off-screen chips.
- **Stream events** need `pumpAndSettle`; status text can appear in both the chip
  and the button, so assert with `findsWidgets` when appropriate.
- **No real native dependencies in unit tests.** Voice tests must not need a
  microphone, a model archive, a native DLL or the internet. Use the fakes in
  `walsey_voice_speech/test/support/fakes.dart` and a loopback `HttpServer` for
  installs.
- **Pinned sizes.** The Whisper test fabricates a model with
  `truncate(147964211)`. Keep that equal to
  `SpeechModel.whisperBaseEnglish.archiveSizeBytes`.
- **Literal expectations.** Frame tests use hand-written hex strings. Parser
  tests use literal plans. Do not derive expectations from the implementation.

## 6. Changing protocol code

1. Read [`../research.md`](../research.md) and locate the exact evidence.
2. Change/add a pure encoder in `walsey_led_core/lib/src/protocol/`.
3. Add literal expected bytes to `leddmx_frames_test.dart`.
4. Keep value objects validating in constructors; throw
   `InvalidCommandException` for out-of-range values.
5. Keep all writes on the `WriteQueue` path.
6. Update the code comment, `research.md` and the matching
   [`hardware_checklist.md`](../hardware_checklist.md) row together.
7. Never raise `Evidence.decompiledApp` without hardware passing on **both**
   platforms.

## 7. Changing voice parsing or recognition

- Parser changes belong in `walsey_voice_core`. Keep it pure Dart.
- Do not add fuzzy matching or stem-based synonyms. Extend the literal
  paraphrase table only with mappings onto existing vocabulary.
- Never clamp brightness or invent colours/effects.
- Keep recognition outcomes and parser outcomes separate.
- Recognition changes belong behind the `SpeechEngineBinding` seam.
- The transcript assembler joins segments and collapses whitespace only. It does
  not "fix" wording.
- A plan is data; execution stays in `apps/walsey/lib/voice/`.
- Any change to the executor must preserve stop-on-failure, prerequisite
  re-checks and the write-vs-LED distinction.

## 8. Documentation workflow

- Update [`../README.md`](../README.md) when adding a document.
- Planned work goes in [`../planned/`](../planned/), with the current state and
  the unbuilt parts stated in the first paragraph.
- Run a quick link check before finishing:

```powershell
# Markdown links whose target file does not exist
Get-ChildItem -Recurse -Filter *.md | ForEach-Object {
  $dir = $_.DirectoryName
  Select-String -Path $_.FullName -Pattern '\]\(([^)#]+)' -AllMatches |
    ForEach-Object { $_.Matches } |
    ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -notmatch '^(https?:|mailto:|#)' } |
    ForEach-Object { Join-Path $dir $_ } |
    Where-Object { -not (Test-Path $_) }
}
```

- Keep counts and dates current, or mark them as the last recorded run.
