# Planned features

Everything in this directory is **not implemented** unless a document says
otherwise in its first paragraph. A plan is not a capability, and a placeholder
page is not a feature.

The repository deliberately keeps some pages and seams visible so the roadmap is
honest and the eventual feature has a home. These documents explain the current
state, the design constraints, and a concrete implementation path.

## Priority order

| Priority | Feature | Why now | Main blocker |
|---|---|---|---|
| 1 | [ONNX wake word](onnx-wake-word.md) | The detector seam, VAD, pre-roll loop, opt-in app wiring and foreground-service shell already exist. Only the model/backend is missing | A trained "Walsey" model, a calibrated keyword set and a real false-activation measurement |
| 2 | [Windows BLE + first hardware sign-off](windows-ble-and-hardware.md) | No frame has ever been sent to the target controller; this gates every LED claim | A controller, a Windows BLE adapter, and the hardware checklist |
| 3 | [Scenes](scenes.md) | `SaveSceneStep` is already recognized by the plan grammar | No scene model, store, validator or executor |
| 4 | [Automations](automations.md) | The app has real connection/command events to build on | The no-automatic-frame rule needs an explicit consent design |
| 5 | [Voice intent ML](voice-intent-ml.md) | Phase 1 audio features exist | Labeled human corpus, classifier, ONNX export, parity tests |
| 6 | [Phone ↔ PC](phone-pc-connect.md) | A visible planned page exists | Pairing/trust, transport, platform permissions, two-device tests |
| 7 | [Music-reactive mode](music-reactive-mode.md) | Offline FFT prototype exists | Hardware-verified frames, pacing, audio-capture design |
| 8 | [LED segments](led-segments.md) | Studio correctly reports it unsupported | Protocol evidence for a per-zone command |

## Definition of done for any planned feature

A feature is done only when all of these are true:

1. **Typed path** — commands go through the existing domain types, registry and
   command facade. No second command path, no raw bytes from UI code.
2. **Honest evidence** — a write is reported as a write; a device state claim
   requires read-back that the protocol does not have.
3. **Explicit start** — nothing listens, sends or runs automatically without a
   user action and, where relevant, an explicit consent step.
4. **Failure handling** — permission denial, missing model, link loss, timeout
   and cancellation produce visible, distinct outcomes.
5. **Tests at the lowest layer** — pure unit tests plus app wiring tests; no
   test may require a microphone, a model archive, the internet or hardware
   unless it is explicitly a hardware checklist item.
6. **Docs updated** — the reference document, this plan (mark it implemented or
   remove it), `docs/README.md`, and the hardware checklist when applicable.
7. **No fake UI** — while a prerequisite is missing, the control is disabled or
   absent with an explanation.

## Cross-cutting constraints

- **Offline first.** No cloud recognizer, no audio upload, no mandatory network
  fallback. Model downloads are explicit and verified.
- **No state invention.** The LEDDMX protocol has no read-back. A feature that
  needs current brightness, current effect or current zone must either take the
  value from the user or refuse.
- **One microphone consumer.** Hold-to-talk, hands-free listening and any future
  music capture cannot run simultaneously without a new arbitration design.
- **Android background limits.** A long-running microphone consumer needs a
  visible foreground service. Windows has no equivalent background model.
- **No weakening of validation.** New user phrasings extend the literal
  paraphrase table or the explicit grammar; they never add fuzzy scoring that
  could turn a statement or negation into a command.
- **Native dependencies are explicit.** Never commit models or DLLs; never add a
  startup download.

## Relationship to the current docs

| Planned doc | Current reference |
|---|---|
| `onnx-wake-word.md` | [`../wake_word.md`](../wake_word.md), [`../voice_assistant_report.md`](../voice_assistant_report.md) |
| `windows-ble-and-hardware.md` | [`../hardware_checklist.md`](../hardware_checklist.md), [`../research.md`](../research.md) |
| `scenes.md` | [`../architecture.md`](../architecture.md), [`../voice_stage1.md`](../voice_stage1.md) |
| `automations.md` | The placeholder `apps/walsey/lib/features/automations/automations_page.dart` |
| `voice-intent-ml.md` | [`../voice_intent_ml.md`](../voice_intent_ml.md) |
| `phone-pc-connect.md` | The placeholder `apps/walsey/lib/features/connect/connect_page.dart` |
| `music-reactive-mode.md` | [`../music_mode.md`](../music_mode.md) |
| `led-segments.md` | [`../led_segments.md`](../led_segments.md) |
