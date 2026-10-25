# Voice assistant — Stage 2 (push-to-talk, offline speech recognition)

Stage 2 adds offline speech recognition in front of the Stage 1 parser. Press
the microphone, speak, press **Stop & recognize**, and the transcript is parsed
exactly like typed text. It still **does not execute anything**: there is no
BLE import, no LED command, no wake word and no cloud service.

| Stage | Scope | State |
|---|---|---|
| 1 | Text → intent → validated parameters; testing UI | implemented |
| 2 | Push-to-talk speech recognition feeding the Stage 1 parser | **implemented now** |
| 3 | Wake word, LED execution through `LedControlService`, platform actions | not started |

## Decisions

### Engine: Vosk (Apache License 2.0)

Vosk is a Kaldi-based offline recognizer with small models (about 40 MB for
English) and a plain C API, which made it the only surveyed option that
satisfies every Stage 2 constraint: fully offline, no account, no paid API, no
mandatory cloud fallback, usable on Android **and** Windows.

Rejected alternatives:

| Option | Why not |
|---|---|
| `vosk_flutter` 0.3.48 | `pubspec.yaml` requires Dart `>=2.15.1 <3.0.0`; this project uses Dart 3.13.2. |
| `vosk_flutter_service` 0.1.3 | SDK-compatible, but its Windows plugin implements only `getPlatformVersion`, never `speechService.*`; its README says Windows needs another plugin for microphone input, and its CMake runs `flutter pub run vosk_flutter install` which fails because `vosk_flutter` is not a dependency. |
| `speech_to_text` / platform recognizers | On Android the system recognizer typically uses a network service and on Windows requires language packs; "offline" would depend on device configuration. The user explicitly chose a guaranteed-offline engine. |

Consequence: the microphone path is ours, not the engine's. One uniform pipeline
serves both platforms.

### Pipeline

```
AudioRecorder (record 7.1.2)         16 kHz, mono, pcm16bits
    ↓ Uint8List chunks
VoskSpeechEngine (dart:ffi)          dedicated worker isolate
    ├─ vosk_model_new / _free        model loaded once per installed path
    ├─ vosk_recognizer_new / _reset
    ├─ vosk_recognizer_accept_waveform
    └─ vosk_recognizer_result / partial_result / final_result
    ↓ SpeechEnginePartial / SpeechEngineSegment / SpeechEngineError
VoskSpeechRecognizer                 SpeechRecognizer port (walsey_voice_core)
    ↓ SpeechRecognitionEvent
PushToTalkController                 session state machine (single flight)
    ↓ final text
VoiceCommandParser                   the unchanged Stage 1 parser
    ↓ VoiceResult
UI                                   preview only
```

The worker isolate matters: `vosk_model_new` reads tens of megabytes from disk
and `vosk_recognizer_accept_waveform` is a synchronous CPU call. Both would
stall the UI if they ran on the main isolate. Audio is sent to the worker as
`TransferableTypedData`, and commands are processed in order.

### Package split

```
walsey_voice_core/          PURE DART. SpeechRecognizer port + session events,
                            parser, value objects, registry. No Flutter, BLE,
                            microphone, network or engine dependency.
walsey_voice_speech/        Flutter adapter package: Vosk FFI + worker isolate,
                            ephemeral model download/extract, push-to-talk
                            controller. No BLE import, no parser copy.
apps/walsey_voice_test/     Testbed UI: mic panel, language/model management,
                            typed input, interpretation panel.
```

The recognition port lives in the pure core so a future adapter (different
engine, different key) can replace Vosk without touching the UI. `VoiceResult`
and the parser were not modified; speech results are the same objects typed
results use.

## Recognition outcomes vs parser outcomes

These are deliberately separate, and the UI shows both:

| Recognizer state | Meaning |
|---|---|
| `idle` / `initializing` | Nothing captured yet / loading a model or starting capture |
| `listening` | Microphone open, partial text may appear |
| `recognizing` | Capture stopped, waiting for the final transcript (10 s watchdog) |
| `result` | Text returned; the parser result below it is the interpretation |
| `empty` | Vosk returned no text (silence, noise) — the parser was never called |
| `cancelled` | User discarded the session; late results are ignored |
| `error` | Permission, missing model, missing native library, unsupported platform/language, engine failure |

A session that ends in `result` can still contain a parser **failure**
(`unsupported`, `invalidParameter`, `ambiguous`, …). That is the honest
outcome: recognition worked, understanding did not. Parser failures are never
softened so that a bad transcript "passes", and brightness is still never
clamped.

`SpeechFailureKind` gains `unsupportedLanguage`; the existing kinds
(`permissionDenied`, `microphoneUnavailable`, `modelNotInstalled`,
`modelInvalid`, `nativeLibraryUnavailable`, `unsupportedPlatform`,
`initializationFailed`, `recognitionFailed`, `alreadyRunning`) are reused.

## Language models

Nothing is bundled and **nothing is downloaded automatically** — not at build
time, not at startup. The model manager lists three verified entries; the user
presses **Install** per language.

| Language | Model | Archive | MD5 (published) | Licence |
|---|---|---|---|---|
| English (US) | `vosk-model-small-en-us-0.15` | 41,205,931 B | `09ab50ccd62b674cbaa231b825f9c1cb` | Apache 2.0 |
| French | `vosk-model-small-fr-0.22` | 42,233,323 B | `8873b1234503f6edd55f54bfff31cf3e` | Apache 2.0 |
| Arabic (MSA) | `vosk-model-small-ar-0.3` | 104,351,896 B | `0eb578c0779f85ef039b7ee5bc1b64ed` | Apache 2.0 |
| Algerian Darija | — | — | — | no Vosk model exists; selectable but documented as unsupported |

Install = stream to a temporary file → verify the published MD5 → extract in a
background isolate → require `am/final.mdl` → atomically move into
`<app support>/walsey_models/<model id>`. A failure or cancellation deletes the
temporary files and leaves any previous installation untouched. Models live in
application support storage, not in the repository.

### Language reality check

The **parser is English-only**. Installing the French or Arabic model changes
what Vosk hears, not what the command registry understands, so their speech is
expected to end as `unsupported`. They are offered for recognition experiments,
not because the assistant understands those languages. Algerian Darija has no
Vosk model at all; it is shown in the selector with the microphone disabled
instead of being silently hidden.

## Offline semantics and privacy

- Recognition and parsing run on the device, after the model is installed.
  With the network disabled, everything except the model download still works.
- The only network call in this package is `ModelStore.install`, triggered by
  the user's **Install** press. There is no retry loop, background prefetch or
  cloud fallback.
- Audio is streamed into the recognizer and never written to disk, uploaded or
  logged. Logs contain status and errors, not transcripts.
- Android declares `INTERNET` only because of the explicit model download;
  `RECORD_AUDIO` is used for capture. Windows has no package manifest.

## Platform setup

### Android

`android/app/build.gradle.kts`:

```kotlin
dependencies {
    implementation("com.alphacephei:vosk-android:0.3.75@aar")
}
```

The AAR (Maven Central, 13,472,638 B) ships
`jni/{arm64-v8a,armeabi-v7a,x86,x86_64}/libvosk.so`; the built APK was checked
and contains `lib/{arm64-v8a,armeabi-v7a,x86_64}/libvosk.so` (Flutter's default
ABI filter drops 32-bit x86). The `@aar` notation skips the POM's Java/JNA
dependencies — the Dart FFI layer calls the C API directly. The merged manifest
declares `RECORD_AUDIO`, `INTERNET` and `minSdkVersion 24`.

### Windows

The Windows build needs the official
`vosk-win64-0.3.45.zip` (14,882,445 B, Apache 2.0) extracted once:

```powershell
powershell -ExecutionPolicy Bypass -File tools/fetch_vosk_windows.ps1
```

The script downloads the GitHub release, checks its size, and installs
`libvosk.dll` plus the MinGW runtime DLLs into
`apps/walsey_voice_test/windows/vosk/` (gitignored). `windows/runner/CMakeLists.txt`
copies them next to the executable when present. If the folder is missing the
build still succeeds; the app then reports "native library unavailable" and
typed commands keep working.

## Testing

No test needs a microphone, a model, a network connection or a native library:

- `walsey_voice_speech/test/vosk_recognizer_test.dart` — fake engine + fake
  capture: initialization, missing/unsupported model, permission denial, 16 kHz
  capture, partial/final/no-speech, cancel, double start, disposal.
- `walsey_voice_speech/test/push_to_talk_controller_test.dart` — session state,
  single flight, retry/cancel, watchdog, same-parser guarantee, empty results,
  language selection.
- `walsey_voice_speech/test/model_store_test.dart` — a loopback `HttpServer`
  serves a tiny model archive: MD5 verification, extraction, cleanup, HTTP
  errors, cancellation, removal. No internet.
- `walsey_voice_speech/test/vosk_result_test.dart` — Vosk JSON parsing,
  malformed replies.
- `apps/walsey_voice_test/test/` — typed Stage 1 flows and the Stage 2 UI with a
  fake recognizer and fake model store.

Results recorded on 2026-10-24 (local toolchain, Flutter 3.47.2 / Dart 3.13.2):

| Command | Result |
|---|---|
| `walsey_voice_core`: `dart analyze` / `dart test` | clean, 124/124 pass |
| `walsey_voice_speech`: `flutter analyze` / `flutter test` | clean, 68/68 pass (2026-10-25) |
| `apps/walsey_voice_test`: `flutter analyze` / `flutter test` | clean, 21/21 pass (2026-10-25) |
| `apps/walsey_voice_test`: `flutter build apk --debug` | PASS (209 MB debug APK; `libvosk.so` for 3 ABIs) |
| `apps/walsey_voice_test`: `flutter build windows --debug` | PASS; DLLs copied next to the exe; also PASSes with `windows/vosk/` absent |

None of these exercise a microphone, a model file or a real recognition. They
prove wiring, state handling and packaging only. Measured recognition accuracy,
the capture diagnostics and the engine comparison are in
[`voice_accuracy.md`](voice_accuracy.md).

## Known limitations

- Speech recognition has **not been exercised on hardware yet** (no microphone
  capture or model download was run on the S21 or on Windows during
  implementation). Treat accuracy, latency and permission behaviour as
  unverified until the checklist below passes.
- Small models favour speed and size over accuracy; command words such as
  "brightness" and colour names can be misheard, and a misheard command becomes
  a parser failure — never a guessed command.
- On this Windows machine the microphone path opens the device ~750 ms after
  the session starts (measured, see [`voice_accuracy.md`](voice_accuracy.md)),
  so the first syllable can be lost. The diagnostics panel reports the delay as
  "First audio"; the UI still says "Listening…" immediately.
- No wake word, no continuous listening, no background service. One session at
  a time, started by a tap and ended by a tap or the 10-second final-result
  watchdog.
- No command execution and no LED transport import; `executionStatus` remains
  `notExecuted`.
- The Windows **testbed** build is verified (`flutter build windows --debug`
  passes). The separate, pre-existing Windows blocker affects the LED app's
  plugins (`bluetooth_low_energy_windows`, `permission_handler_windows`), which
  this testbed does not use (see the root `AGENTS.md`).
- `record` and the Vosk native library are the only platform-specific pieces;
  replacing either is contained inside `walsey_voice_speech`.
- Windows capture asks the device for **16 kHz, mono, PCM16** directly (the
  `record_windows` source reader is configured with that media type and does not
  resample in Dart). A microphone/driver that does not expose that format would
  fail to start; this has not been exercised yet, so the first Windows run is
  the check. Android's `AudioRecord` path resamples internally.

## Manual checklist (Galaxy S21+ and Windows 11)

Setup, once per platform:

1. Install a language model from **Language models** (English US, ~40 MB).
   Confirm the progress bar reaches "Extracting" and the card says *Installed*.
2. Deny the microphone permission the first time the mic is pressed; expect
   "Microphone permission denied" and typed input still working. Grant it in
   system settings, press **Retry**, and expect *Listening…*.
3. Disable Wi-Fi/mobile data completely and repeat a recognition: it must still
   work, proving the offline path.

For each platform, record actual results:

| Check | Expected |
|---|---|
| Start listening | "Listening…", partial text appears within ~1 s |
| "Set brightness to 50 percent" | Recognized text + `setBrightness` + `Brightness: 50%` + "Not executed" |
| "Turn the lights blue" | `setColor` + blue + "Not executed" |
| "Activate effect 5" | `applyEffect` + effect 5 |
| Silence, then stop | "No speech detected" (not a parser failure) |
| Stop, then cancel | "Cancelled"; no transcript appears afterwards |
| Stop and stay silent for 10 s | "recognizer did not return a final result" error, Retry works |
| Second tap while initializing | No second session starts |
| Unplug/disable microphone mid-session | Error, typed input still works |
| Rotate/background the app mid-session | Session ends or cancels; reopening does not auto-start |
| Close the app | No microphone indicator remains |
| Arabic/French model + English speech | Recognition may return text; parser usually reports unsupported |
| Select Algerian Darija | Explanation text, mic button disabled |
| Windows: start capture on the built-in mic | Starts, or reports a clear capture error if the device does not expose 16 kHz mono PCM16 |
| Windows: launch with `windows/vosk/` removed | "Native library unavailable"; typed input still works |
| Both: network off, restart the app | Model already installed → recognition works with no network call |

Do not mark any LED/frame claim as verified here; Stage 2 sends no command.

## Stage 3 (not implemented)

Recommended next step only after this checklist passes on both platforms:
map `VoiceColor`/`VoiceBrightness`/`VoiceEffect` into `walsey_led_core` value
objects and call the existing `LedControlService` behind an explicit execution
action. Wake word, relative brightness and "next effect" still need a
trustworthy device state that the protocol cannot currently read.
