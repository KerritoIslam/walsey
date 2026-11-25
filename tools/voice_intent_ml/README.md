# Walsey Voice Audio Features — Phase 1

The primary Phase 1 path converts audio samples directly into log-Mel feature
matrices. It does not transcribe speech, train a classifier, or execute
commands. The older transcript-text experiments remain available separately,
but are not used by this acoustic pipeline.

See [`../../docs/voice_intent_ml.md`](../../docs/voice_intent_ml.md) for the
voice architecture, feature configuration, output format, measured example,
and limitations.

## Install and test

Use Python 3.11–3.13:

```powershell
py -3.13 -m venv .venv
.venv\Scripts\python -m pip install -e ".[dev]"
.venv\Scripts\python -m pytest
```

NumPy and SciPy perform the signal processing; no speech model or network
access is required.

## Extract features from a WAV recording

```powershell
.venv\Scripts\python scripts\extract_log_mel.py path\to\command.wav --out-dir out\audio
```

Input must be uncompressed 16-bit PCM WAV. Mono or multi-channel audio and
sample rates other than 16 kHz are supported; channels are downmixed and other
rates are resampled to match Walsey's microphone pipeline. Each recording gets
its own output directory containing `features.npy` and `metadata.json`.

Optional `--intent` and repeatable `--parameter` arguments attach reviewed
labels; they never affect the feature values.
