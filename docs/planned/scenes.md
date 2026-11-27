# Plan: scenes (saved multi-command LED states)

**Status: not implemented. The plan grammar already recognises a scene phrase
and produces a `SaveSceneStep`, but there is no scene model, store, validator or
executor.** Nothing is saved, listed or applied today.

## What exists

- `walsey_voice_core/lib/src/plan/voice_plan.dart` defines `SaveSceneStep`.
- The Assistant reports a scene request as recognized but not executed.
- The app has no scene storage, no scene page and no scene command.

## What a scene is (and is not)

A scene is an **ordered list of validated LED steps** — for example
`power on → colour warm white → brightness 40 → effect 3`. It is not:

- a raw frame blob;
- a second command language;
- a claim about device state (the protocol has no read-back);
- an automation trigger (that is [`automations.md`](automations.md)).

## Proposed model

```dart
final class Scene {
  final String id;
  final String name;
  final DateTime createdAt;
  final List<SceneStep> steps; // validated, bounded
}

sealed class SceneStep { /* power / colour / brightness / effect */ }
```

Rules:

- Steps use the existing domain value objects (`RgbColor`, `BrightnessLevel`,
  `LedEffect`), not raw bytes.
- A scene cannot contain a scan/connect/disconnect/query step. Applying a scene
  never changes the connection.
- A scene cannot contain another scene, and the step count is bounded.
- The validator rejects an empty scene, duplicate contradictory steps and
  anything outside the existing validation ranges.

## Where it lives

- Pure model + validator in `walsey_led_core` (the directory currently claimed
  as `lib/src/scenes/` in `architecture.md` does not exist yet; adding it is the
  first edit).
- Persistence in `apps/walsey/lib/state/` (JSON through the existing local
  storage approach). Scenes are user data, not device state.
- Application logic in `apps/walsey/lib/voice/voice_plan_executor.dart` or a
  small `SceneExecutor` that expands a scene into the existing typed calls.
  Do not add a second BLE path.

## Voice grammar

Add an explicit plan grammar:

| Utterance | Result |
|---|---|
| `save movie night as power on, warm white and brightness 40` | `SaveSceneStep` with explicit validated steps |
| `apply movie night` | `ApplySceneStep(sceneId)` |
| `delete movie night` | explicit confirmation flow |

Important: the protocol has no read-back, so a bare **"save this as movie
night"** cannot capture the controller's current state. A first version should
support only explicit steps in the same sentence, or saving from the Studio's
current draft with the user confirming the exact steps. Do not infer a scene from
an imagined current colour. If the user asks to save "this", explain that the
protocol cannot report the current state and ask for the steps.

## Applying a scene

1. Require a connected, validated supported variant.
2. Run steps strictly in order through the existing control service.
3. Stop on the first failure; report later steps as not run.
4. Report each step as a write, never as a confirmed LED state.
5. Never send anything automatically on connect, app start or scene selection
   without an explicit **Apply** action.

## Tests

- Validator: ranges, empty, duplicates, recursion, step count, unsupported
  step kinds.
- Store: round-trip, corrupt JSON, missing scene, delete, name collision policy.
- Executor: order, stop-on-failure, prerequisite re-check, no write on a failed
  parse, write-vs-LED reporting.
- App: save/apply buttons are explicit; no scene runs on launch; typed and voice
  paths share the validator.

## Acceptance

- A scene is data, fully validated before any frame.
- No scene can bypass `LedControlService` or the `WriteQueue`.
- No scene claims device state.
- Scenes survive restart locally, with no network and no telemetry.
