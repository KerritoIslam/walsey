# Walsey voice intent ML — Phase 1 audio features

Phase 1 converts the **voice signal** into numeric acoustic features. It does
not convert speech to text for the ML path, train a classifier, access BLE, or
execute commands. Existing transcript-based command interpretation remains
unchanged.

## Existing voice path and integration point

Walsey's `AudioCapture` port supplies interleaved little-endian PCM16 chunks.
The production recorder requests **16 kHz, mono**, and the speech recognizer
assembles complete samples before passing each chunk to `SpeechEngine.accept`.
Whisper consumes this same audio and only produces a transcript for the
existing deterministic parser.

The future acoustic-model seam is the captured PCM signal, after chunk
reassembly and before the speech-engine consumer. It must use the existing
microphone session rather than opening a second recorder. This Phase 1 Python
tool processes saved WAV clips only; it does not modify the Flutter capture
path or feed features into the app.

## Numeric representation

The selected representation is a **log-Mel power spectrogram**. It preserves
time and frequency patterns from the waveform, making it appropriate for a
voice-intent model without first recognizing words.

`walsey_intent.audio_features` provides:

- `pcm16le_to_mono_float`: decodes little-endian PCM16 to float32 using
  `sample / 32768.0`, and downmixes interleaved channels by their mean.
- `load_wav`: reads uncompressed PCM16 WAV, downmixes to mono, and resamples to
  16 kHz when required. It does not silently accept other encodings.
- `log_mel_spectrogram`: transforms normalized mono samples into log-Mel
  features.

The versioned `logmel-v1` defaults are:

| Parameter | Value |
|---|---:|
| Sample rate | 16,000 Hz |
| Window | Hann, 400 samples (25 ms) |
| FFT | 512 |
| Hop | 160 samples (10 ms) |
| Mel bands | 64 |
| Mel scale | HTK, sum-normalized triangular filters |
| Log | Natural log of power with a fixed `1e-10` floor |
| Output | `float32`, shape `[64, frames]` |

No peak normalization, clipping, transcript conversion, or duration truncation
is applied. Frame count follows the source duration; very short input is
zero-padded to one analysis window. The exact parameters are written to each
sample's metadata.

## Run and output format

From `tools/voice_intent_ml`:

```powershell
python -m pytest
python scripts\extract_log_mel.py path\to\command.wav --out-dir out\audio
```

The script prints the input audio metadata and feature shape. It saves:

- `<out-dir>/<id>/features.npy`: the numeric log-Mel matrix, loaded with
  `allow_pickle=False`.
- `<out-dir>/<id>/metadata.json`: source filename and SHA-256, source sample
  rate/channel count/frame count, optional intent/parameter labels, feature
  shape/dtype/axes, and the complete transform configuration.

The metadata deliberately contains no recognized sentence. `--intent` and
repeatable `--parameter` arguments attach reviewed labels; they do not affect
the feature matrix.

The workspace includes `test_mic.wav`, an unlabeled 44.1 kHz stereo PCM16
recording, for an end-to-end feature-conversion demonstration. It is not a
labeled command example and must not be assigned an intent by guesswork. There
is not yet a labeled WAV command dataset in the repository.

## Future PyTorch use

Each clip produces a `[64, frames]` float32 tensor. A model can consume
`[batch, 1, 64, frames]` for a convolutional front end, or a later experiment
can flatten a consistently padded/fixed-duration representation for an MLP.
Clip lengths vary, so Phase 2 must establish a reviewed duration and padding or
pooling policy before batching; this phase does not truncate recordings or
train any network.

Training and future inference must share `AudioFeatureConfig` and the same
log-Mel implementation. A Flutter/ONNX feature port must reproduce the WAV/PCM
conversion, resampling, STFT window/padding/scaling, Mel filterbank, log floor,
and axis order. The metadata preserves those choices for a later parity test.
The current app is not wired to an audio classifier.

## Tests and limitations

Tests use generated waveforms and WAV fixtures, not a microphone or a speech
model. They cover PCM16 decoding, stereo downmix, sample-rate conversion,
feature shape/determinism, silence/floor behavior, preserved amplitude, invalid
inputs, and saved metadata/features.

The unlabeled local WAV demonstrates input conversion only. Real intent
recognition still requires user-recorded, reviewed audio clips paired with
intent and parameter labels, plus a leakage-safe split. No MLP training, ONNX
export, or Flutter classifier integration belongs in this phase.

The earlier transcript-text/TF-IDF experiments remain separate files in
`tools/voice_intent_ml` for reference. They are not input to this acoustic
pipeline and do not satisfy the raw-audio goal.
