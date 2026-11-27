# Plan: real "Walsey" wake word with an ONNX keyword spotter

**Status: not implemented. Nothing in this document ships or listens today.**
The detector seam, VAD, pre-roll → decode loop, opt-in app wiring and Android
foreground-service shell exist and are tested. The missing piece is a model and
a scorer backend. The Assistant currently reports `notConfigured`.

This plan implements the smallest honest path first: a **sherpa-onnx streaming
keyword spotter** behind the existing `WakeWordScorer` seam. The
openWakeWord-style custom-ONNX model is documented as the production-quality
alternative, because it needs a training pipeline this repository does not have.

Reference: [`../wake_word.md`](../wake_word.md) for the measured Vosk failure and
platform constraints, and [`../../AGENTS.md`](../../AGENTS.md) for the binding
rules.

---

## 1. What already exists

| Piece | File | State |
|---|---|---|
| `WakeWordScorer` port | `walsey_voice_speech/lib/src/wake/onnx_wake_word_detector.dart` | Frame scoring seam: `load`, `score(Int16List)`, `reset`, `dispose`, `frameSamples` |
| `OnnxWakeWordDetector` | same file | Capture, framing, threshold, consecutive frames, duplicate window, raw-audio tap. 15 tests with a fake scorer |
| `VoiceActivityDetector` | `lib/src/audio/voice_activity.dart` | Pure-Dart energy VAD. 9 tests |
| `BufferedSpeechRecognizer` | `lib/src/wake/buffered_speech_recognizer.dart` | Warm batch decode of captured PCM |
| `WakeWordCommandLoop` | `lib/src/wake/wake_word_command_loop.dart` | Pre-roll, VAD, stop-detector-before-decode, transcript event. 7 tests |
| Opt-in app wiring | `apps/walsey/lib/voice/voice_session_controller.dart`, `.../features/assistant/assistant_page.dart` | Consent switch, explicit start/stop, prewarm, hold handover, honest status. 11 app tests |
| Android FGS shell | `lib/voice/android_wake_service.dart`, `WakeWordForegroundService.kt` | Visible notification, never opens the microphone |

The seam is already right: `OnnxWakeWordDetector` owns capture and detection
policy; a scorer only turns one frame into a confidence. The loop is typed to
`OnnxWakeWordDetector`, so implementing a scorer requires **no loop refactor**.

### Current uncommitted worktree state (do not treat as shipped)

At the time of writing the worktree contains, **untracked and unverified**:

```
walsey_voice_speech/pubspec.yaml                       sherpa_onnx: ^2.0.1
walsey_voice_speech/assets/wake/zhen_3m/
  encoder.int8.onnx   4,599,656 B
  decoder.onnx          759,829 B
  joiner.int8.onnx       86,629 B
  tokens.txt              1,928 B
  keywords.txt            1,526 B
```

There is **no `flutter: assets:` section**, no installer, no scorer class and no
digest manifest. The keywords file contains empirically derived ARPABET
spellings for "Walsey" with provisional `:1.5 #0.25` values and a comment
referring to a `wakeWordModelV1` digest and calibration that **do not exist yet**.
The model is a general phone-based KWS acoustic model, not a model trained on
"Walsey"; the phrase is supplied as a phone keyword list.

Decision required before shipping: commit the model files or download them
explicitly through a verified catalogue. The project rule says never commit model
archives; individual small ONNX files are still model weights and should be
treated the same way unless the licence and size are explicitly accepted. This
plan supports both paths, with explicit install as the default.

---

## 2. Target architecture

```
record (16 kHz mono PCM16)
  │ OnnxWakeWordDetector captures and frames (frameSamples)
  ▼
SherpaKeywordSpotterScorer implements WakeWordScorer
  │ int16 → float32 (s/32768.0)
  │ KeywordSpotter.createStream()
  │ while isReady: decode
  │ getResult(stream).keyword == "WALSEY" ? 1.0 : 0.0
  ▼
OnnxWakeWordDetector threshold / consecutive / duplicate policy
  ▼
WakeWordCommandLoop pre-roll + VAD + stop detector + batch decode
  ▼
unchanged parser → executor
```

Why keep the detector: it already owns the single-microphone lifecycle, the
duplicate window and the raw-audio tap used for pre-roll. The scorer must not
duplicate that state.

---

## 3. Phase 1 — model assets and installation

### 3.1 Choose the distribution model

**Option A (recommended): explicit install through a verified catalogue.**

- Add a `WakeModel` descriptor: id, display name, file list, exact sizes,
  SHA-256 per file, licence, source URL, model revision.
- Install only from an explicit **Install wake model** action, using the same
  rules as speech models: stream to a staging folder, verify size + digest, move
  atomically into `<app support>/walsey_wake/<id>/`.
- No startup prefetch, no retry loop, no background download.
- The UI shows *Not installed* with the reason until the install completes.

**Option B: bundle as Flutter assets (only if the licence and size are
accepted).**

- Add a `flutter: assets:` entry under `walsey_voice_speech`.
- Copy from `rootBundle` to application support on first use, verifying pinned
  sizes/digests.
- This is simpler offline but increases every APK/exe and still needs a digest
  manifest. Never use the Flutter asset path directly: sherpa takes filesystem
  paths, and Android asset paths are not real files.

Either way, do **not** hard-code a developer machine path, and do not silently
use an unverified file.

### 3.2 Directory layout

```
<app support>/walsey_wake/<model-id>/
  encoder.int8.onnx
  decoder.onnx
  joiner.int8.onnx
  tokens.txt
  keywords.txt
  manifest.json          # id, revision, sizes, digests, licence
```

`OnnxWakeWordDetector.modelPath` can point to this directory; its `prepare()`
only checks existence. The scorer's `load()` must validate the files again
because a directory can exist while a file is truncated.

### 3.3 Validation rules

- Exact byte size for every file.
- SHA-256 for every file, pinned in code/catalogue.
- `tokens.txt` parses as `<token> <id>` lines and the ids are contiguous.
- `keywords.txt` parses as phone sequence + optional `:boost #threshold
  @display`; every phone exists in `tokens.txt`.
- Reject a model if any check fails; report `modelInvalid`, never fall back to a
  different model silently.
- Record the model id and revision in diagnostics.

### 3.4 Native libraries

`sherpa_onnx ^2.0.1` is a Flutter plugin, so it packages its own native
libraries:

- Android: `libsherpa-onnx-c-api.so`, `libsherpa-onnx-cxx-api.so`,
  `libonnxruntime.so` in the ABI folders.
- Windows: `sherpa-onnx-c-api.dll`, `sherpa-onnx-cxx-api.dll`,
  `onnxruntime.dll`, `onnxruntime_providers_shared.dll` next to the exe.

Do not copy these by hand or commit them. Verify the packaged APK after adding
the dependency, and verify the Windows build still passes. This dependency adds
size to the app; record the measured increase.

---

## 4. Phase 2 — the scorer adapter

Create `walsey_voice_speech/lib/src/wake/sherpa_keyword_scorer.dart` and export
it from `walsey_voice_speech.dart`.

Sketch (not compilable as-is; wire the exact imports and error handling):

```dart
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'onnx_wake_word_detector.dart';

/// [WakeWordScorer] over a sherpa-onnx streaming keyword spotter.
///
/// One scorer instance owns one [sherpa.KeywordSpotter] and one online stream.
/// `score()` feeds exactly one frame; detection policy stays in
/// [OnnxWakeWordDetector].
final class SherpaKeywordSpotterScorer implements WakeWordScorer {
  SherpaKeywordSpotterScorer({
    this.frameSamples = 1600, // 100 ms at 16 kHz
    this.sampleRate = 16000,
    this.keyword = 'WALSEY',
    this.numThreads = 1,
  });

  @override
  String get name => 'sherpa-kws';

  @override
  final int frameSamples;

  final int sampleRate;
  final String keyword;
  final int numThreads;

  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;

  @override
  Future<void> load(String modelPath) async {
    if (_spotter != null) return;

    // Required once per isolate before any runtime object is created.
    sherpa.initBindings();

    final spotter = sherpa.KeywordSpotter(
      sherpa.KeywordSpotterConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$modelPath/encoder.int8.onnx',
            decoder: '$modelPath/decoder.onnx',
            joiner: '$modelPath/joiner.int8.onnx',
          ),
          tokens: '$modelPath/tokens.txt',
          numThreads: numThreads,
          provider: 'cpu',
          debug: false,
        ),
        keywordsFile: '$modelPath/keywords.txt',
      ),
    );
    _spotter = spotter;
    _stream = spotter.createStream();
  }

  @override
  Future<double> score(Int16List frame) async {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null) {
      throw StateError('The keyword spotter is not loaded.');
    }
    if (frame.length != frameSamples) {
      throw StateError('Expected $frameSamples samples, got ${frame.length}.');
    }

    final samples = Float32List(frame.length);
    for (var i = 0; i < frame.length; i++) {
      samples[i] = frame[i] / 32768.0;
    }
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
    }

    final hit = spotter.getResult(stream).keyword;
    if (hit.isEmpty) return 0.0;
    if (hit.toUpperCase() != keyword) return 0.0;

    // Clear the stream so the same phrase cannot fire twice; the detector also
    // calls reset() after emitting, and reset must stay idempotent.
    spotter.reset(stream);
    return 1.0;
  }

  @override
  Future<void> reset() async {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter != null && stream != null) spotter.reset(stream);
  }

  @override
  Future<void> dispose() async {
    _stream?.free();
    _stream = null;
    _spotter?.free();
    _spotter = null;
  }
}
```

Notes and traps:

- `initBindings()` is sync and native-only. Call it once per **isolate**. If the
  scorer is later moved to a worker isolate, call it there, not only on the UI
  isolate. `initBindingsAsync()` exists for web, which Walsey does not target.
- `OnlineStream.free()` is manual. Forgetting it leaks native memory across
  start/stop cycles.
- The detector calls `score()` serially through its `_queue`; the scorer does not
  need its own lock.
- `frameSamples` must match what the detector passes. 1600 (100 ms) is a
  responsive starting point; measure CPU and latency. openWakeWord's 1280
  (80 ms) is not a requirement for this model.
- `KeywordSpotter.getResult()` returns the `@display` name. Match it
  case-insensitively and return exactly 1.0 or 0.0 so the detector's threshold
  and duplicate policy remain the only detection policy.
- A scorer exception currently fails the detector
  (`wake-word scoring failed`). Keep that: never swallow a native error and
  report "listening".

---

## 5. Phase 3 — keywords and calibration

The `keywords.txt` in the worktree is a starting point, not a result. Its header
already explains that "Walsey" is not in a dictionary and that multiple TTS
voices produced different phone strings.

### 5.1 How the file works

```
<phone> <phone> ... [:boost] [#threshold] [@display]
```

- `:1.5` raises the acoustic score for that keyword (easier to fire).
- `#0.25` is the trigger threshold in 0..1 (lower = easier).
- `@WALSEY` is what `getResult()` returns.
- Global defaults live in `KeywordSpotterConfig` (`keywordsScore`,
  `keywordsThreshold`); per-keyword values override them.

### 5.2 Calibration procedure

1. Keep the deliberate exclusion: do **not** ship `V AE1 L S OW0`
   ("VAL-so") just because one TTS voice produced it. Document it in
   `docs/wake_word.md` instead.
2. Build a corpus with positives **and** hard negatives:
   - positives: several human speakers, distances, speaking rates and mic
     positions, not only TTS;
   - near-misses: "Waltz", "Wally", "well say", "while", "Wall Street",
     "Walsall", "well see", plus normal sentences containing those sounds;
   - general speech: the command corpus, silence, TV/room noise.
3. Sweep per-keyword `:boost` and `#threshold` on a held-out split. Never tune
   and report on the same clips.
4. Report:
   - detection rate (positives),
   - false activations per hour of negative audio,
   - missed detections,
   - detection latency from the end of the phrase,
   - CPU and memory on Windows and Android.
5. Accept only if the false-activation rate is usable in a real room. Zero false
   activations on a tiny corpus is not evidence, and the Vosk result (0/36
   positives) shows why a single number is misleading.

### 5.3 Harness

The existing `walsey_voice_speech/bin/wake_accuracy.dart` targets the Vosk
detector. Add a parallel `bin/sherpa_wake_accuracy.dart` (or a `--engine sherpa`
switch) that:

- loads a scorer from a model directory;
- reads the same manifest/polarity convention (`!` = must not trigger);
- feeds complete 16 kHz PCM16 frames at `frameSamples`;
- reports positives, false activations, latency and RTF;
- writes JSON so results are reproducible.

Do not make the app path depend on the harness. The app uses the same scorer
class, not a copy.

### 5.4 Digests

`keywords.txt` is a model input. If it changes, the model manifest digest must
change too. Update the `wakeWordModelV1` reference in the header or remove it
until the catalogue exists.

---

## 6. Phase 4 — app injection

The production injection point is
`apps/walsey/lib/app/app_shell.dart` where `AssistantPage(...)` is constructed
(currently no `wakeLoop`). `AssistantPage` already accepts an optional
`WakeCommandSource`, passes it to `VoiceSessionController`, and calls
`prewarmWakeWord()` without opening the microphone.

### 6.1 Construction helper

```dart
// apps/walsey/lib/voice/wake_pipeline.dart (new)
Future<WakeCommandSource?> createWakePipeline({
  required ModelStore modelStore,
  WakeModel? installedModel,
}) async {
  if (installedModel == null) return null; // honest: nothing to inject

  final detector = OnnxWakeWordDetector(
    scorer: SherpaKeywordSpotterScorer(),
    capture: RecordAudioCapture(),
    modelPath: installedModel.directory,
    // Keep the detector policy explicit and testable.
    threshold: 0.5,
    requiredConsecutiveFrames: 1,
    duplicateWindow: const Duration(seconds: 2),
  );

  final recognizer = BufferedSpeechRecognizer(
    binding: const WhisperSpeechEngineBinding(), // exact name per package
    modelStore: modelStore,
  );

  return WakeWordCommandLoop(
    detector: detector,
    recognizer: recognizer,
    preRoll: const Duration(milliseconds: 1500),
    commandTimeout: const Duration(seconds: 8),
  );
}
```

Then, in the app service graph:

- resolve the installed wake model once (app support check);
- construct the pipeline only when a verified model exists;
- pass it to `WalseyShell` → `AssistantPage(wakeLoop: ...)`;
- keep `null` otherwise so the Assistant shows the honest `notConfigured`
  explanation;
- dispose the pipeline with the app/shell.

Do **not** construct a detector with a placeholder path just to make the switch
appear.

### 6.2 Two-stage startup

`WakeWordCommandLoop.prewarm()` already:

1. asks the detector for availability;
2. loads the buffered recognizer/engine **without opening the microphone**.

Keep it. The first **Start listening** press should then be fast, but it remains
the only action that opens the microphone.

### 6.3 UI states

| State | UI |
|---|---|
| No model | Card says the model is missing; no Start button |
| Model installed, permission denied | Explain and offer permission recovery; hold-to-talk still works |
| Ready but stopped | Consent switch + **Start listening** |
| Starting | "Starting…"; no fake "Listening" |
| Listening | "Listening for Walsey"; visible stop control |
| Capturing/decoding | "Heard you; transcribing" (from real loop events) |
| Failure | Distinct message; no auto-restart loop |
| Android background | Visible ongoing notification with **Stop listening** |

Never claim "listening" before `loop.start()` resolved and the detector is
running.

### 6.4 One-microphone arbitration

Already implemented and must stay:

- a hold calls `stopWakeListening` (keeping consent) before the recorder opens;
- a hold is refused while `wakeCapturing`;
- a spoken response is silenced on detection;
- stop/cancel/failure/dispose close the microphone;
- lifecycle change stops listening on Windows/other platforms; Android may keep
  the visible foreground service.

---

## 7. openWakeWord / custom ONNX alternative

Use this when the keyword-spotter route cannot reach an acceptable
false-activation rate, or when a trained "Walsey" model becomes available.

### Shape

openWakeWord-style models chain small ONNX models:

```
audio → melspectrogram.onnx → embedding_model.onnx → wake_model.onnx → score
```

- `frameSamples` is typically 1280 (80 ms at 16 kHz), but the chain keeps
  streaming state across frames.
- The wake model is trained on the target phrase plus synthetic negatives.
- The scorer still implements the same `WakeWordScorer` interface; the detector,
  loop and app wiring do not change.

### Why it is not first

- It needs a **trained** model. The openWakeWord training pipeline
  (TensorFlow/PyTorch + synthetic speech augmentation) is not installed or
  verified here.
- It needs an ONNX runtime binding. `sherpa_onnx` bundles onnxruntime but does
  not expose a general "run this arbitrary ONNX graph" API suitable for this
  chain. A separate `onnxruntime` Dart FFI binding would be another native
  dependency to package and test.
- Shipping an untrained or borrowed model would violate the "no placeholder
  model, no fake confidence" rule.

### If implemented

1. Pin the three model files by size and digest.
2. Implement mel/embedding/wake state in one scorer, not three widgets.
3. Keep `score()` streaming and cheap; do not allocate per frame.
4. Run the same calibration protocol as §5.2, on human audio.
5. Keep the same `notConfigured` behaviour when any file is missing.

---

## 8. Tests

All new tests must be microphone-, network- and native-library-free.

| Layer | Test |
|---|---|
| Installer | Size/digest verification, staging cleanup, cancellation, invalid token/keyword file, atomic move. Use a loopback `HttpServer` or in-memory bytes |
| Asset copy | Each bundled file copied once, verified, and reused; a truncated file is rejected |
| Scorer (fake native seam) | A fake `KeywordSpotterBackend` returns `''` then `WALSEY`; assert 0.0 then 1.0, reset called, no double fire. If sherpa types cannot be faked cheaply, put the backend behind a small interface |
| Detector | Existing 15 tests stay green; add one where the scorer returns 1.0 and the duplicate window suppresses a second detection |
| Loop | Existing 7 tests stay green with the scorer in place; no command after the wake word stays `WakeEmpty` |
| App | Existing 11 wake tests stay green; an injected pipeline still requires explicit start; a missing model injects `null` |
| Benchmark | Not a unit test: `bin/sherpa_wake_accuracy.dart` against real audio |

Add one test that a scorer exception produces `WakeFailed`, not a silent stop.

---

## 9. Hardware and platform checklist

Before calling the wake word "available":

- [ ] Windows: model installs, `initBindings()` loads, a human says "Walsey" at
      1 m and the detector fires; the command is transcribed and parsed.
- [ ] Windows: 30 minutes of ordinary speech/room noise → record false
      activations per hour.
- [ ] Android: same, with `RECORD_AUDIO` granted and the foreground service
      visible.
- [ ] Android: deny the microphone permission; expect an honest failure and
      working hold-to-talk.
- [ ] Android: background the app while listening; the visible notification
      remains, **Stop listening** works, and the microphone closes.
- [ ] Windows: close/minimise the app; no hidden capture remains.
- [ ] Both: a hold pauses listening and resumes it after the take.
- [ ] Both: a spoken response is not transcribed by the detector.
- [ ] Both: a wake transcript that fails to parse executes nothing.
- [ ] Both: no automatic frame is sent by a detection; the normal executor still
      requires a valid plan.
- [ ] Repeat the calibration on human audio, not TTS, and record it in
      [`../wake_word.md`](../wake_word.md) / [`../voice_accuracy.md`](../voice_accuracy.md).

Packaging checks:

- [ ] APK contains the sherpa libraries for every shipped ABI.
- [ ] Windows build still passes with `nuget.exe` and the `/await` workaround.
- [ ] APK/exe size increase is measured and documented.
- [ ] No model file is committed unless the licence decision explicitly allows
      it; otherwise only the catalogue and digests are committed.

---

## 10. Definition of done

The feature is done when:

1. a verified model can be installed explicitly;
2. `SherpaKeywordSpotterScorer` implements `WakeWordScorer` and is tested with a
   fake native seam;
3. the app injects the pipeline only when the model is installed;
4. the Assistant shows real states and never a fake "Listening";
5. human-audio false-activation and miss rates are measured on both platforms;
6. every write still goes through the unchanged parser → plan → executor path;
7. [`../wake_word.md`](../wake_word.md), [`../../README.md`](../../README.md),
   [`../README.md`](../README.md) and the hardware checklist are updated.

Until then, the honest answer is the current one: **hold-to-talk works; the wake
word is not available in this build.**
