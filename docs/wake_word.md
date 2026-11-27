# Wake word: pipeline, measurements and platform constraints

Status: **pipeline implemented and tested; opt-in app wiring implemented; not
available at runtime in this build.** The shipped Assistant still starts capture
only on an explicit hold or the explicit "Start listening" button. There is no
wake-word *model* and no ONNX scoring backend in this repository, so the
Assistant shows an honest "not installed" explanation instead of a fake
listening control.

This document records what was actually built, what was measured, and what is
still blocked. The concrete implementation plan — a sherpa-onnx keyword spotter
first, an openWakeWord-style custom model as the production alternative — is
[`planned/onnx-wake-word.md`](planned/onnx-wake-word.md).

## Current behaviour

- Assistant page: hold the microphone button → session starts; release →
  recognition, interpretation, then (only for a ready plan) execution.
- `VoiceSessionController` owns one microphone consumer at a time. A hold stops
  hands-free listening before the recorder opens; a hold is refused while a
  detected command is being decoded.
- Hands-free listening is opt-in: a consent switch plus an explicit
  **Start listening** button. Nothing starts it at app launch, and turning
  consent off stops a running listener immediately.
- The Assistant shows the consent switch and start/stop controls only when a
  wake pipeline has been injected. This build injects none, so the card states
  that a trained "Walsey" model and an ONNX scoring backend are required.
- Typed input is interpreted by the same plan interpreter and is **never**
  executed.
- The parser/registry remain the authorization allowlist; a wake detection can
  only produce a transcript that goes through the normal pipeline.

## What exists now

| Implementation | File | Status |
| --- | --- | --- |
| `VoiceActivityDetector` | `walsey_voice_speech/lib/src/audio/voice_activity.dart` | Pure-Dart energy VAD with minimum speech, silence hangover and a max-duration latch. 9 tests. |
| `BufferedSpeechRecognizer` | `lib/src/wake/buffered_speech_recognizer.dart` | Decodes an already-captured PCM buffer through a warm `SpeechEngineBinding` (Whisper primary). No microphone ownership. |
| `WakeWordCommandLoop` | `lib/src/wake/wake_word_command_loop.dart` | Pre-roll ring buffer → VAD boundary → detector stopped → batch decode → transcript event; single restart after a completed take, no restart after failure. 7 tests. |
| `OnnxWakeWordDetector` | `lib/src/wake/onnx_wake_word_detector.dart` | Frame-scoring model behind `WakeWordScorer`, plus a raw-audio tap used for pre-roll. 15 tests. **No trained model or scorer backend ships.** |
| `VoskWakeWordDetector` | `lib/src/wake/vosk_wake_word_detector.dart` | Streaming Vosk + `PhoneticWakeMatcher`. 22 tests. **Not production-viable** (measurement below). |
| `WakeCommandSource` | `lib/src/wake/wake_word_command_loop.dart` | The seam the app depends on, so the session controller is testable with an in-memory source. |
| `AndroidWakeService` | `apps/walsey/lib/voice/android_wake_service.dart` | Lifecycle-only foreground-service bridge (`walsey/wake_service`), plus `WakeWordForegroundService.kt`. Never opens the microphone. |
| App wiring | `apps/walsey/lib/voice/voice_session_controller.dart`, `apps/walsey/lib/features/assistant/assistant_page.dart` | Consent setting, explicit start/stop, prewarm on page open, TTS echo protection, hold-to-talk handover, honest status lines. 11 app tests. |

The pipeline is deliberately composed so each part is individually honest:

1. The detector (a `WakeWordDetector`) only emits `WakeWordDetected`. It never
   produces a transcript.
2. The loop keeps 1.5 s of pre-roll audio, starts the VAD *at* the detection,
   stops the detector before decoding, and never fabricates a transcript. No
   speech after the wake word → `WakeEmpty`, not a decode of "Walsey" itself.
3. The transcript is handed to the existing interpreter/executor unchanged. A
   wake transcript that fails to parse is reported, never executed.

## What is still missing (blocking)

- **A trained "Walsey" model.** The openWakeWord training pipeline
  (TensorFlow/PyTorch + synthetic speech augmentation) is not installed or
  verified in this environment.
- **An ONNX runtime backend.** `WakeWordScorer` is a seam only; no
  `onnxruntime` library, Dart FFI binding or model file is bundled.
- **A measured false-activation/miss rate on human audio.** The synthetic SAPI
  corpus is a regression baseline, not evidence.

Because of this, `OnnxWakeWordDetector.prepare()` reports `notConfigured` when no
model is present and `start()` throws. There is no placeholder model and no fake
confidence.

## Measured Vosk phonetic proxy

Harness: `walsey_voice_speech/bin/wake_accuracy.dart` with
`tools/voice_accuracy/wake.txt` (18 positives per voice, 30 negatives per voice;
96 clips total from Microsoft David and Zira). Run on 2026-11-06, Windows 11,
`vosk-model-small-en-us-0.15`, real Vosk worker isolate, 3.2 kB (100 ms) chunks.

| Metric | Result |
|---|---|
| Positive clips | 36 |
| Detected | **0/36 (0.0%)** |
| Missed | 36/36 |
| Negative clips | 60 |
| False activations | 0/60 (0.0%) |
| Negative audio | 112.2 s → 0.00 false activations/hour |
| Model load (first start) | 4,124 ms |
| RSS before / after load / after run | 216.8 MB / 341.4 MB / 200.1 MB |
| Decode real-time factor | 0.135 |

The zero false-activation number is not a success: the detector also never fires
on a true positive. The reason is visible in the raw transcripts
(`--verbose`): the small Vosk model has no "walsey" token and transcribes it as
`well say`, `well see`, `while`, `the city` and similar common phrases. Those are
exactly the variants `PhoneticWakeMatcher` must reject to avoid false
activations, so the two goals conflict. `vosk_recognizer_set_key_phrases` is not
exposed by the pinned DLL/AAR, so a constrained grammar cannot fix it either.

## Android foreground service

`WakeWordForegroundService.kt` is compile-verified code, not a runtime-verified
listener:

- `START_NOT_STICKY` — no automatic restart after process death.
- Ondemand `startForeground(...)` with
  `FOREGROUND_SERVICE_TYPE_MICROPHONE` and a visible ongoing notification with a
  **Stop listening** action.
- The notification is silent-capable (`IMPORTANCE_LOW`) but cannot be dismissed
  while the service runs.
- The service itself does **not** open the microphone and does **not** recognise
  anything. It only keeps a detector that Dart already started alive.
- Manifest declares `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE` and
  `POST_NOTIFICATIONS`; `RECORD_AUDIO` is the existing runtime permission.

Background listening is therefore Android-only. On Windows and any other
platform the Assistant stops listening when the app leaves the foreground
(explicitly logged and reflected in the status text).

## Why the app does not enable it yet

### Windows

- Desktop applications may hold the microphone open, but there is no standard
  "background service" model equivalent to Android. A minimised window still
  runs, while a closed app cannot listen at all.
- Microphone access is a per-app privacy setting (Settings → Privacy →
  Microphone). An enterprise policy can disable it; the detector then must
  report `permissionDenied`, not retry silently.
- Any always-on capture keeps the audio device busy, blocks other apps from
  exclusive-mode capture and prevents sleep in some configurations.
- whisper.cpp batch decoding is unsuitable for a continuous wake word: the
  model expects an utterance. The wake stage must stay a small dedicated
  detector; full Whisper decodes only happen after a detection, on the buffered
  command audio.

### Android

- Android 9+ restricts background microphone access. A long-running detector
  needs a **foreground service** with `android.permission.FOREGROUND_SERVICE`
  and the microphone service type
  (`android:foregroundServiceType="microphone"`, plus
  `FOREGROUND_SERVICE_MICROPHONE` on Android 14+). The notification is
  mandatory and visible; a silent background listener is not allowed.
- `RECORD_AUDIO` is a runtime permission. Denial must degrade to typed input and
  hold-to-talk after the user grants it, never to a retry loop.
- Doze and manufacturer battery optimisation can kill or throttle the service.
  Exemption (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) is a user-facing choice and
  Play Store policy restricts broad use; Walsey does not request it today.
- Apps cannot start a microphone foreground service from the background on
  recent Android versions; a detection cannot bootstrap itself from a cold
  start without user-visible activity.
- Battery cost is continuous: the microphone and detector run for as long as
  the service lives, not only while the user speaks.

### Both platforms

- Recognition stays offline; a wake-word engine must also be local. No cloud
  fallback, no audio upload.
- Audio must be discarded unless the user explicitly saves a diagnostic take.
  The pre-roll ring and capture buffer are in memory only, are bounded, and are
  cleared when the loop stops or resumes.
- The app must never claim "listening" unless the microphone is actually
  delivering audio. The Assistant only shows "Listening" after the loop reports
  that the detector started.
- A recognized sentence may legitimately fail to parse. The wake path never
  cleans up or rewrites a transcript.

## Permissions summary

| Platform | Needed for hold-to-talk today | Extra for opt-in hands-free listening |
| --- | --- | --- |
| Windows | Microphone privacy setting | None, but no background-service model |
| Android | `RECORD_AUDIO` (runtime) | `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `POST_NOTIFICATIONS`, visible ongoing notification, battery-exemption decision |

`BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` are unrelated to wake word and stay scoped
to the existing connection flow.

## Failure and UX rules

- Detector unavailable / denied / killed → status message plus hold-to-talk,
  never a fake pulsing "active" indicator.
- Detection while a session is already active → ignored (single-session rule).
- Detection while a plan is executing → ignored until it finishes; no queued
  commands.
- App backgrounded → stop the detector unless the foreground-service path is
  active and visible (Android only today).
- Every start/stop is explicit and logged; no automatic restart loops. One
  restart after a *successful* take is part of the loop, not a retry loop.
- A spoken response is silenced on detection so the assistant cannot transcribe
  its own voice.
- Diagnostic lines use the fixed prefix `WAKE WORD:` and never reuse the
  recognition/execution prefixes.

## Reproducing the Vosk measurement

```powershell
# 1. corpus (once)
powershell -ExecutionPolicy Bypass -File tools/voice_accuracy/make_tts_corpus.ps1 `
  -CommandFile tools/voice_accuracy/wake.txt `
  -OutputDirectory "$env:TEMP\walsey_wake_corpus"

# 2. model (once, ~41 MB zip)
#    https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip

# 3. detector benchmark (needs libvosk.dll + its three MinGW DLLs on PATH)
$env:PATH = "<vosk dll folder>;$env:PATH"
cd walsey_voice_speech
dart run bin/wake_accuracy.dart `
  --model "$env:TEMP\vosk-model-small-en-us-0.15" `
  --corpus "$env:TEMP\walsey_wake_corpus" `
  --out "$env:TEMP\walsey_wake_baseline.json" -v
```

`--limit N` runs only the first N manifest rows for a quick smoke test. The
manifest uses the same polarity convention as the command corpus: `!` means the
clip must not trigger.

## What a shipped detector would still need

1. A trained openWakeWord-style ONNX model for "Walsey", plus an ONNX runtime
   FFI backend implementing `WakeWordScorer` (or a different lightweight local
   model behind the same seam).
2. A measured false-activation and miss rate on **human** audio, on both
   platforms.
3. A startup path in the app that constructs the loop only when the model is
   installed, and keeps reporting `notConfigured` otherwise.
4. On-device verification of the Android foreground service (none is available
   in this environment).
