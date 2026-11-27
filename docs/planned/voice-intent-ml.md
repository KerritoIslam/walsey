# Plan: voice-intent ML (acoustic classification)

**Status: research only. Phase 1 feature extraction exists; no classifier is
trained, exported or wired into the app.**

Current reference: [`../voice_intent_ml.md`](../voice_intent_ml.md).

## What exists

- `tools/voice_intent_ml/` converts PCM16 WAV to a `[64, frames]` float32
  log-Mel matrix (`logmel-v1`: 16 kHz, Hann 400/512 FFT, hop 160, 64 HTK mel
  bands, natural log with `1e-10` floor).
- Metadata records the source digest and the complete transform configuration.
- 72 Python tests cover decoding, downmix, resampling, shape, determinism,
  silence and metadata.
- There is **no labeled WAV command corpus**, no training split, no model and no
  Flutter inference path.

## Why it might exist alongside ASR

Whisper is accurate but batch-decoded and relatively heavy. A small acoustic
classifier could recognise a fixed command set faster and without a transcript.
It is not a replacement for the parser: the parser and `CommandRegistry` remain
the authorization allowlist.

## Non-negotiable constraints

1. **No second execution path.** A classifier may only produce a proposed
   `VoiceIntent` + validated parameters. It must go through the same parser
   validation and registry checks, or be rejected.
2. **Offline only.** No cloud inference, no audio upload.
3. **One microphone consumer.** Features must come from the existing capture
   session, after sample reassembly, not a second recorder.
4. **Unknown rejection.** A low-confidence result must become
   "not understood", never the nearest command.
5. **No parser weakening.** Do not add synonyms or fuzzy matches to compensate
   for classifier errors.
6. **Typed input and hold-to-talk keep working** when the model is absent.

## Target design

```
record → Pcm16Assembler → ┬→ Whisper/Vosk (existing)
                           └→ FeatureBuilder (Dart, logmel-v1)
                                → ONNX classifier (small CNN)
                                → candidate intent + confidence
                                → validation/registry (same as ASR)
                                → optional confirmation UI
```

- Feature parity is the hard part. A Dart `FeatureBuilder` must reproduce the
  Python WAV/PCM conversion, resampling, STFT window/padding/scaling, mel
  filterbank, log floor and axis order exactly. The Python metadata exists for
  this parity test.
- Inference backend: a Dart ONNX FFI binding, or a backend exposed by the chosen
  runtime. Do not reuse the whisper.cpp FFI for this.
- Confidence policy must be measured, not guessed. Prefer "no command" over a
  wrong command.

## Implementation steps

1. **Corpus** — collect user-recorded, reviewed clips with intent and parameter
   labels. Include negatives, silence, near-misses and different speakers.
   A leakage-safe speaker-disjoint split is mandatory.
2. **Baseline** — train a small CNN on `[1, 64, frames]`, with a fixed
   duration/padding/pooling policy. Report per-intent precision/recall and a
   confusion matrix.
3. **Rejection** — add an unknown/negative class and a confidence threshold.
   Measure false commands first, accuracy second.
4. **Export** — ONNX with a pinned opset and input/output shape. Record the file
   size and SHA-256.
5. **Dart features** — implement `logmel-v1` in pure Dart and prove numerical
   parity against the Python matrices within a stated tolerance.
6. **Inference adapter** — load the model once, run in an isolate if the frame
   cost is visible, free native resources deterministically.
7. **Integration** — feed only after explicit user action. Show the candidate
   and confidence. Route through the existing parser validation before any
   plan/executor call.
8. **Fallback** — if the model is missing, unsupported or low-confidence, use
   ASR/typed input and say so.

## Tests

- Python: existing 72 plus corpus/split integrity, label validation, ONNX export
  shape.
- Dart: feature parity, determinism, silence/floor, inference with a fake
  backend, rejection below threshold, no execution on a candidate, missing model
  → honest unavailable state.
- End-to-end app: classifier candidate still cannot bypass the registry; a
  malformed/low-confidence candidate executes nothing.

## Acceptance

- Measured false-command rate is acceptable on held-out human audio.
- No classifier result can execute without passing the same validation as text.
- The app works fully when the model is absent.
- The model is installed explicitly, verified by size/digest, never committed as
  an unlicensed archive.
