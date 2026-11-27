# App shell, services and local state

This document explains how `apps/walsey` is assembled and why the UI never
pretends to know more than the protocol does.

## 1. Shell and navigation

`lib/app/app_shell.dart` is a responsive shell over a single service graph.

| Platform | Navigation |
|---|---|
| Windows / wide | Fixed sidebar: Home, Devices, Connect (planned), Studio, Automations (planned), Assistant, Activity, Settings. Optional diagnostics dock below content |
| Android / narrow | Five bottom destinations: Home, Devices, Studio, Assistant, Settings. Activity is reached from Home or Settings |

Shared pieces live in `lib/design/`:

- tokens, colours and typography;
- `WPageBody`, `WCard`, `WListRow`, `WBadge`, `WInfoBanner`,
  `WPlannedFeature`;
- the colour picker and the hold-to-talk button.

Pages live in `lib/features/`:

| Page | State |
|---|---|
| Home | Real connection summary + quick actions |
| Devices + device details/hardware test | Real scan/connect/validate + controlled first-hardware sequence |
| Studio | Real power/colour/brightness/effect commands; segments and music shown as unsupported |
| Assistant | Real hold-to-talk, recognition, plans, execution, optional TTS, opt-in wake card |
| Activity / Diagnostics | Real event log and measured values |
| Settings | Persisted local preferences |
| Connect (Phone ↔ PC) | Honest planned-capability page, no controls |
| Automations | Honest planned-capability page, no controls |

`WPlannedFeature` exists so a planned page can explain requirements without
rendering a fake button. Studio reports unsupported features instead of
simulating them.

## 2. Service graph

```
main.dart
  └─ LedConnectionService
       ├─ PluginBleCentral        (walsey_led_ble)
       ├─ LeddmxDriver            (attached after FFE0/FFE1 validation)
       └─ LedControlService       (typed UI facade, logging, activity)
  └─ AppSettingsService          (shared_preferences)
  └─ ActivityLog                 (shared_preferences, bounded)
  └─ Assistant page
       ├─ VoiceSessionController (hold-to-talk + wake orchestration)
       ├─ VoicePlanParser        (pure interpreter)
       ├─ VoicePlanExecutor      (over LedConnectionService)
       └─ VoiceResponseSpeaker   (optional TTS)
```

Services are constructed once and passed down; widgets do not open BLE or parse
text themselves. This keeps the protocol and parser testable outside Flutter.

### `LedConnectionService`

Owns the connection state machine and exposes a stream of
`AppConnectionState`. It enforces scan/connect rules, validates GATT, binds the
driver and never sends a frame by itself. It also holds the `LedControlService`
facade and the diagnostic log sink.

### `LedControlService`

The only typed UI facade for LED commands:

- calls `LeddmxDriver` methods;
- serialises one command at a time;
- logs command, redacted frame, write mode and result;
- records an activity entry;
- exposes "last command sent", never "current LED state".

### `VoiceSessionController`

Owns the single voice session, the take id, the hold watchdog, wake
orchestration and the phase machine. Recognition, interpretation and execution
are separate phases. A parser failure never reaches the executor; a typed
sentence is never executed. See [`voice-assistant.md`](voice-assistant.md).

## 3. Local state

Everything stored locally is preference/ledger data. No device state is stored,
because the protocol cannot report it.

### `AppSettingsService`

Persisted with `shared_preferences`:

| Key | Default | Meaning |
|---|---|---|
| `walsey.accent` | platform default | Accent colour |
| `walsey.displayName` | `''` | Optional personal name; empty means the UI shows no personal greeting |
| `walsey.showDiagnosticsPanel` | `true` | Desktop diagnostic dock visibility |
| `walsey.spokenResponses` | `false` | Opt-in short TTS outcomes |
| `walsey.wakeWordEnabled` | `false` | User consent for hands-free listening |
| `walsey.favoriteColors` | empty | Locally saved Studio swatches |
| `walsey.lastDeviceName` / `walsey.lastDeviceAt` | none | Convenience label only, not a connection target |

Consent and activation are separate: `wakeWordEnabled` records the user's
preference, but listening starts only from the explicit **Start listening**
button and stops immediately when consent is turned off.

### `ActivityLog`

A bounded local ledger of app events. Entries describe:

- connection state changes;
- commands and their real write result;
- voice session/recognition/interpretation/execution stages;
- user observations recorded manually.

Activity is not telemetry: nothing leaves the device. An entry can say
`BLE WRITE OK`; it cannot say "the LEDs are green".

## 4. Diagnostics

Every app log line is printed as `[WalseyApp] <time>  <text>` and also written
with `developer.log(name: 'WalseyApp')`. The same lines appear in:

- the Windows diagnostic dock (if enabled);
- Activity → Diagnostics;
- Settings → Open diagnostics;
- `adb logcat -s flutter:D`.

Fixed prefixes are shared with the voice pipeline (see
[`voice-assistant.md`](voice-assistant.md#8-diagnostics-one-prefix-one-meaning)).
The log is the audit trail for the first hardware test; a human observation is
recorded next to the write result, separately.

## 5. Honesty rules visible in the UI

| Situation | UI behaviour |
|---|---|
| Advertised name is not a documented `LEDDMX-NN` | Controls disabled with the reason |
| GATT validation fails | Connection aborts, no driver bound |
| Write fails/times out | `FAILED`, controls explain the blocked queue |
| No frame sent yet | "Last command sent", never "current state" |
| Status question | Answer says the protocol has no read-back; nothing sent |
| Plan wrote nothing | "Nothing sent", not "Executed" |
| Typed input | Interpretation only, explicitly not executed |
| Wake model/backend missing | Card says so; no fake listening control |
| Music/segments | "Not supported"; no simulated output |
| Phone↔PC / Automations | Requirements only; no pretend controls |

## 6. Where to add a feature

1. Put protocol knowledge in `walsey_led_core`, not in a widget.
2. Put recognition/parser knowledge in `walsey_voice_core` or
   `walsey_voice_speech`, not in the app.
3. Add an app service method only for UI orchestration/logging.
4. Add the honest state to the UI: unavailable, planned, failed, or "write
   completed". Never a guessed success.
5. Add a test at the lowest layer that can prove the behaviour, then an app test
   for the wiring.
6. Update the relevant `docs/` reference and the hardware checklist if hardware
   behaviour is involved.
