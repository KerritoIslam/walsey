# Walsey documentation

This directory is the source of truth for how Walsey works, what is verified,
and what is still planned. If a claim is not backed by a test or a hardware
observation recorded here, it is not a claim the project makes.

## Start here

| If you want to… | Read |
|---|---|
| Understand the whole system in one pass | [`how-it-works/README.md`](how-it-works/README.md) |
| Work on LED protocol, frames or BLE | [`how-it-works/led-control.md`](how-it-works/led-control.md), then [`research.md`](research.md) |
| Work on speech, parsing, plans or the Assistant | [`how-it-works/voice-assistant.md`](how-it-works/voice-assistant.md) |
| Work on the app shell, settings or activity ledger | [`how-it-works/app-and-state.md`](how-it-works/app-and-state.md) |
| Build, test or add a native dependency | [`how-it-works/development.md`](how-it-works/development.md) |
| Pick up a planned feature | [`planned/README.md`](planned/README.md) |
| Test on the real controller | [`hardware_checklist.md`](hardware_checklist.md) |

## Reference documents

| Document | Contents |
|---|---|
| [`architecture.md`](architecture.md) | Package boundaries, layer split, public APIs, dependency table |
| [`research.md`](research.md) | Sources, decompiled frame evidence, variant analysis, open questions |
| [`hardware_checklist.md`](hardware_checklist.md) | Every hardware test and the evidence sign-off rule |
| [`voice_stage1.md`](voice_stage1.md) | Deterministic parser, validation, registry, safety behaviour |
| [`voice_stage2.md`](voice_stage2.md) | Recognition pipeline, engines, models, platform setup, manual checklist |
| [`voice_accuracy.md`](voice_accuracy.md) | Measured recognition accuracy, decoder bias, engine comparison |
| [`voice_assistant_report.md`](voice_assistant_report.md) | Hold-to-talk fix, failure analysis, wake benchmarks, current measured state |
| [`voice_intent_ml.md`](voice_intent_ml.md) | Phase 1 raw-audio log-Mel feature pipeline |
| [`wake_word.md`](wake_word.md) | Wake pipeline, Vosk measurement, platform constraints, what a shipped detector needs |
| [`music_mode.md`](music_mode.md) | Music-reactive investigation and offline FFT prototype |
| [`led_segments.md`](led_segments.md) | Split-by-parts investigation and why it is unsupported |

## Planned documents

| Document | Feature | Status |
|---|---|---|
| [`planned/onnx-wake-word.md`](planned/onnx-wake-word.md) | Real "Walsey" wake word through an ONNX/keyword-spotter backend | Highest priority; pipeline already exists |
| [`planned/voice-intent-ml.md`](planned/voice-intent-ml.md) | Acoustic intent classifier (raw audio, not transcripts) | Research, Phase 1 exists |
| [`planned/scenes.md`](planned/scenes.md) | Save/apply multi-command LED scenes | Data model only |
| [`planned/automations.md`](planned/automations.md) | Trigger → condition → action routines | Placeholder page |
| [`planned/phone-pc-connect.md`](planned/phone-pc-connect.md) | Pairing, file/clipboard/notification sync | Placeholder page |
| [`planned/music-reactive-mode.md`](planned/music-reactive-mode.md) | Audio-reactive LED output | Offline prototype only |
| [`planned/led-segments.md`](planned/led-segments.md) | Per-zone / split-by-parts control | Blocked on protocol evidence |
| [`planned/windows-ble-and-hardware.md`](planned/windows-ble-and-hardware.md) | Windows BLE validation and first-hardware sign-off | Build passes, hardware unrun |

## Documentation rules

These mirror the project rules in `AGENTS.md`:

1. **Do not upgrade evidence without hardware.** Frame layouts stay
   `decompiledApp` until the matching checklist rows pass on Windows *and*
   Android.
2. **"BLE write OK" is not "the LEDs changed".** Only `USER OBSERVATION:` records
   a visible change.
3. **Do not document a feature as working because code exists.** A detector with
   no model, a page with no engine, or a control with no caller is "implemented
   but not available", not "working".
4. **Planned documents describe a plan, not current behaviour.** If a step is
   unbuilt, say so in the same sentence.
5. **Keep fixed diagnostic prefixes unique.** `VOICE SESSION:`, `WAKE WORD:`,
   `VOICE RECOGNIZED:`, `VOICE INTERPRETED:`, `ACTION STARTED:`,
   `PLAN STEP i/n`, `RESULT … BLE WRITE OK`, `HARDWARE RESPONSE: PASSWORD
   REPLY:`, `USER OBSERVATION:` each mean exactly one thing.
6. **Do not loosen validation to make a demo pass.** No invented colours, effect
   ids, brightness clamping or fuzzy parsing.
