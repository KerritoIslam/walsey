# Voice assistant: capture, understanding and execution

The voice feature is a pipeline, not a chat model. Every stage has one job and
hands a typed result to the next. Nothing is executed from a transcript that did
not pass the deterministic parser and the command registry.

Reference documents: [`../voice_stage1.md`](../voice_stage1.md) (parser),
[`../voice_stage2.md`](../voice_stage2.md) (recognition),
[`../voice_assistant_report.md`](../voice_assistant_report.md) (measured state),
[`../wake_word.md`](../wake_word.md) (hands-free).

## 1. Pipeline

```
record (16 kHz, mono, pcm16)
  │ Uint8List chunks → complete little-endian samples (Pcm16Assembler)
  ▼
SpeechEngine in a worker isolate
  ├─ WhisperSpeechEngine  batch decode at stop; ~120 s cap; s16/32768.0
  └─ VoskSpeechEngine     streaming fallback with partials
  │ transcript (verbatim; only segments joined and whitespace collapsed)
  ▼
VoicePlanParser (CommandInterpreter)
  │  single command → the Stage 1 VoiceCommandParser first
  │  explicit multi-step grammar → ordered VoicePlan
  ▼
VoicePlanExecutor (apps/walsey/lib/voice)
  │ re-check prerequisites before each step
  ▼
LedConnectionService → LedControlService → LeddmxDriver → WriteQueue → BLE
```

Recognition outcomes and parser outcomes are separate. A perfect transcript may
still fail to parse; that is an interpretation failure, shown honestly. A
transcript is never cleaned up to make it pass.

## 2. Capture and engines

- `walsey_voice_speech` implements the pure `SpeechRecognizer` port from
  `walsey_voice_core`.
- **Whisper** (`ggml-base.en`, whisper.cpp tag `b5454`, 1.9.5) is primary. It
  runs through hand-written `dart:ffi` in a dedicated worker isolate. Decoding is
  batch: no partial transcript appears while speaking. The whole utterance is
  buffered (capped ~120 s) and decoded at stop. S16→F32 is `s16 / 32768.0`.
- Two decode fields are written through guarded setters:
  `initial_prompt` (a fixed product-vocabulary sentence) and
  `greedy.best_of = 1`. Each setter compares every known struct field against the
  pinned release defaults and writes nothing on a mismatch. Never write
  `whisper_full_params` directly.
- **Vosk** is the kept fallback: streaming Kaldi with partials, small models.
- Engines sit behind `SpeechEngineBinding` + `EngineSpeechRecognizer`. A new
  engine supplies a binding; it does not reimplement session logic.
- Capture uses the `record` plugin. The recorder stream is not assumed to align
  to 16-bit samples; `Pcm16Assembler` carries the trailing byte.
- Models are installed explicitly from **Manage offline models**. Model installs
  stream to a temporary file, verify size/digest, then move atomically. There is
  no startup prefetch, retry loop or background download. Whisper additionally
  checks the exact size and GGML/GGUF magic header.
- Recognition is offline after install. Audio is never written to disk, uploaded
  or logged.

## 3. Parser and registry

`walsey_voice_core` is pure Dart. It has no Flutter, BLE, microphone, network or
LLM dependency.

1. **Normalize** — lowercase, trim, collapse whitespace, strip punctuation,
   convert `%` to "percent", remove apostrophes for negation detection, keep
   signed/decimal numbers whole, strip a leading "Walsey"/"hey Walsey".
2. **Literal paraphrase table** — `lib/src/parser/paraphrase.dart` rewrites
   everyday phrases (`could you`, `I want`, `let's`, `get the lights working`,
   `power up`, `lighting` → `lights`). It is a literal map. It never gains
   stemming, fuzzy matching or scoring, and every mapping lands on vocabulary the
   unchanged parser already validates.
3. **Parse** — one closed `VoiceIntent` enum:
   `powerOn`, `powerOff`, `setColor`, `setBrightness`, `increaseBrightness`,
   `decreaseBrightness`, `applyEffect`, `queryStatus`.
   Parameters are sealed classes, not maps.
4. **Validate** — brightness is a whole 0..100 percent and is **never clamped**;
   colours come from a fixed list; effects are ids 1..210 or 255; two different
   values are `ambiguous`; missing/invalid values fail explicitly.
5. **Authorize** — `CommandRegistry` is the allowlist. An intent becomes a valid
   command only if its action spec is registered.

Safety behaviour that must not regress:

- negated, hypothetical, question-shaped and statement sentences are refused;
- compound or contradictory single sentences are `ambiguous`;
- unregistered actions and non-LED domains are refused, not ignored;
- status questions (`are the lights on`) become `queryStatus` only with an
  interrogative shape; the answer is always "the protocol has no state
  read-back", and nothing is sent;
- brightness qualifiers are fixed percentages (`half` 50, `quarter` 25,
  `full`/`maximum` 100, `minimum` 0), never interpolated; an explicit number
  wins.

`VoiceResult.executionStatus` stays `notExecuted` in both voice packages. They
have no executor.

## 4. Plans

`walsey_voice_core/lib/src/plan/` is a planning layer, **not a second parser**:

- `VoicePlanParser implements CommandInterpreter`.
- A single sentence is delegated to `VoiceCommandParser` first, so negation,
  questions, the registry allowlist, parameter validation and ambiguity still
  decide the outcome.
- Parameter failures are never split into several steps.
- The chain grammar is explicit; there is no fuzzy matching.

Step types:

| Step | Produced by |
|---|---|
| `ScanDevicesStep`, `SelectDeviceStep`, `ConnectDeviceStep`, `DisconnectDeviceStep`, `ReconnectLastDeviceStep` | connection phrases / pronoun follow-up |
| `SetPowerStep`, `SetColorStep`, `SetBrightnessStep`, `ApplyEffectStep` | validated commands |
| `QueryStatusStep` | interrogative status question |
| `SaveSceneStep` | recognized scene phrase, but no scene store/executor exists yet |

A plan is data only. `VoicePlanExecution.wroteNothing` exists so a scan-only or
status-only plan is not labelled "Executed".

## 5. Execution in the main app

`VoicePlanExecutor` (`apps/walsey/lib/voice/voice_plan_executor.dart`) is the
only `CommandExecutor`:

- runs steps strictly in order;
- re-checks prerequisites before each step (connected, validated variant,
  supported device);
- resolves devices only from real scan results;
- requires a supported `LEDDMX-NN` variant;
- stops on the first failure and reports later steps as not run;
- reports a BLE write as a write, never as a confirmed LED change;
- routes everything through the usual `LedConnectionService` /
  `LedControlService` path (no parallel command path).

The Assistant only executes a plan produced from **recognized speech**. Typed
input is interpreted for inspection and never executed. Scenes are recognized
but honestly refused.

## 6. Hold-to-talk lifecycle

The main app's Assistant is hold-to-talk; the testbed is tap-to-start /
tap-to-stop.

- `HoldToTalkButton` uses a custom `OneSequenceGestureRecognizer`: pointer down
  starts, pointer up (including outside the button) ends, pointer cancel
  cancels. The recognizer is start-gated: `enabled` must not clear
  `onEnd`/`onCancel`.
- `VoiceSessionController.press()` silences an optional spoken response, then
  starts one take. A second press while busy is ignored.
- `release()` is never gated on recognizer status. If the status is `idle` (the
  permission/recorder-open window), `press()` re-checks its pressed flag and does
  not open the microphone.
- `EngineSpeechRecognizer` records a stop request and re-checks it after every
  await. A recorder that fails to stop produces a visible
  `SpeechSessionFailed`, not a clean transcript.
- A 2 s hold watchdog stops a take whose pointer-up was never delivered; a 60 s
  `maxHoldDuration` is the hard cap. The phase changes only **after** the
  recognizer was asked to stop.
- Page deactivation or app lifecycle change cancels an active session.
- Optional spoken responses are off by default, use the OS voice, are silenced
  before every take, and are never used for typed input.

Diagnostics use take ids: `VOICE SESSION: hold started (take #N, …)`,
`microphone open`, `released`, `microphone stopped; transcribing`, plus explicit
lines for abnormal paths (released before open, released while starting,
pointer-up never observed, maximum hold).

## 7. Wake word / hands-free

Implemented, tested, opt-in wired — but **no model/backend ships in this build**.

Pipeline:

1. `WakeWordDetector` (Vosk phonetic or ONNX frame-scoring seam) emits only
   `WakeWordDetected`; it never produces a transcript.
2. `WakeWordCommandLoop` keeps 1.5 s of pre-roll, starts a pure-Dart energy VAD
   at the detection, **stops the detector** (one microphone consumer), and
   batch-decodes the captured command through `BufferedSpeechRecognizer`.
3. No speech after "Walsey" → `WakeEmpty`, not a decode of the wake phrase.
4. The transcript goes through the same parser/executor; a parse failure executes
   nothing.
5. After a *successful* take one restart is allowed. A failure never resumes
   automatically.

App rules:

- consent switch + explicit **Start listening**; nothing starts at launch;
- the Assistant shows those controls only when a loop is injected;
- a hold pauses hands-free listening and resumes it after the take;
- a hold is refused while a command is being decoded;
- stop/cancel/failure/dispose close the microphone;
- the Android `WakeWordForegroundService` is a visible lifecycle shell that
  never opens the microphone; background listening is Android-only.

Measured Vosk result: **0/36 synthetic positives, 0/60 false activations**. The
small model has no "walsey" token and transcribes it as common phrases that the
phonetic matcher must reject. That is why the UI reports `notConfigured` rather
than showing a fake control. The implementation plan for a real model is
[`../planned/onnx-wake-word.md`](../planned/onnx-wake-word.md).

## 8. Diagnostics: one prefix, one meaning

| Prefix | Means |
|---|---|
| `VOICE SESSION:` | hold/cancel lifecycle; no recognition claim |
| `WAKE WORD:` | opt-in hands-free start/stop/detection/failure |
| `VOICE RECOGNIZED:` | a real transcript, or explicit empty/cancelled/failure; `(hands-free)` marks the source |
| `VOICE INTERPRETED:` | plan or rejection; typed input is `(typed, not executed)` |
| `ACTION STARTED:` / `PLAN STEP i/n …` | execution began; step status is a step result |
| `RESULT … BLE WRITE OK …` | the frame was written; LED reaction unknown |
| `HARDWARE RESPONSE: PASSWORD REPLY:` | the only device-originated reply |
| `USER OBSERVATION:` | a human saw the LEDs change |
| `VOICE LATENCY:` | measured per-session timings; missing stages stay `null` |

Never log a write as device confirmation, and never reuse a prefix for another
meaning.

## 9. Tests and what they do not prove

- `walsey_voice_core/test/` is pure `dart test`: normalization, power, colour,
  brightness, effect, safety/ambiguity, registry, literal plan expectations,
  paraphrase/status, conversation memory.
- `walsey_voice_speech/test/` uses `FakeEngine` / `FakeCapture` / loopback HTTP.
  No microphone, model archive, native library or internet is required.
- `apps/walsey/test/` covers the executor over a real service + fake central,
  hold/release/typed/failure/cancel routing, gesture behavior, settings/activity,
  the Studio send path and the shell.
- These prove wiring and state handling, **not** human-speech accuracy, Android
  capture, a real model install or a BLE/LED response.
- Measured accuracy lives in [`../voice_accuracy.md`](../voice_accuracy.md);
  the remaining on-device checks are in [`../hardware_checklist.md`](../hardware_checklist.md)
  and [`../voice_stage2.md`](../voice_stage2.md).
