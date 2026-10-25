# Voice assistant — Stage 1 (parse and test, no execution)

Stage 1 adds a deterministic, offline command-understanding core plus a small
testing app. It does **not** listen to a microphone, recognize speech, detect a
wake word, open Bluetooth, or execute anything.

Stage 1 is still the parser documented here. Stage 2 adds offline push-to-talk
recognition in front of the same parser without changing it — see
`docs/voice_stage2.md`.

The three-stage roadmap remains:

| Stage | Scope | State |
|---|---|---|
| 1 | Text → intent → validated parameters; testing UI | implemented |
| 2 | Push-to-talk speech recognition feeding the Stage 1 parser | **implemented now** |
| 3 | Wake word, LED execution through `LedControlService`, platform actions | not started |

## Packages

```
walsey_voice_core/            PURE DART. No Flutter, BLE, microphone or network.
walsey_voice_speech/          Flutter adapter: Vosk + microphone + model setup.
apps/walsey_voice_test/       Flutter testbed: speech or text + interpretation.
```

The main app (`apps/walsey`) and both LED packages are unchanged.

Why the voice core does not depend on `walsey_led_core`: the assistant will
eventually route several domains (LED, Windows system, applications, audio).
Keeping the core domain-neutral avoids making system commands depend on the LED
model. A future Stage 3 adapter maps `VoiceColor` → `RgbColor`,
`VoiceBrightness` → `BrightnessLevel` and `VoiceEffect` → `LedEffect`, then
calls the existing `LedControlService`. No BLE byte ever originates in the voice
layer.

```
apps/walsey_voice_test
  ↓ VoiceResult (typed, display-only)
walsey_voice_core
  normalize → parse → validate → registry authorization
  ↓ (Stage 3, not implemented)
future adapter → apps/walsey LedControlService → LeddmxDriver → BLE
```

## Command model

`VoiceIntent` is a closed enum. `intent.name` is the stable action id shown in
the UI (`powerOn`, `setColor`, …). Parameters are sealed classes, not maps:

- `NoParameters` — power on/off, relative brightness.
- `ColorParameters(VoiceColor)` — fixed name/RGB entry.
- `BrightnessParameters(VoiceBrightness)` — whole percent 0..100.
- `EffectParameters(VoiceEffect)` — id 1..210 or 255.

`VoiceResult` is sealed:

- `VoiceCommandResult` — parsed and validated; `executionStatus` is still
  `notExecuted`.
- `VoiceFailure` — `emptyInput`, `unsupported`, `ambiguous`, `missingParameter`
  or `invalidParameter`, with a user-facing explanation and, where relevant,
  the intent that was recognized.

Parsing never implies execution. The execution row in the UI always reads
"Not executed — Stage 2 testing mode" until a real executor exists.

## Supported grammar

| Intent | Examples |
|---|---|
| `powerOn` | "turn the lights on", "switch on the lights", "lights on", "Walsey, turn the lights on." |
| `powerOff` | "turn off the lights", "switch the lights off", "lights off", "shut the lights off" |
| `setColor` | "make the lights blue", "set the color to blue", "change the lights to red", "turn the lights green" |
| `setBrightness` | "set brightness to 50 percent", "brightness 50%", "set the brightness to 30", "make the lights 50 percent" |
| `increaseBrightness` | "increase brightness", "make the lights brighter", "brighten the lights", "turn up the brightness" |
| `decreaseBrightness` | "decrease brightness", "make the lights dimmer", "dim the lights", "turn down the brightness" |
| `applyEffect` | "activate effect 5", "apply effect 255", "effect 210" |

Normalization lowercases, trims, collapses whitespace, strips punctuation,
converts `%` to "percent", removes apostrophes for negation detection, keeps
signed/decimal numbers whole, and strips a leading "Walsey"/"hey Walsey".
Word numbers (`fifty`, `one hundred`) are accepted for brightness and effects.

## Validation rules

- **Brightness**: whole percentage 0..100. Out-of-range, negative and decimal
  values are `invalidParameter`; nothing is clamped. Two different values are
  `ambiguous`. Missing or non-numeric values are `missingParameter` /
  `invalidParameter`.
- **Colour**: controlled list only — red, green, blue, white, yellow, orange,
  purple, pink, cyan, magenta (plus `violet` → purple, `turquoise` → cyan).
  Unknown names such as "teal" are rejected, not passed through. Multiple
  colours are ambiguous.
- **Effects**: ids 1..210 and 255, matching `LedEffect` in `walsey_led_core`.
  The existing app exposes no effect names, so none are invented. Relative
  requests ("next effect") are refused: the protocol has no effect-state
  read-back.
- **Relative brightness** is recognized as an intent, but Stage 3 will need a
  trustworthy current-brightness value or must refuse execution. The protocol
  has no state read-back today.

## Safety behaviour

- A statement or question ("the lights are on", "how do I turn on the lights")
  is not a command.
- Negated or hypothetical sentences ("I don't want the lights on") are
  refused; they are never inverted into the opposite action.
- One sentence with two actions ("turn on the lights and set brightness to 50")
  or contradictory states ("on and off") is `ambiguous`; the parser never
  picks one silently.
- Mentions of unregistered actions ("open Chrome") or non-LED devices
  ("volume", "tv") are refused instead of being ignored while another action
  runs.
- Unrelated sentences containing "blue", "on", etc. do not become commands.

## Registry and future stages

`CommandRegistry` is the immutable allowlist and extension point. The parser
turns an intent into a command only when its `VoiceActionSpec` is registered;
an empty registry makes every parse fail with "not in this command registry".
Stage 1 registers one domain (`led`) and seven actions. Stage 3 adds specs and
an executor; it does not need to change normalization, parsing or result types.
A future AI interpreter, if ever added, must produce the same `VoiceIntent` +
validated-parameter shape and pass through this registry.

## Run

```bash
cd walsey_voice_core
dart pub get
dart analyze
dart test

cd ../apps/walsey_voice_test
flutter pub get
flutter analyze
flutter test
flutter run -d <android-device-id>      # or -d windows
```

No BLE, microphone, network or API key is required. Because the testbed has no
BLE plugin, it is not affected by the Windows plugin build blocker described in
the root README.

## Limitations

- English only. Stage 2 adds English speech recognition; the parser itself
  remains English-only. Other recognition languages produce French/Arabic text
  that the parser rejects as unsupported.
- No device state: "brighter" and "next effect" are understood structurally but
  cannot be resolved to a safe absolute command yet.
- Effect names and arbitrary RGB values are intentionally unsupported.
- Stage 1 makes no claim about hardware behaviour.
