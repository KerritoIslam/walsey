# Voice assistant — Stage 2 (push-to-talk, offline speech recognition)

Stage 2 adds offline speech recognition in front of the Stage 1 parser. Press
the microphone, speak, press **Stop & recognize**, and the transcript is parsed
exactly like typed text. It still **does not execute anything**: there is no
BLE import, no LED command, no wake word and no cloud service.

| Stage | Scope | State |
|---|---|---|
| 1 | Text → intent → validated parameters; testing UI | implemented |
| 2 | Push-to-talk speech recognition feeding the Stage 1 parser | **implemented now** |
| 3 | Wake word, LED execution through `LedControlService`, platform actions | partially investigated: detectors implemented but disabled, LED execution lives in the main app, wake accuracy measured as not viable (`docs/wake_word.md`) |

## Decisions

### Engine: whisper.cpp primary, Vosk fallback

The shipped configuration is **whisper.cpp** (tag `b5454`, reports version
1.9.5) with the `ggml-base.en.bin` model — called through hand-written
`dart:ffi`, in a dedicated worker isolate, CPU-only, fully offline. It was
chosen over the previously shipped Vosk small model because it transcribed the
synthetic Stage 1 benchmark corpus measurably better (65 % vs 50 % verbatim on
the same 60 sentences, see [`voice_accuracy.md`](voice_accuracy.md)), at the
cost of a ~141 MB model and **batch decoding**: there are no partial
transcripts while the user speaks; the whole utterance is decoded at
"Stop & recognize".

Vosk stays installed and selectable as a **fallback** (its catalogue entries,
Windows DLLs and Android AAR are all kept), but nothing requires it and it is
no longer the default engine.

The worker sets two decode parameters that whisper.cpp does not default to:

- `initial_prompt` — a fixed sentence of the product's own vocabulary (wake
  word, device-name shape, colour words, `percent`, `effect`, `scan for
  devices`, `then`). It steers spelling only; the transcript still goes through
  the unchanged parser, so it can never add a command.
- `greedy.best_of = 1` — whisper.cpp keeps five candidates per window by
  default; one candidate measured identical accuracy at roughly half the decode
  time (see [`voice_accuracy.md`](voice_accuracy.md)).

Both are written through `WhisperBindings.setInitialPrompt` /
`setGreedyBestOf`, which first compare every field this binding knows against
the pinned release's defaults. If any field differs, nothing is written and the
engine decodes with the library defaults. The struct is never written blindly.

Rejected alternatives (from the original 2026 survey; cloud options remain
rejected for the same reasons):

| Option | Why not |
|---|---|
| Cloud / platform recognizers (`speech_to_text` etc.) | Network dependency; "offline" would depend on device configuration. A guaranteed-offline engine was an explicit requirement. |
| whisper.cpp **Android AAR / prebuilt** | No official Maven artifact exists; the APK therefore builds whisper.cpp from source (see Platform setup). |
| `vosk_flutter` 0.3.48 | `pubspec.yaml` requires Dart `>=2.15.1 <3.0.0`; incompatible SDK range. (Vosk fallback uses hand-written FFI instead.) |

Consequence: the microphone path is ours, not the engine's, and engines are
swappable data: `SpeechEngineBinding` (name, spawn factory, platform check,
model-per-language, failure hints) plus the generic `EngineSpeechRecognizer`
hold all session logic once. `WhisperSpeechRecognizer` and `VoskSpeechRecognizer`
are thin subclasses that only supply their binding.

### Pipeline

```
AudioRecorder (record 7.1.2)         16 kHz, mono, pcm16bits
    ↓ Uint8List chunks → PCM16 sample-boundary assembler
SpeechEngine (worker isolate)        chosen by the active SpeechEngineBinding
    ├─ WhisperSpeechEngine           buffers the utterance, decodes once in
    │   whisper_init_from_file /       finish() (no partials); ~120 s cap;
    │   whisper_full(_params_by_ref)   s16→f32 is s16/32768.0; initial_prompt
    │   (guarded struct writes)        + one greedy candidate
    │   + whisper_full_n_segments / _get_segment_text
    └─ VoskSpeechEngine              streaming Kaldi path with partials
        vosk_model_new / _free       (fallback engine, unchanged)
        vosk_recognizer_new / _reset / _accept_waveform
        vosk_recognizer_result / partial_result / final_result
    ↓ SpeechEnginePartial / SpeechEngineSegment / SpeechEngineError
EngineSpeechRecognizer               SpeechRecognizer port (walsey_voice_core);
                                     WhisperSpeechRecognizer / VoskSpeechRecognizer
                                     are binding-only subclasses
    ↓ SpeechRecognitionEvent
PushToTalkController                 session state machine (single flight)
    ↓ final text
VoiceCommandParser                   the unchanged Stage 1 parser
    ↓ VoiceResult
UI                                   preview only
```

The worker isolate matters: loading a model reads tens/hundreds of megabytes
from disk and inference is a synchronous CPU call that can take seconds. Both
would stall the UI on the main isolate. Audio is sent to the worker as
`TransferableTypedData`, and commands are processed in order.

The recorder stream is not assumed to align chunks to 16-bit samples.
`Pcm16Assembler` carries one trailing byte into the next chunk, feeds the engine
only complete little-endian samples, and reports a truncated final sample as a
recognition failure. Diagnostics and WAV export observe the same complete bytes
that reach the engine.

### Session teardown, the stop/start race and the hold watchdog

Releasing the hold-to-talk button did not stop recording in real use, even
though the gesture tests passed. Two independent causes were found, and neither
was the gesture layer:

1. `EngineSpeechRecognizer.stop()` could run **while `start()` was still
   awaiting** the permission check, the recorder open or the engine spawn.
   `stop()` completed the session, and the pending `start()` then attached the
   audio stream and opened the recorder with the session flag already cleared —
   so nothing was left that could stop it. The recognizer now records the stop
   request (`_stopRequested`) and re-checks it after every await
   (`_abandoned(token)`): a stop before any audio resolves to
   `SpeechNoSpeechDetected`, and a stop after the engine began still closes the
   recorder.
2. `VoiceSessionController.release()` returned early when the recognizer status
   was `idle` — which is exactly the state during that window. A release is now
   never gated on status: `idle` means `press()` re-checks its own pressed flag
   after echo suppression and never opens the microphone; an active status is
   stopped immediately; a terminal status is a no-op.

A third defect made a bad case silent: a recorder that failed to stop was
swallowed into a clean transcript. It now ends the session with
`SpeechSessionFailed(microphoneUnavailable)` and a visible message, and
`EngineSpeechRecognizer(captureStopTimeout:)` (default 3 s) bounds a recorder
that never answers.

Guardrails on top of the fix:

- `VoiceSessionController` runs a watchdog every 2 s while the phase is
  `pressing`/`recording`. If the pointer-up never arrives (lost capture, parent
  gesture took the arena, OS swallowed it) it stops the take; a hard
  `maxHoldDuration` (60 s) ends a stuck hold regardless. The phase only changes
  **after** the recognizer has been asked to stop, so the UI can never show a
  closed microphone that is still open.
- Every take is logged with an id, so one press → release cycle can be followed
  end to end: `VOICE SESSION: hold started (take #N, attempt N)`,
  `take #N — microphone open; recording`,
  `take #N — released (status …); stopping the microphone`,
  `take #N — microphone stopped; transcribing`, plus explicit lines for
  "released before the microphone opened", "released while the recognizer was
  starting", "the microphone opened after the release", "the pointer release was
  never observed" and "maximum hold reached".

### Package split

```
walsey_voice_core/          PURE DART. SpeechRecognizer port + session events,
                            parser, value objects, registry. No Flutter, BLE,
                            microphone, network or engine dependency.
walsey_voice_speech/        Flutter adapter package: engine seam + Whisper FFI
                            (primary) and Vosk FFI (fallback), worker
                            isolates, ephemeral model download/verify,
                            push-to-talk controller. No BLE import, no parser
                            copy.
apps/walsey_voice_test/     Testbed UI: mic panel, language/model management,
                            typed input, interpretation panel.
```

The recognition port lives in the pure core, and the engine seam is data
(`SpeechEngineBinding` + `EngineSpeechRecognizer`), so another engine can be
added without touching the UI or the session logic. `VoiceResult` and the
parser were not modified; speech results are the same objects typed results
use.

## Recognition outcomes vs parser outcomes

These are deliberately separate, and the UI shows both:

| Recognizer state | Meaning |
|---|---|
| `idle` / `initializing` | Nothing captured yet / loading a model or starting capture |
| `listening` | Microphone open, partial text may appear |
| `recognizing` | Capture stopped, waiting for the final transcript (20 s watchdog) |
| `result` | Text returned; the parser result below it is the interpretation |
| `empty` | The engine returned no text (silence, noise) — the parser was never called |
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
time, not at startup. The model manager lists four verified entries; the user
presses **Install** per language.

| Language | Engine | Model | Size | Digests | Licence |
|---|---|---|---|---|---|
| English (US) | Whisper (primary) | `ggml-base.en` → `ggml-base.en.bin` | 147,964,211 B | MD5 `4279db3d7b18d9f6e4d5817a16af4f09`, SHA-256 `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002` | MIT |
| English (US) | Vosk (fallback) | `vosk-model-small-en-us-0.15` | 41,205,931 B | MD5 `09ab50ccd62b674cbaa231b825f9c1cb` | Apache 2.0 |
| French | Vosk (fallback) | `vosk-model-small-fr-0.22` | 42,233,323 B | MD5 `8873b1234503f6edd55f54bfff31cf3e` | Apache 2.0 |
| Arabic (MSA) | Vosk (fallback) | `vosk-model-small-ar-0.3` | 104,351,896 B | MD5 `0eb578c0779f85ef039b7ee5bc1b64ed` | Apache 2.0 |
| Algerian Darija | — | — | — | — | no offline model exists; selectable but documented as unsupported |

Hugging Face publishes **no official digest** for `ggml-base.en.bin`, so the
Whisper entry's MD5/SHA-256 were computed from a downloaded artifact whose size
was verified byte-for-byte against the repo's published `X-Linked-Size`
(147,964,211 B, checked 2026-10-26). The digest is therefore "self-verified",
and the installer additionally pins the exact size and the file's magic header.

Vosk install = stream to a temporary file → verify the published MD5 → extract
in a background isolate → require `am/final.mdl` → atomically move into
`<app support>/walsey_models/<model id>`. Whisper install = stream to a staged
file → verify exact published size + MD5 + SHA-256 → atomically rename into
`<app support>/walsey_models/ggml-base.en/ggml-base.en.bin` (validated later by
size + magic: little-endian `6C 6D 67 67`, plain `ggml` or `GGUF`). A failure or
cancellation deletes the temporary files and leaves any previous installation
untouched. Models live in application support storage, not in the repository.
On Windows a developer convenience also accepts a verified copy at
`<exe folder>/models/ggml-base.en.bin` (wired by the CMake whisper block); an
explicitly installed copy always wins.

### Language reality check

The **parser is English-only**. Installing the French or Arabic model changes
what the engine hears, not what the command registry understands, so their
speech is expected to end as `unsupported`. They are offered for recognition
experiments, not because the assistant understands those languages. Whisper
ships **no French/Arabic model in this build** (`ggml-base.en` is English-only),
so with the primary engine those languages are disabled in the selector; the
Vosk fallback still covers them when selected with Vosk as the engine. Algerian
Darija has no offline model at all; it is shown in the selector with the
microphone disabled instead of being silently hidden.

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

**Whisper on Android** has no official AAR/Maven artifact, so the APK's
`libwhisper.so`/`libggml*.so` are built from source, once, by an explicit
script (no network at app-build time; if the folder is missing the APK still
builds and speech reports "native library unavailable"):

```powershell
powershell -ExecutionPolicy Bypass -File tools/build_whisper_android.ps1
```

The script builds the pinned `b5454` tag with the Android NDK (NDK r28,
CMake/Ninja from the SDK, `GGML_NATIVE=OFF`, `GGML_OPENMP=OFF`, shared libs,
examples/tests/server off) for `arm64-v8a`, `armeabi-v7a` and `x86_64`, and
installs into
`android/app/src/main/jniLibs-whisper/<abi>/` (gitignored), which Gradle
packages via a `sourceSets` jniLibs entry. The APK ships exactly
`libwhisper.so`, `libggml.so`, `libggml-base.so`, `libggml-cpu.so` per ABI —
verified with `llvm-readelf -d`: `libwhisper.so` and `libggml.so` carry hard
`DT_NEEDED` entries on `libggml-cpu.so`, and with OpenMP off the only other
dependencies are Android system libraries (`libc`, `libm`, `libdl`), so the
libraries are self-contained. The CPU backend is registered inside the shipped
libraries; no runtime backend search happens on Android.

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

**Whisper on Windows** uses the official prebuilt binaries of the same `b5454`
revision (release asset `whisper-bin-x64.zip`, 8,928,640 B; the CLI self-reports
version 1.9.5) plus the model, fetched once:

```powershell
powershell -ExecutionPolicy Bypass -File tools/fetch_whisper_windows.ps1
```

It installs `whisper.dll`, `ggml.dll`, `ggml-base.dll`, the nine
`ggml-cpu-<arch>.dll` backend variants and `ggml-base.en.bin` into
`apps/walsey_voice_test/windows/whisper/` (gitignored); the CMake whisper block
copies the DLLs next to the executable and the model into `models/` next to it.
If the folder is missing the build still succeeds and speech reports the
native-library error while typed commands keep working. On Windows the ggml
CPU backend is dynamically loaded, which is why
`ggml_backend_load_all_from_path(<exe folder>)` runs before whisper.dll is
used; Android needs no such search because its CPU backend is compiled in.

## Testing

No test needs a microphone, a model, a network connection or a native library:

- `walsey_voice_speech/test/whisper_recognizer_test.dart` — the Whisper
  binding through the shared fake engine/capture (`test/support/fakes.dart`):
  missing model → `SpeechModelRequired` naming `ggml-base.en`, French/Darija →
  `unsupportedLanguage`, transcript passthrough verbatim, no grammar
  forwarding, session/permission/disposal behaviour.
- `walsey_voice_speech/test/whisper_model_store_test.dart` — loopback
  `HttpServer` serving a fake GGUF file: size/MD5/SHA-256 verification, magic
  and size validation of installed files, staged-file cleanup, cancellation.
- `walsey_voice_speech/test/whisper_pcm_test.dart` / `whisper_result_test.dart`
  — s16→f32 conversion and the join-only transcript assembler (punctuation,
  capitalisation and hallucination artefacts pass through untouched).
- `walsey_voice_speech/test/vosk_recognizer_test.dart` — Vosk fallback through
  the same shared fakes: initialization, missing/unsupported model, permission
  denial, 16 kHz capture, partial/final/no-speech, cancel, double start,
  disposal.
- `walsey_voice_speech/test/push_to_talk_controller_test.dart` — session state,
  single flight, retry/cancel, watchdog, same-parser guarantee, empty results,
  language selection.
- `walsey_voice_speech/test/model_store_test.dart` — a loopback `HttpServer`
  serves a tiny model archive: MD5 verification, extraction, cleanup, HTTP
  errors, cancellation, removal. No internet.
- `walsey_voice_speech/test/vosk_result_test.dart` — Vosk JSON parsing,
  malformed replies.
- `apps/walsey_voice_test/test/` — typed Stage 1 flows and the Stage 2 UI with a
  fake recognizer and fake model store (model manager lists all four entries;
  no execution control anywhere).

Results recorded on 2026-11-04 (local toolchain, Flutter 3.47.2 / Dart 3.13.2).
These are the implementation-time numbers; the current counts after the
2026-11-06 recording fix and accuracy work are 154 / 213 / 21 / 128
(`docs/voice_assistant_report.md` §7):

| Command | Result |
|---|---|
| `walsey_voice_core`: `dart analyze` / `dart test` | clean, 151/151 pass |
| `walsey_voice_speech`: `flutter analyze` / `flutter test` | clean, 116/116 pass |
| `apps/walsey_voice_test`: `flutter analyze` / `flutter test` | clean, 21/21 pass |
| `apps/walsey_voice_test`: `flutter build windows --debug` | PASS; whisper + Vosk DLLs and `models/ggml-base.en.bin` copied next to the exe; also PASSes with `windows/whisper/` absent |
| `apps/walsey_voice_test`: `flutter build apk --debug` | PASS (2026-10-26; APK contains `libwhisper.so`, `libggml.so`, `libggml-base.so`, `libggml-cpu.so` and `libvosk.so` for all 3 ABIs) |
| `apps/walsey`: `flutter analyze` / `flutter test` | clean, 82/82 pass |
| `apps/walsey`: `flutter build apk --debug` | PASS (2026-11-04); same native libs, verified by APK inspection |
| `apps/walsey`: `flutter build windows --debug` | PASS (2026-11-04) with the app-side `/await` workaround; **not** run against BLE hardware |

None of these exercise a microphone, a model file or a real recognition. They
prove wiring, state handling and packaging only. Measured recognition accuracy,
the capture diagnostics and the engine comparison are in
[`voice_accuracy.md`](voice_accuracy.md).

## Known limitations

- Android is the unverified platform: no Android device was available, so
  microphone capture, permissions, the foreground service and model download on
  the S21 are unexercised. Windows capture was measured (below), but no person
  has spoken a command through the Assistant. Treat Android accuracy, latency and
  permission behaviour as unverified until the checklist below passes.
  A model **download** has only been exercised against a loopback test server,
  never against the real host.
- Whisper decodes in **batch**: no partial transcript appears while the user
  speaks; the transcript arrives once at "Stop & recognize". This is a design
  property of the primary engine, not a bug. The Vosk fallback keeps partials.
- Small models favour speed and size over accuracy; command words such as
  "brightness" and colour names can be misheard, and a misheard command becomes
  a parser failure — never a guessed command. The Whisper vocabulary prompt
  reduces the specific mishearings listed in
  [`voice_accuracy.md`](voice_accuracy.md) on the synthetic corpus; it is not
  evidence about human speech.
- On this Windows machine the microphone path was measured (2026-10-25) to
  deliver the first chunk ~65 ms after start; the earlier ~750 ms delay is no
  longer present. The diagnostics panel reports it as "First audio".
- No wake word in the testbed, no continuous listening and no automatic detector
  start. One session at a time. The voice testbed is tap-to-start/tap-to-stop;
  the main app's Assistant is **hold-to-talk** (release, including outside the
  button, ends the take; pointer cancel or a lifecycle change cancels it).
  `walsey_voice_speech` now also contains two detectors behind the pure
  `WakeWordDetector` port, but nothing calls `start()`; the measured Vosk
  baseline is 0/36 positives (`docs/wake_word.md`). The main app additionally has
  a compile-verified Android microphone foreground-service shell that no shipped
  code path starts.
- No command execution and no LED transport import; `executionStatus` remains
  `notExecuted`.
- The Windows **testbed** build is verified (`flutter build windows --debug`
  passes). The LED app's Windows build now also passes after the app-side CMake
  workaround for MSVC 14.51's `/await` rejection (no pub-cache edit); Windows
  BLE has still not been run against a controller.
- `record` plus each engine's native library are the only platform-specific
  pieces; replacing or adding an engine is contained inside
  `walsey_voice_speech`.
- Windows capture asks the device for **16 kHz, mono, PCM16** directly (the
  `record_windows` source reader is configured with that media type and does not
  resample in Dart). A microphone/driver that does not expose that format would
  fail to start; this has not been exercised yet, so the first Windows run is
  the check. Android's `AudioRecord` path resamples internally.

## Real-device validation

Automated tests are microphone-, native-library- and hardware-free, so these
are the gaps they cannot close: Android microphone capture, an Android
Whisper/Vosk native load, a model install on device storage, a real BLE
scan/connect/write, the password reply, hold-to-talk on touch input, and the
same flow on Windows.

The practical sequence lives in
[`hardware_checklist.md`](hardware_checklist.md): **P1–P5** (APK packaging and
on-device model install) and **V1–V12** (voice pipeline, hold gesture, plans,
BLE stages, latency). Record results in its tables; do not mark a row pass from
a simulated run.

## Manual checklist (Galaxy S21+ and Windows 11)

Setup, once per platform:

1. Install a language model from **Language models** — with the Whisper engine
   that is `ggml-base.en` (~141 MB, size + MD5 + SHA-256 verified); the Vosk
   fallback model is ~40 MB. Confirm the card says *Installed*.
   Whisper also accepts a developer copy at `<exe folder>/models/ggml-base.en.bin`
   (copied there by the build when `windows/whisper/` is populated).
2. Deny the microphone permission the first time the mic is pressed; expect
   "Microphone permission denied" and typed input still working. Grant it in
   system settings, press **Retry**, and expect *Listening…*.
3. Disable Wi-Fi/mobile data completely and repeat a recognition: it must still
   work, proving the offline path.

For each platform, record actual results:

| Check | Expected |
|---|---|
| Start listening | "Listening…"; with Whisper there are no partials by design (batch decode) |
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
| Select French/Arabic with the Whisper engine | Item disabled ("no Whisper model"); Vosk fallback still covers them |
| Windows: start capture on the built-in mic | Starts, or reports a clear capture error if the device does not expose 16 kHz mono PCM16 |
| Windows: launch with `windows/whisper/` removed | "Native library unavailable"; typed input still works |
| Windows: launch with `windows/vosk/` removed | Only matters with the Vosk fallback engine selected; Whisper is unaffected |
| Both: network off, restart the app | Model already installed → recognition works with no network call |

Do not mark any LED/frame claim as verified here; Stage 2 sends no command.

## Stage 3 (not implemented)

Recommended next step only after this checklist passes on both platforms:
map `VoiceColor`/`VoiceBrightness`/`VoiceEffect` into `walsey_led_core` value
objects and call the existing `LedControlService` behind an explicit execution
action. Wake word, relative brightness and "next effect" still need a
trustworthy device state that the protocol cannot currently read.
