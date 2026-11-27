# How Walsey works

Walsey is two cooperating stacks that never shortcut each other:

```
┌────────────────────────────── An app ───────────────────────────────┐
│  Flutter UI (apps/walsey, apps/walsey_voice_test)                   │
│    ├─ LED pages + Assistant                                         │
│    ├─ App services: connection, control, voice session/executor     │
│    └─ Local state: settings, activity ledger                       │
└───────────────┬───────────────────────────────┬─────────────────────┘
                │ typed LED calls               │ speech / plans
                ▼                               ▼
┌───────────────────────────┐   ┌─────────────────────────────────────┐
│ LED stack                 │   │ Voice stack                         │
│ walsey_led_core (pure)    │   │ walsey_voice_core (pure)            │
│  domain → protocol →      │   │  normalize → parse → validate →     │
│  driver → WriteQueue      │   │  registry → plan                    │
│        │                  │   │        │                            │
│        ▼ LedTransport     │   │        ▼ SpeechRecognizer port      │
│ walsey_led_ble (Flutter)  │   │ walsey_voice_speech (Flutter)       │
│  PluginLedTransport       │   │  record → Whisper/Vosk → transcript │
│  PluginBleCentral         │   │  VAD + wake pipeline                │
└───────────┬───────────────┘   └─────────────────┬───────────────────┘
            ▼                                     │
     bluetooth_low_energy                         │ transcript
            ▼                                     ▼
     LEDDMX controller                 the *main app* maps plan steps → LED
```

The voice packages deliberately do not import `walsey_led_core` or
`walsey_led_ble`. A transcript can only affect the LEDs after the main app's
executor converts validated plan steps into typed calls on the existing
connection/control services. The pure voice packages never originate a BLE
byte.

## The two flows, end to end

### A. Manual LED command

1. **Scan** — `LedConnectionService` asks `BleCentral` for advertisements. The
   advertised name must match `LEDDMX-NN[-suffix]`.
2. **Resolve** — `resolveLeddmxVariant` maps the number to `filler` (`00/01/03`)
   or `shifted` (`02/04`). Anything else stays `UnsupportedVariant`; controls
   stay disabled.
3. **Connect + validate** — GATT discovery must find FFE0 and FFE1 with the
   required properties. Validation only; no frame is written.
4. **Bind** — the service attaches a `LeddmxDriver` to a `PluginLedTransport`.
5. **Command** — a UI action calls `LedControlService`, which calls a typed
   `LeddmxDriver` method. The driver encodes one 9-byte frame with a pure
   function, then `WriteQueue` serialises the write.
6. **Report** — a completed write becomes `BLE WRITE OK`. The app records the
   frame and the manual observation, never a device state.

### B. Hold-to-talk command

1. **Press** — `VoiceSessionController.press()` starts one session. Spoken
   responses are silenced first; a second press while busy is ignored.
2. **Capture** — `record` delivers 16 kHz mono PCM16 through
   `EngineSpeechRecognizer`.
3. **Recognize** — the worker isolate decodes with whisper.cpp (batch) or Vosk
   (streaming fallback). A transcript is returned verbatim.
4. **Release** — a release (inside or outside the button) stops the take. If the
   pointer-up was lost, the 2 s watchdog or 60 s cap stops it. The UI phase only
   changes after the recognizer was asked to stop.
5. **Interpret** — `VoicePlanParser` parses one command or an ordered plan. A
   parser failure stops here; nothing is executed.
6. **Execute** — only for recognized speech, `VoicePlanExecutor` runs steps in
   order over `LedConnectionService`, re-checking prerequisites and stopping on
   the first failure.
7. **Report** — each step reports a real write result. A write-free plan (status
   question, scan-only plan) is labelled "nothing sent", never "Executed".

### C. Optional hands-free path (pipeline present, model absent)

1. The user turns on consent and presses **Start listening**.
2. `WakeWordCommandLoop` starts a detector, with one microphone consumer only.
3. A detection keeps 1.5 s of pre-roll, starts a VAD, **stops the detector**, and
   batch-decodes the captured command.
4. The resulting transcript goes through the same parser/executor. No speech
   after the wake word produces an empty result, not a decode of "Walsey".
5. Nothing starts at launch and no placeholder model ships, so in this build the
   Assistant truthfully says the feature is unavailable.

## Package boundaries

| Package | May depend on | Must not |
|---|---|---|
| `walsey_led_core` | Dart only | Flutter, BLE plugins, I/O in encoders |
| `walsey_led_ble` | `walsey_led_core`, Flutter, `bluetooth_low_energy` | Logic that belongs in the driver/queue |
| `walsey_voice_core` | Dart only | Flutter, BLE, microphone, network, LLM, LED packages |
| `walsey_voice_speech` | `walsey_voice_core`, Flutter, record, FFI/ONNX | Parsing duplication, BLE imports, execution |
| `apps/walsey` | Both LED packages, both voice packages | Putting protocol or parsing logic in widgets |
| `apps/walsey_voice_test` | Both voice packages | LED packages, execution, wake start |
| `tools/ble_probe` | Its own copy of the BLE port/adapter | Stage 2 packages, any write/handshake/notify |

`walsey_led_ble` exists because `bluetooth_low_energy` is a Flutter plugin;
depending on it from the core would break pure `dart test`. `walsey_voice_core`
exists for the same reason: parser tests must run without Flutter, a microphone,
a model or a native library.

## Why the safety rules exist

- **No automatic frames.** The vendor app authenticates on connect and may send
  state; this project treats every frame as a user action. That is why the
  handshake is a button, why automations need an explicit consent design, and
  why a status question sends nothing.
- **No state claims.** The protocol has no read-back. `DeviceState.lastCommand`
  means "the last frame we wrote", not "the strip is now red". The only device
  reply is the password-status notification.
- **Parser failures are honest.** A recognized but unparseable sentence is a
  legitimate outcome. Loosening the grammar to make a demo work would create
  commands the user did not say.
- **Missing models disable features.** A wake-word card without a model, a
  language without a model, and a music mode without a hardware-verified frame
  all say "not available" instead of showing decorative controls.

## Reading order

1. This file — the map.
2. [`led-control.md`](led-control.md) — frames, variants, transport, driver, queue.
3. [`voice-assistant.md`](voice-assistant.md) — capture, engines, parser, plans,
   execution, wake pipeline, diagnostics.
4. [`app-and-state.md`](app-and-state.md) — shell, settings, activity, honesty in UI.
5. [`development.md`](development.md) — commands, native setup, test pitfalls.
6. [`../planned/README.md`](../planned/README.md) — what comes next and why.
