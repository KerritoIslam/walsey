# Voice assistant: reliability and accuracy report (2026-11-06)

Scope: make the offline assistant reliable in real use, in this order — fix the
hold-to-talk release bug, analyse recognition failures, improve Whisper accuracy,
then verify (or explicitly refute) wake word, background listening, latency,
spoken responses, music-reactive mode and split-by-parts. Everything below is
measured, compile-verified, or marked blocked. No cloud service, no fake wake
detection, no background listening, no simulated audio meter, no weakened
command validation and no LED success claim was added.

Headline: the release bug was **not** the gesture recognizer. It was a
stop/start race inside the recognizer plus a release path that dropped the
request; both are fixed and regression-tested. The app-path Whisper
measurement went from 95.4% to 100% on the single-command corpus and from 76.2%
to 100% on the plan corpus (in-sample, see §2), with zero false commands in
every configuration.

## 1. Hold-to-talk: releasing no longer leaves the microphone open

### What was observed

The button animation stopped but the microphone stayed open; a second take
either failed or recorded the tail of the previous one. Unit tests passed,
because they exercised the gesture layer, not the ordering between the
recognizer's own `start()` and `stop()`.

### Root causes (all three fixed)

1. **`stop()` could complete while `start()` was still awaiting.**
   `EngineSpeechRecognizer.stop()` finished the session; the pending `start()`
   then attached the recorder stream and opened the microphone with the session
   flag already cleared, so nothing could ever close it. The recognizer now
   records a stop request and re-checks it after **every** await
   (`_stopRequested`, `_abandoned(token)`). A stop before any audio resolves to
   `SpeechNoSpeechDetected`; a stop after the engine began still tears the
   session down.
2. **`VoiceSessionController.release()` dropped releases in that window.**
   It returned early when the recognizer status was `idle`, which is exactly the
   status during permission/recorder-open. Release is now never gated on status:
   `idle` means `press()` re-checks its pressed flag after echo suppression and
   never opens the mic; an active status is stopped now; a terminal status is a
   no-op. If the recognizer reports `listening` *after* the release, that is
   detected and stopped.
3. **A recorder that failed to stop was swallowed.** Its error became a clean
   (empty or partial) transcript. It now ends the session with
   `SpeechSessionFailed(microphoneUnavailable)` and a visible message, and
   `captureStopTimeout` (3 s) bounds a recorder that never answers — never a
   transcript, never a silent success.

### Guarantees now covered by tests

| Behaviour | Where |
|---|---|
| Mouse press/release stops one take | `assistant_recording_test.dart` |
| Touch press/release behaves identically | same |
| Drag outside the button, then release, still stops | same |
| Pointer cancel cancels instead of recording on | same |
| Rapid press/release never leaves the mic open | same |
| Release during recorder open still stops the take | same + `voice_session_controller_test` + `vosk_recognizer_test` |
| Repeated takes each stop their own recorder | same |
| Navigating away while recording cancels the take | same |
| App lifecycle change while recording cancels the take | same |
| Recorder that cannot stop shows a visible error | same + controller test |
| Recorder that never confirms the stop times out visibly | same + recognizer test |
| Release before the permission check never opens the mic | `vosk_recognizer_test` |
| Watchdog stops a hold whose release was never observed | `voice_session_controller_test` |
| A normal release wins long before the watchdog | same |

21 new tests: 11 widget/integration, 6 controller, 4 recognizer (red before the
fix, green after).

### Watchdog

While the phase is `pressing`/`recording`, a 2 s periodic check runs; a hold
that reaches `maxHoldDuration` (60 s) is force-stopped. The phase changes only
**after** the recognizer was asked to stop, so the UI can never display a closed
microphone that is still open. The watchdog is tick-counted, so it is testable
under the fake clock instead of relying on wall time.

### Diagnostics

Every take carries an id, and the existing fixed prefixes are unchanged:

```
VOICE SESSION: hold started (take #3, attempt 3)
VOICE SESSION: take #3 — microphone open; recording
VOICE SESSION: take #3 — released (status listening); stopping the microphone
VOICE SESSION: take #3 — microphone stopped; transcribing
VOICE RECOGNIZED: transcript="turn the lights on"
```

Abnormal paths log their own sentence: released before the microphone opened,
released while the recognizer was starting, microphone opened after the release,
pointer release never observed, maximum hold reached. None of them reuses a
recognition or execution prefix.

### Physical-microphone procedure (blocked here, no device)

No Android device was available, and on Windows the capture path was exercised
only through the voice testbed's `--record-selftest` (ambient room audio, no
spoken command through the Assistant). So the runtime fix is proven by the
fake-recorder integration tests plus code inspection, not by hearing the
recorder stop during a real take. The procedure that closes that gap:

1. Open Assistant, hold the button, say "turn the lights on", release **inside**
   the button. Expect exactly one `take #N` sequence ending in
   `microphone stopped; transcribing`, then a transcript (or an honest failure).
2. Hold, drag off the button, release. Same sequence; no second take starts.
3. Hold, press Escape or switch apps mid-hold. Expect `cancelled by the user`
   and no transcript.
4. Tap and release as fast as possible. Expect either a clean "nothing was
   recorded" or one normal take — never a still-open microphone.
5. Repeat three times; each take must have a new `#N` and stop exactly once.
6. Leave the app while recording; on return the microphone indicator must be
   off and the next take must work.
7. Watch the OS microphone indicator between steps: it must be off whenever the
   UI is not showing `Recording`.

## 2. Recognition failure analysis

Method: `tools/voice_accuracy/make_tts_corpus.ps1` (144 single-command clips =
108 positives + 36 negatives) and the plan corpus (62 clips = 42 + 20), then
`bin/whisper_corpus.dart` — a new harness that links the app's own
`WhisperBindings`, so the parameters, prompt and greedy setting are the shipping
ones, not the CLI's approximation of them.

Recognition failures were classified, not guessed. On the **previous** app
configuration (greedy with whisper.cpp's default five candidates, no prompt),
103/108 single commands parsed; with one candidate and no prompt, 32/42 plans
parsed. The misses were:

| Expected | Heard | Class |
|---|---|---|
| walsey turn the lights on | Volsidy turned the lights on | invented wake word is out of vocabulary |
| walsey activate effect 7 | Volsity Activate FX7 | model normalises "effect 7" to "FX7" |
| make the lights green | Make the light screen | homophone |
| make the lights cyan | Turn the lights on | homophone |
| scan for devices | Skin for devices | homophone |
| connect to LEDDMX-03-6B4A | Letting 0.03-6B4A | product word is out of vocabulary |
| … on then set brightness … | … on the Anset brightness … | clause boundary misheard |

The distinction matters: "green"→"screen" is a **language-model** bias, not a
poor microphone. The capture path itself was verified separately (format, rate,
timing, tail, no clipping), so capture problems were not "fixed" with parser
synonyms — the parser was not touched at all.

Fix: vocabulary biasing via `initial_prompt` (a fixed sentence of the product's
vocabulary) plus **one** greedy candidate instead of five. Measured through the
app path:

| Configuration | Single commands | Plan corpus | False commands |
|---|---|---|---|
| five candidates, no prompt (previous app) | 103/108 (95.4%), p95 4,757 ms | not run through FFI | 0/36, 0/20 |
| one candidate, no prompt | 103/108 (95.4%), p95 1,198 ms | 32/42 (76.2%) | 0/36, 0/20 |
| one candidate + shipped prompt | **108/108 (100%), p95 960–1,174 ms** | **42/42 (100%), p95 1,002–1,274 ms** | **0/36, 0/20** |

Decode latency of the shipped configuration, rerun on the final code: mean
894 ms / p95 960 ms (single) and mean 929 ms / p95 1,002 ms (plan), RTF 0.394 and
0.293. Across runs on this machine the mean moved between 0.9 s and 1.2 s, so
treat the range as the measurement. These are **decode only**: press → first
audio, recorder stop, and parsing add to the user-visible time, and none of that
has been measured on a phone.

Entity accuracy: 70/70 (colour 32/32, brightness 20/20, effect 18/18) and
24/24 plan. Beam search was measured and rejected (worse accuracy, slower): 100/108
at RTF 0.666 versus 103/108 at RTF 0.506 for the same CLI run.

For reference, the kept **Vosk fallback** measures 92/108 (85.2%) and 30/42
(71.4%) on the same corpora, also with zero false commands. It stays installed
and selectable, but it is not the shipped engine, so those numbers describe the
fallback, not the default experience.

Caveat, stated plainly: the prompt was chosen while looking at these clips, so
100% is an **upper bound**, not a prediction for new speakers. What it does
establish is that the prompt only re-weights spellings the parser already
accepts, that it converts no negative into a command, and that the parser kept
its zero-false-command property. A human-speech benchmark is still required.

Also unchanged by design: a correct transcript that fails to parse is an
**interpretation** failure, not a recognition failure, and poor capture is not
treated as an excuse to loosen validation. Recognizer outcomes and parser
outcomes stay separate in the UI and in the logs.

## 3. Wake word

| Approach | Status | Measured / blocker |
|---|---|---|
| Streaming Vosk + `PhoneticWakeMatcher` (`VoskWakeWordDetector`) | Implemented, 22 tests | **0/36 positives, 0/60 false activations**, model load 4,124 ms, RTF 0.135. Not viable. |
| Frame-scoring ONNX seam (`OnnxWakeWordDetector`) | Implemented, 15 tests | No trained "Walsey" model and no verified training pipeline. `prepare()` returns `notConfigured`; `start()` throws. |
| Command pipeline (`VoiceActivityDetector` + `BufferedSpeechRecognizer` + `WakeWordCommandLoop`) | Implemented, 16 tests (9 + 7) | Pre-roll, VAD end-of-command, detector stopped before decode, no fabricated transcript. Verified with fakes only. |
| App opt-in wiring (`VoiceSessionController` + Assistant card + Android FGS) | Implemented, 11 app tests | Consent + explicit start/stop, prewarm on page open, TTS echo protection, hold-to-talk handover, honest "not installed" state. **Not runtime-verified**; no pipeline is injected because no model/backend exists. |

Vosk keyword spotting (`vosk_recognizer_set_key_phrases`) is absent from both the
Windows DLL and the pinned Android AAR — binary-checked, so this is not a wiring
choice. `VoiceSessionController.startWakeListening` exists but the Assistant
injects no wake pipeline, so the card states that a trained model and an ONNX
`WakeWordScorer` backend are missing. Hold-to-talk remains the only active input
in this build. Details in `docs/wake_word.md`.

## 4. Background listening: platform capability

| Capability | Android | Windows | Verified? |
|---|---|---|---|
| Hold-to-talk while the app is foreground | Yes | Yes | Android BLE transport yes; microphone capture not on a physical device |
| Capture while the app is backgrounded | Needs a foreground service with `foregroundServiceType="microphone"` and a mandatory notification | No standard background-service model; a closed app cannot listen | **No** |
| Service survives Doze / OEM battery optimisation | Not guaranteed; exemption is a user/Play-policy decision | n/a | **No** |
| Start listening from a cold background state | Blocked by recent Android versions without a visible activity | n/a | **No** |
| Visible stop control | Notification action implemented | In-app only | Compile-verified, not run |
| No silent/background capture | By design: no caller starts it | By design | Yes (absence of a caller) |

`WakeWordForegroundService.kt` + the `walsey/wake_service` Dart bridge are a
visible lifecycle shell only; the service does not open the microphone. The
controller will start it only from an explicit hands-free start request, which
cannot happen here because no detector is injected. 6 mocked-channel tests, no
device run.

## 5. Spoken responses (TTS)

- `flutter_tts` in `apps/walsey`; `VoiceResponseSpeaker` + `FlutterTtsEngine` in
  `lib/voice/voice_response_speaker.dart`.
- **Off by default**, enabled by the persisted `spokenResponses` setting.
- Speaks only a short fixed outcome (`Done.`, `Command not executed.`,
  `Cancelled.`, `Plan ready. Nothing was sent.`) after a **speech** session;
  typed interpretations are never spoken.
- Echo suppression: `press()` awaits `speaker.silence()` before opening the
  microphone, and a release during that await now aborts the take instead of
  opening the mic late (covered by the new release-race test).
- Failures are swallowed and logged; a missing platform voice cannot block
  recognition or execution. Uses the OS voice; no download, no network.
- 7 unit tests. **Not exercised with a real voice on Android or Windows.**

## 6. Music-reactive mode and split-by-parts

- Music-reactive: `docs/music_mode.md` + a pure-Dart FFT prototype
  (`lib/music/spectrum.dart`, 7 tests). Analysis only; it never touches BLE and
  no shipped path calls it. Timing over BLE is unverified (no controller).
- Split-by-parts / segments: `docs/led_segments.md` — no per-segment command is
  documented, so it stays unsupported rather than simulated. Nothing was added
  that would send an unverified frame.

## 7. Build and test results

Run sequentially, Windows 11.

| Package | Analyze | Tests |
|---|---|---|
| `walsey_led_core` | clean | 57 pass |
| `walsey_led_ble` | clean | 7 pass |
| `walsey_voice_core` | clean | 154 pass |
| `walsey_voice_speech` | clean | 213 pass |
| `apps/walsey` | clean | 128 pass |
| `apps/walsey_voice_test` | clean | 21 pass |
| `tools/ble_probe` | clean | 30 pass, 1 skipped (widget test) |

Builds:

- `flutter build apk --debug` — **PASS**. APK 213 MB (debug, three ABIs). Native
  packaging inspected inside the APK: `libwhisper.so`, `libggml.so`,
  `libggml-base.so`, `libggml-cpu.so` and `libvosk.so` are present for
  `arm64-v8a`, `armeabi-v7a` and `x86_64`. Merged manifest carries
  `RECORD_AUDIO`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`,
  `POST_NOTIFICATIONS`, the BLE permissions and
  `WakeWordForegroundService` with `foregroundServiceType="microphone"`.
- `flutter build windows --debug` — **PASS** with `nuget.exe` on `PATH` (the
  `flutter_tts` Windows plugin fetches `Microsoft.Windows.CppWinRT`; the binary
  is not committed). The app-side CMake `/await` workaround for the BLE plugins
  is still required.

Measurement prerequisites (explicit, gitignored, outside the repo): whisper.cpp
b5454 DLLs + `ggml-base.en.bin` in `apps/walsey_voice_test/windows/whisper/`,
`nuget.exe` on `PATH` for the Windows build, and the regenerated corpora in
`%TEMP%`.

## 8. Changed files

Recording reliability:

- `walsey_voice_speech/lib/src/speech_recognizer.dart` — stop/start race,
  `captureStopTimeout`, bounded stop, capture-failure reporting.
- `walsey_voice_speech/lib/src/vosk_speech_recognizer.dart`,
  `.../whisper/whisper_speech_recognizer.dart` — timeout pass-through.
- `apps/walsey/lib/voice/voice_session_controller.dart` — release no longer
  status-gated, take ids, 2 s watchdog + 60 s cap, phase logging, disposed-safe
  notifications.
- `apps/walsey/lib/features/assistant/assistant_page.dart` — recognizer
  injection for tests, deactivation guard.
- `apps/walsey/lib/design/hold_to_talk_button.dart` — start-gated gesture (from
  the earlier fix; release/cancel stay wired for the whole take).

Recognition accuracy:

- `walsey_voice_speech/lib/src/whisper/whisper_bindings.dart` —
  `_WhisperFullParams` layout, `_matchesPinnedLayout`, `setInitialPrompt`,
  `setGreedyBestOf`, `debugAllocatePinnedParams` (test-only).
- `walsey_voice_speech/lib/src/whisper/whisper_speech_engine.dart` — vocabulary
  prompt constant, ownership/freeing, one greedy candidate, `vocabularyPromptApplied`.
- `walsey_voice_speech/bin/whisper_corpus.dart` — new app-path corpus harness.
- `tools/voice_accuracy/run_whisper_corpus.ps1` — `-BeamSize` / `-Prompt`.

Wake word, background service, spoken responses, LED feedback, music:

- `walsey_voice_speech/lib/src/wake/` — `VoskWakeWordDetector`,
  `OnnxWakeWordDetector`, `PhoneticWakeMatcher`, start exception.
- `apps/walsey/lib/voice/android_wake_service.dart` +
  `android/app/src/main/kotlin/com/walsey/walsey/WakeWordForegroundService.kt`
  and the manifest service/permission entries.
- `apps/walsey/lib/voice/voice_response_speaker.dart`,
  `lib/state/app_settings.dart` (`spokenResponses`).
- `apps/walsey/lib/control/led_feedback.dart`, `lib/music/spectrum.dart`.

Tests:

- `apps/walsey/test/assistant_recording_test.dart` (new, 11).
- `apps/walsey/test/voice_session_controller_test.dart` (6 new).
- `walsey_voice_speech/test/vosk_recognizer_test.dart` (4 new),
  `test/support/fakes.dart` (`GatedCapture`).
- `walsey_voice_speech/test/whisper_params_guard_test.dart` (new, 5): builds the
  parameter struct in Dart with the pinned defaults and proves the guard
  accepts only that layout, so a whisper.cpp upgrade cannot silently corrupt
  native memory.

Docs: `docs/voice_accuracy.md`, `docs/voice_stage2.md`,
`docs/music_mode.md` (stale capture-delay figure corrected),
`docs/voice_assistant_report.md` (this file), `README.md`, `AGENTS.md`.

## Blocked / not verified

No Android device and no LED controller were available. Not verified: Android
microphone capture and the foreground service on a real device, real wake-word
detection (no trained model), background listening, spoken responses with a real
voice, hold-to-talk on touch hardware, any LEDDMX frame, LED-feedback cues,
music mode over BLE, and split-by-parts. The next hardware pass follows
`docs/hardware_checklist.md` (protocol) and `docs/voice_stage2.md` (voice), and
must record `USER OBSERVATION:` separately from `BLE WRITE OK`.


## Upgrade round: audio lifecycle, understanding, wake pipeline (2026-11-12)

This round did not change the recognition engine or its measured numbers. It
changed what happens around recognition and what the parser accepts.

| Area | State | Evidence |
|---|---|---|
| Hold-to-talk release lifecycle | **Already correct; no bug reproduced** | The 2026-11-06 race tests still pass; no code change was needed. |
| Voice activity detection | Implemented | Pure-Dart energy VAD (`lib/src/audio/voice_activity.dart`), 9 tests. Used by the wake pipeline, not by hold-to-talk (release still ends a take). |
| Wake ? command pipeline | Implemented, not runtime-verified | `WakeWordCommandLoop` (pre-roll, VAD, stop-before-decode, no fabricated transcript), 7 tests. |
| Prewarm | Implemented | The Assistant preloads the wake model and buffered engine on page open without opening the microphone. |
| Paraphrases | Implemented | Literal table (`paraphrase.dart`), 26 literal tests; negation/question/statement refusals unchanged. |
| Brightness qualifiers | Implemented | Fixed percentages (half/quarter/full/maximum/minimum), never clamped. |
| Status questions | Implemented | `queryStatus` intent + `QueryStatusStep`; the executor answers "no state read-back" and sends nothing. A write-free plan is reported as `answered` ("nothing sent"), never as `Executed`. |
| Follow-up memory | Implemented | `VoiceConversation` (10-minute TTL) adds a reconnect step for pronouns; wired in the Assistant and invalidated on disconnect/cancel/parse failure. |
| Wake word in the app | **Blocked** | No trained "Walsey" model and no ONNX `WakeWordScorer` backend. The UI says so; no fake control. |
| Background listening | **Not runtime-verified** | Android FGS is wired end to end but never runs because no detector is injected; no device available. |
| Multilingual (fr/ar) | **Not implemented** | Deliberately deferred; the parser vocabulary and models are English-only. |

The measured recognition baseline in this report and in
`docs/voice_accuracy.md` predates the parser changes and has not been re-run.
`bin/check_corpus.dart` should be run before quoting coverage again.
