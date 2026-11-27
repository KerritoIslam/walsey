# Plan: automations (trigger → condition → action)

**Status: not implemented. The Automations page is an honest placeholder with
no toggles, scheduler or execution engine.**

## The central conflict

The project rule is: **no frame is ever sent automatically.** An automation, by
definition, runs without a fresh button press. That is not a detail to hand-wave;
it is the first design decision.

Any implementation must add an explicit, user-created **armed** state:

- creating a routine is not the same as arming it;
- an armed routine is visible everywhere (badge, notification/dock, Activity);
- one action disarms everything;
- an automation can only run while the app process is alive and the user has
  accepted the risk;
- no hidden background service, no auto-start at boot, no silent frame.

If that consent model is not acceptable, automations should stay unimplemented.

## Proposed model

```dart
final class Routine {
  final String id;
  final String name;
  final Trigger trigger;
  final List<Condition> conditions;
  final List<RoutineAction> actions;
  final bool armed; // separate from existence
}

sealed class Trigger { /* deviceConnected, manualRun, schedule? */ }
sealed class Condition { /* connected, variantIs, ... */ }
sealed class RoutineAction { /* power / colour / brightness / effect / scene */ }
```

### Triggers that are honest today

| Trigger | Data source |
|---|---|
| A supported controller connects | `LedConnectionService` state stream |
| The user presses **Run now** | explicit UI action |
| A scene is applied | explicit UI action |

Do **not** offer "brightness is below X", "the lights are red" or "effect
finished": the protocol has no read-back, so those conditions cannot be
evaluated.

### Conditions that are honest today

- connected / not connected;
- resolved layout (`filler` / `shifted`);
- app foreground state;
- time-of-day (a real clock value).

Anything about LED state is not available.

## Execution

- Reuse the existing typed command facade and `WriteQueue`; no parallel path.
- Run actions in order, stop on the first failure, report each step.
- A failed condition skips the actions and records "not run".
- A write is reported as a write, never as a visible change.
- Disarming or stopping cancels the remaining actions; an in-flight write may
  still complete (the platform write cannot be cancelled) and must be reported.
- Store an execution ledger with real outcomes. Never synthesize a result.

## Delivery stages

1. **Data + UI only** — create/edit/arm/disarm routines, persist locally, no
   execution. Prove the consent model is clear.
2. **Manual run** — `Run now` executes the same plan path as the Assistant.
3. **Connection trigger** — the existing connection stream fires an armed
   routine. Add a prominent armed indicator and a one-tap disarm.
4. **Scenes integration** — an action may apply a saved scene
   ([`scenes.md`](scenes.md)).
5. **Scheduling** — only if a foreground/background model is designed per
   platform. Windows has no mobile-style background service; do not promise it.

## Tests

- Routine validation: empty actions, unsupported condition, duplicate/contradictory
  actions, bounded size.
- Persistence: round-trip, corrupt data, migration, armed state after restart.
- Execution: order, stop-on-failure, failed condition, disarm mid-run, no write
  when not armed, write-vs-LED reporting.
- App: no routine runs at launch; arming is explicit; the armed indicator is
  visible; a link loss fails the run and does not reconnect.

## Acceptance

- Nothing runs unless the user explicitly armed it.
- No automation can claim device state.
- No hidden background capture/connection.
- The same command path and evidence rules as manual control.
