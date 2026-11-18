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
- `walsey_voice_speech/` — Flutter voice Stage 2 adapter: an engine seam
  (`SpeechEngineBinding` + generic `EngineSpeechRecognizer`), whisper.cpp
  through hand-written `dart:ffi` in a worker isolate (primary), the Vosk C API
  the same way (fallback), `record` microphone capture, explicit model
  download/verify, and the single-session `PushToTalkController`. Must not
  import `walsey_led_core`/`walsey_led_ble`, copy the parser, or execute
  commands.
- `apps/walsey_voice_test/` — Flutter voice testbed: speak (offline Whisper, or
  the Vosk fallback) or type, then inspect the same parser's interpretation.
  Imports only the two voice packages (no BLE), so it also builds on Windows.
- `apps/walsey/` — main app: `lib/connection/led_connection_service.dart`
  (scan/connect/validate/disconnect state machine + driver binding),
  `lib/control/led_control_service.dart` (typed UI facade + logging),
  `lib/app/` (responsive shell: Windows sidebar + optional diagnostics dock,
  Android five-destination bottom nav), `lib/design/` (tokens, theme, widgets,
  colour picker), `lib/features/` (Home, Devices + details/hardware test,
  Studio, Assistant, Activity/Diagnostics, Settings, planned Connect/Automations),
  `lib/voice/` (hold-to-talk session controller, plan executor over the real
  connection/command services, opt-in spoken responses, Android microphone
  foreground-service bridge), `lib/control/led_feedback.dart` (dormant opt-in
  cue abstraction), `lib/music/spectrum.dart` (offline FFT prototype, never
  sends), `lib/state/` (local settings + activity ledger) and
  `lib/ui/log_view.dart`. The Assistant is hold-to-talk: release ends the take,
  then the transcript is planned and (only if valid) executed step by step. See
  its README for the controlled first-hardware-test procedure and
  `docs/voice_assistant_report.md` for the current measured state.
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
dart analyze                         # clean as of 2026-11-12
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
flutter analyze                      # clean as of 2026-11-18
flutter test                         # 143 tests pass as of 2026-11-18
flutter build apk --debug            # PASS as of 2026-11-04
flutter run -d <android-device-id>
adb logcat -s flutter:D              # app diagnostics are tagged [WalseyApp]
flutter build windows --debug        # PASS as of 2026-11-04 (app-side /await CMake workaround)
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
dart analyze                         # clean as of 2026-11-12
dart test                            # 191 tests pass as of 2026-11-12
dart test test/parser_safety_test.dart

cd ../walsey_voice_speech
flutter pub get
flutter analyze                      # clean as of 2026-11-12
flutter test                         # 229 tests pass as of 2026-11-12

cd ../apps/walsey_voice_test
flutter pub get
flutter analyze                      # clean as of 2026-11-12
flutter test                         # 21 widget tests pass as of 2026-10-26
flutter run -d <device-id>           # speech needs a mic + one explicit model install

# Windows native engines (explicit, once, gitignored):
powershell -ExecutionPolicy Bypass -File ../../tools/fetch_whisper_windows.ps1   # whisper.cpp + ggml-base.en
powershell -ExecutionPolicy Bypass -File ../../tools/fetch_vosk_windows.ps1      # Vosk fallback DLLs
flutter build windows --debug

# Android whisper.cpp from source, once (needs NDK + SDK cmake/ninja):
powershell -ExecutionPolicy Bypass -File ../../tools/build_whisper_android.ps1
flutter build apk --debug
```

No CI, formatter config, codegen, or root test runner. `flutter create` was
already run for `tools/ble_probe` and `apps/walsey`; rerunning it can overwrite
the runner files. `test` and `lints` are already in `walsey_led_core/pubspec.yaml`,
so skip the README's `dart pub add` step.

**Windows build (LED app):** `flutter build windows --debug` PASSed in
`apps/walsey` on 2026-11-06. `flutter_tts` (added for opt-in spoken responses)
requires `nuget.exe` on `PATH` at build time: its Windows plugin fetches
`Microsoft.Windows.CppWinRT`. The binary is not committed; install/download it
outside the repo and prepend its folder to `PATH` for the build. The existing
app-side CMake workaround for the BLE plugins remains: those plugins compile
C++/WinRT coroutines as C++17 with `/await`, which MSVC 14.51 rejects (STL1011).
`apps/walsey/windows/CMakeLists.txt` strips `/await` from
`bluetooth_low_energy_windows_plugin` and `permission_handler_windows_plugin`
and builds them as C++20 (native coroutines). Keep the pub cache untouched;
remove the block once the plugins raise their own language standard. The voice
testbed does not use those plugins: `flutter build windows --debug` PASSes there
(2026-10-26) with `record_windows` + the whisper/Vosk DLLs next to the exe.
Windows BLE has **not** been run against a controller; Android remains the
hardware-testing platform.

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
- Diagnostic stages keep fixed prefixes, and each prefix has one meaning:
  `VOICE SESSION:` (hold/cancel), `WAKE WORD:` (opt-in hands-free detector
  start/stop/detection/failure), `VOICE RECOGNIZED:` (real transcript, or
  explicit empty/cancelled/failure; a hands-free transcript adds
  `(hands-free)`), `VOICE INTERPRETED:` (plan or rejection;
  typed input is marked `(typed, not executed)`), `ACTION STARTED:` /
  `PLAN STEP i/n …`, `RESULT … BLE WRITE OK …` (frame written, LED reaction
  unknown), `HARDWARE RESPONSE: PASSWORD REPLY:` (the only device reply) and
  `USER OBSERVATION:` (a human saw the LEDs change). Never log a write as a
  device confirmation, and never reuse a prefix for another meaning.

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
- Everyday paraphrases are rewritten by the **literal** table in
  `lib/src/parser/paraphrase.dart` (`could you`, `I want`, `let's`,
  `get the lights working`, `power up`, word aliases such as `lighting` →
  `lights`). It must never gain stemming, fuzzy matching or scoring, and every
  mapping must land on vocabulary the unchanged parser already validates.
- Brightness qualifiers are fixed percentages (`half` 50, `quarter` 25, `full`/
  `maximum` 100, `minimum` 0), never interpolated or clamped. An explicit number
  always wins.
- Status questions become `VoiceIntent.queryStatus` only with an interrogative
  shape (`are the lights on`, `what is the brightness`); a statement
  (`the lights are on`) and any sentence containing an action verb stay
  refused. The answer is always "the protocol has no state read-back".
- `VoiceConversation` is an expiring target memory (10-minute default). It may
  add `ReconnectLastDeviceStep` for a pronoun follow-up; it never stores LED
  state and never bypasses the parser, registry or executor prerequisites.

## Voice Stage 2 rules

- Primary engine is **whisper.cpp** (pinned tag `b5454`, 1.9.5), called through
  hand-written `dart:ffi` in `walsey_voice_speech/lib/src/whisper/`, with the
  `ggml-base.en.bin` model (~141 MB). Vosk (Apache License 2.0,
  `lib/src/vosk/`) is the kept fallback, never required. Both engines sit
  behind the `SpeechEngineBinding`/`EngineSpeechRecognizer` seam in
  `lib/src/speech_recognizer.dart`; never special-case engine logic outside a
  binding. Do not replace them with a cloud/paid recognizer or add a mandatory
  network fallback. A different engine must implement the core
  `SpeechRecognizer` port and keep typed input working.
- Whisper decodes in batch: no partial transcripts by design; the utterance is
  buffered (capped ~120 s) and decoded once at stop. S16→F32 conversion is
  `s16 / 32768.0`. `whisper_full_params` is used only through the by-ref API
  (`whisper_full_default_params_by_ref`). The worker writes **two** fields into
  that struct — `initial_prompt` (the fixed product-vocabulary sentence) and
  `greedy.best_of = 1` — and only through `WhisperBindings.setInitialPrompt` /
  `setGreedyBestOf`, which first compare every known field against the pinned
  b5454 defaults and write nothing on any mismatch. Never write the struct
  directly, never add a field without extending that guard, and keep the prompt
  to spellings the parser already accepts: biasing must not invent commands,
  soften validation or "clean up" a transcript. The CLI runner
  (`tools/voice_accuracy/run_whisper_corpus.ps1`) only approximates the app;
  `walsey_voice_speech/bin/whisper_corpus.dart` is the app-path reference.
- Recognition is offline once a model is installed. Nothing is downloaded
  implicitly: `ModelStore.install` runs only from the explicit model-manager
  action, with no startup prefetch, retry loop or background download. The
  catalogue is verified (id, size, digest, licence); adding a Whisper entry
  additionally requires the SHA-256 — HF publishes no digest for GGUF files, so
  the artifact's size is checked against HF's published `X-Linked-Size` and the
  computed digests are documented as self-verified. Adding a Vosk entry requires
  checking id/size/MD5/licence against Alpha Cephei's published list.
- Whisper model validation pins exact size and header magic (little-endian
  `6C 6D 67 67`/'ggml'/GGUF). Never accept a file that only "looks like a
  model". An installed app-support copy always wins over the Windows developer
  copy in `<exe folder>/models/`.
- Recognition outcomes (`empty`, `cancelled`, permission, model, native-library,
  platform/language) and parser outcomes (`unsupported`, `invalidParameter`,
  `ambiguous`, …) stay separate. Never modify or "clean up" a transcript to make
  a poor transcription pass the parser — the transcript assembler only joins
  segments and collapses whitespace. A recognized sentence may legitimately end
  as a parser failure.
- One session at a time, started only by explicit user action. The testbed uses
  tap-to-start/tap-to-stop; the main app's Assistant is **hold-to-talk** (press
  starts, release or pointer-cancel ends, release outside the button still
  ends). Stop, cancel and dispose close the microphone; a 20 s recognition
  watchdog prevents a hung engine from pinning the UI, and the controller's
  2 s hold watchdog plus a 60 s `maxHoldDuration` stop a take whose pointer-up
  was never delivered. That watchdog may only change the phase **after** asking
  the recognizer to stop — never show a closed microphone that is still open.
  A release is never gated on the recognizer status: `idle` means the pending
  press must re-check and not open the mic. No wake word, no auto-start, no
  background listening.
- The voice testbed must not import `walsey_led_ble` or `walsey_led_core`, and
  no voice code path may send a frame. Typed input must keep working when the
  microphone, model or native library is unavailable.
- Android ships `libvosk.so` via
  `implementation("com.alphacephei:vosk-android:0.3.75@aar")` and whisper.cpp
  via the gitignored `android/app/src/main/jniLibs-whisper/<abi>/` source set
  built by `tools/build_whisper_android.ps1` (`GGML_NATIVE=OFF`,
  `GGML_OPENMP=OFF`; the APK needs `libwhisper.so`, `libggml.so`,
  `libggml-base.so`, `libggml-cpu.so` — `libggml-cpu.so` is a hard dependency,
  verified with `llvm-readelf`). Windows needs `tools/fetch_whisper_windows.ps1`
  and/or `tools/fetch_vosk_windows.ps1`; the DLLs are gitignored and copied next
  to the exe by `windows/runner/CMakeLists.txt` (with the model into
  `models/`). Never commit model archives, native libraries or `build/`.

## Voice plans, hold-to-talk and wake word

- `walsey_voice_core/lib/src/plan/` is a planning layer, not a second parser.
  Single commands are delegated to `VoiceCommandParser` first, so negation,
  questions, the registry allowlist, parameter validation and ambiguity keep
  deciding the outcome. Parameter failures are never split into several steps.
  The plan grammar is explicit; no fuzzy matching.
- `VoicePlanParser implements CommandInterpreter`. A plan is data only. Execution
  lives in `apps/walsey/lib/voice/voice_plan_executor.dart` (`CommandExecutor`),
  runs steps strictly in order, re-checks prerequisites before each step, stops
  on the first failure, resolves devices only from real scan results and
  requires a supported `LEDDMX-NN` variant. A BLE write is reported as a write,
  never as a confirmed LED change. Scenes are recognized but honestly refused.
- `apps/walsey/lib/voice/voice_session_controller.dart` owns the single
  hold-to-talk session, the plan result and the execution progress. Recognition,
  interpretation and execution stay separate phases; a parser failure never
  reaches the executor; typed input is interpreted only, never executed. A
  second press while busy is ignored. A plan that finished without writing any
  frame (`VoicePlanExecution.wroteNothing`) is never labelled "Executed": a
  status question ends in `VoiceSessionPhase.answered` ("nothing sent"), and a
  scan/connect-only plan keeps its own honest message.
- `HoldToTalkButton` uses a custom `OneSequenceGestureRecognizer`: pointer down
  starts, pointer up (including outside the button) ends, pointer cancel
  cancels. Page deactivation/lifecycle change cancels an active session. The
  rings are a phase animation, never fake microphone amplitude. The recognizer
  is only *start-gated*: `enabled` must not clear `onEnd`/`onCancel`, because the
  Assistant sets `enabled: canStart`, which turns false as soon as a take starts.
- Wake word is **implemented and opt-in wired, but has no model/backend in this
  build**: `WakeWordDetector` and `WakeCommandSource` are pure ports in
  `walsey_voice_core`/`walsey_voice_speech`; `VoskWakeWordDetector` (streaming
  Vosk + phonetic matcher), `OnnxWakeWordDetector` (frame-scoring seam),
  `VoiceActivityDetector`, `BufferedSpeechRecognizer` and
  `WakeWordCommandLoop` (pre-roll → VAD → stop detector → batch decode) ship in
  `walsey_voice_speech`. `VoiceSessionController.startWakeListening` exists but
  is only reachable from the Assistant's explicit consent switch + Start button,
  and the app injects no pipeline, so the card says the model is missing.
  Never add background recording, an automatic detector start, a fake wake
  button or a placeholder model. Measured Vosk result: 0/36 synthetic positives,
  0/60 false activations, RTF 0.135, so it is not production-viable; the ONNX
  path reports `notConfigured` until a trained "Walsey" model and an ONNX
  `WakeWordScorer` backend exist. Benchmarks and platform limits are in
  `docs/wake_word.md`.
- Hands-free rules: exactly one microphone consumer. A hold calls
  `stopWakeListening` (keeping the user's consent so it can resume) before the
  recorder opens; a hold is refused while `wakeCapturing`; a spoken response is
  silenced on detection and listening resumes only after it finishes. Stop,
  cancel, failure and dispose close the microphone. The Android
  `WakeWordForegroundService` is a visible lifecycle shell that never opens the
  microphone; background listening is Android-only, other platforms stop on
  lifecycle change and say so.
- Latency is measured per session in `VoiceLatency` (engine/model, recorder open,
  press → first audio, release → transcript, parse, end-to-end) and logged as
  `VOICE LATENCY: …`. Never synthesize a stage; a missing mark stays `null`.

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
  command logging/redaction/single-flight (`led_control_service_test`), the voice
  plan executor over a real service + fake central
  (`voice_plan_executor_test`), hold/release/typed/failure/cancel routing and
  the diagnostic stage lines (`voice_session_controller_test`), the hold gesture
  including release outside,
  pointer cancel and disposal while held (`hold_to_talk_button_test`), the legacy
  single-command routing (`voice_command_executor_test`), colour-picker math
  (`color_picker_test`), settings/activity persistence with mocked
  `SharedPreferences` (`app_settings_test`, `activity_log_test`), the Studio send
  path over a real driver + fake transport (`studio_page_test`) and the shell at
  desktop/mobile widths (`widget_test`). Newer suites: the Android FGS bridge with
  a mocked channel (`android_wake_service_test`), spoken-response policy
  (`voice_response_speaker_test`), the dormant LED-feedback abstraction
  (`led_feedback_test`) and the offline FFT prototype (`spectrum_test`).
  `wake_word_session_test.dart` drives the opt-in hands-free path with an
  in-memory `WakeCommandSource`: prewarm never starts the microphone, an
  explicit start is required, a hold pauses listening and resumes it after the
  take, a wake transcript goes through the same parser/executor, a parse failure
  executes nothing, and a failed start/failure is reported honestly.
  `assistant_recording_test.dart` drives the Assistant page with an injected
  in-memory recognizer: mouse/touch press, release outside, drag out, pointer
  cancel, rapid press/release, release during recorder open, repeated takes,
  navigation away, lifecycle change, recorder-stop failure and a hung stop. It
  must never use `pumpAndSettle` during a take (the pulse animation repeats);
  pump 12 × 20 ms instead. A plain
  `testWidgets` body that creates/disposes a service hangs on fake-async stream
  futures — create and dispose it inside `tester.runAsync`. The same applies to
  a `LeddmxDriver` created in `setUp`: construct it inside the test body,
  otherwise its chained write futures belong to another async zone and never
  complete under the fake clock.
- `tools/ble_probe/test/widget_test.dart` is skipped; real probe behavior needs
  physical BLE hardware. The service/state-machine tests use a fake `BleCentral`
  (`test/led_probe_service_test.dart`); GATT validation is pure
  (`test/gatt_profile_test.dart`).
- `walsey_voice_core/test/` is pure `dart test` (no microphone/network/hardware):
  normalization, power, colour, brightness, effect, safety/ambiguity and registry
  suites, plus literal multi-step plan expectations (`plan_parser_test.dart`).
  Expectations are literal, not derived from the parser.
  `paraphrase_and_status_test.dart` pins the literal paraphrase table, the fixed
  brightness qualifiers, the interrogative-only status intent and the unchanged
  negation/statement refusals. `voice_conversation_test.dart` pins the 10-minute
  expiry, immediate invalidation and the pronoun follow-up reconnect step.
- `walsey_voice_speech/test/` must stay microphone-, native-library- and
  internet-free: `FakeEngine`/`FakeCapture`/`TailCapture`/`GatedCapture` live in
  `test/support/fakes.dart` and drive both recognizer suites, a fake
  `SpeechRecognizer` drives the controller, and model installs (Vosk zip and
  Whisper single-file) run against a loopback `HttpServer`. Do not add tests
  that need a model archive, a real `record` channel or a native DLL. The
  `stop during a pending start` group in `vosk_recognizer_test.dart` pins the
  release/stop race (release while the recorder opens, release before the
  permission check, a recorder that fails to stop, a recorder that never
  answers); keep it green — it is the recognizer half of the hold-to-talk fix.
  The Whisper recognizer test fabricates its installed model with
  `truncate(147964211)` — keep the size pinned to
  `SpeechModel.whisperBaseEnglish.archiveSizeBytes`.
- `walsey_voice_speech/test/vosk_wake_word_detector_test.dart` (22) and
  `onnx_wake_word_detector_test.dart` (15) drive the detectors with
  `FakeEngine`/`FakeCapture` and a fake `WakeWordScorer`. They prove wiring and
  safety rules only; accuracy comes from `bin/wake_accuracy.dart` against real
  audio and is recorded in `docs/wake_word.md`.
- `voice_activity_test.dart` (9) drives the pure VAD with synthesized tone and
  silence: threshold, minimum speech, pause tolerance, silence tail,
  max-duration latch, split frames and reset.
- `wake_word_command_loop_test.dart` (7) drives the pre-roll → VAD → decode
  pipeline with the fake scorer and an in-memory `BufferedRecognizer`: no
  command after the wake word stays empty (the wake phrase is never decoded
  back as a command), the detector is stopped before transcription, a decode
  failure is surfaced without a retry, and auto-resume only follows a completed
  take.
- `apps/walsey_voice_test/test/widget_test.dart` covers typed Stage 1 flows;
  `test/speech_widget_test.dart` covers Stage 2 with a fake recognizer/model
  store, and must keep asserting that no execution control exists. The Stage 2
  page is taller than the default 800x600 surface: set `tester.view.physicalSize`
  before pumping or taps miss off-screen chips. Stream events need
  `pumpAndSettle`, and status text can appear both in the chip and on the button
  (use `findsWidgets`).
- Windows microphone capture **has** been exercised (2026-10-25): the production
  `record` path delivers 16 kHz mono PCM16 at the requested rate, with a ~65 ms
  first-chunk delay and no tail loss (the earlier "digital silence" report was
  ambient noise in an empty room; peak −11.45 dBFS). Android capture and model
  download are still unexercised. Do not claim Android or real-speech accuracy
  results before the checklist in `docs/voice_stage2.md` passes.
- Measured accuracy (synthetic SAPI corpus, both Vosk configurations and
  whisper.cpp) is in `docs/voice_accuracy.md`; reproduce it with
  `walsey_voice_speech/bin/voice_accuracy.dart` and `tools/voice_accuracy/`.
  The shipped configuration is now `ggml-base.en` (whisper.cpp, unconstrained);
  the Vosk constrained grammar stays opt-in only because the invented wake word
  is not in the model vocabulary.
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
`windows/vosk/`, `windows/whisper/` (DLLs + model),
`android/app/src/main/jniLibs-whisper/` or model archives and `build/`.
