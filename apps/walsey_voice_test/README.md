# Walsey voice test (Stage 2)

Small Flutter testbed for offline speech recognition and voice command
understanding. Press the microphone and say a command, or type one; both go
through the **same** Stage 1 parser, and the page shows the recognized text,
the intent, the parameters, the validation status and an explanation.

**Nothing is executed.** The app imports `walsey_voice_core` and
`walsey_voice_speech` only; there is no BLE dependency and no path to the LED
service. Every result says "Not executed — Stage 2 testing mode".

Recognition is fully offline. The primary engine is **whisper.cpp**
(`ggml-base.en`, ~141 MB, English-only); Vosk stays available as a fallback
engine. Both need a one-time, explicit model download; nothing is downloaded at
startup. Whisper decodes the whole utterance at "Stop & recognize", so no
partial text appears while you speak.

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

Windows (needs the native DLLs once, for the engine(s) you want to run):

```powershell
# Whisper (primary engine): official b5454 binaries + ggml-base.en model
powershell -ExecutionPolicy Bypass -File ..\..\tools\fetch_whisper_windows.ps1
# Vosk (fallback engine)
powershell -ExecutionPolicy Bypass -File ..\..\tools\fetch_vosk_windows.ps1
flutter run -d windows
```

If a native library is missing the app still runs and explains that the engine
is unavailable; typed commands keep working.

Android (the Vosk model comes from Maven; whisper.cpp is built from source
once by `tools/build_whisper_android.ps1` into the gitignored
`jniLibs-whisper/` folder, which Gradle then packages):

```bash
flutter run -d <android-device-id>
```

## First run

1. Press **Language models** and install `ggml-base.en` (~141 MB, size + MD5 +
   SHA-256 verified, MIT). On a developer Windows build a verified copy is
   already placed in `models/` next to the exe by the build, so the model
   status may show installed immediately.
2. Allow the microphone permission when prompted.
3. Press **Start listening**, say e.g. "set brightness to fifty percent", then
   **Stop & recognize** (Whisper decodes then; there is no partial text before
   this).
4. Disable the network and repeat: recognition must still work.

The model manager also lists the three Vosk fallback models
(`vosk-model-small-en-us-0.15`, French, Modern Standard Arabic). They recognize
those languages, but the command parser is English-only, so their results
usually end as unsupported commands. With the Whisper engine, French and
Arabic are disabled in the language selector (no Whisper model in this build);
Algerian Darija has no offline model at all — it is selectable and clearly
marked unavailable.

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

Architecture, the engine decision (Whisper primary, Vosk fallback), model
catalogue, offline semantics and the manual hardware checklist:
`docs/voice_stage2.md`. Stage 1 parser rules: `docs/voice_stage1.md`.
