# Walsey voice test (Stage 2)

Small Flutter testbed for offline speech recognition and voice command
understanding. Press the microphone and say a command, or type one; both go
through the **same** Stage 1 parser, and the page shows the recognized text,
the intent, the parameters, the validation status and an explanation.

**Nothing is executed.** The app imports `walsey_voice_core` and
`walsey_voice_speech` only; there is no BLE dependency and no path to the LED
service. Every result says "Not executed — Stage 2 testing mode".

Recognition is fully offline with Vosk. It needs a one-time, explicit model
download per language; nothing is downloaded at startup.

## Run

```bash
flutter pub get
flutter analyze
flutter test
```

Android (model comes from Maven, no extra step):

```bash
flutter run -d <android-device-id>
```

Windows (needs the native DLLs once):

```powershell
powershell -ExecutionPolicy Bypass -File ..\..\tools\fetch_vosk_windows.ps1
flutter run -d windows
```

If the DLLs are missing the app still runs and explains that the native library
is unavailable; typed commands keep working.

## First run

1. Press **Language models** and install `vosk-model-small-en-us-0.15`
   (about 40 MB, MD5 verified, Apache 2.0).
2. Allow the microphone permission when prompted.
3. Press **Start listening**, say e.g. "set brightness to fifty percent", then
   **Stop & recognize**.
4. Disable the network and repeat: recognition must still work.

The model manager also offers French and Modern Standard Arabic models. They
recognize those languages, but the command parser is English-only, so their
results usually end as unsupported commands. Algerian Darija has no Vosk model;
it is selectable and clearly marked unavailable.

## What to try

- Valid: `Walsey, make the lights blue.`, `set brightness to 50 percent`,
  `increase brightness`, `activate effect 5`.
- Unsupported: `Tell me a joke`, `open Chrome`, `I don't want the lights on`.
- Ambiguous: `turn the lights on and off`,
  `make the lights blue and set brightness to 50 percent`.
- Invalid: `set brightness to 150 percent`, `make the lights teal`,
  `activate effect 999`.

A successful recognition that produces an unsupported or invalid command is
shown as exactly that; the parser is never loosened to make transcription
errors pass.

Architecture, the Vosk decision, model catalogue, offline semantics and the
manual hardware checklist: `docs/voice_stage2.md`. Stage 1 parser rules:
`docs/voice_stage1.md`.
