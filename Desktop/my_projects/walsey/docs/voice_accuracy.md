# Voice recognition accuracy (measured 2026-10-25)

This is a measurement report, not a feature. It answers three questions about
the Stage 2 pipeline (`record` → Vosk → `SpeechRecognizer` → unchanged Stage 1
parser):

1. What does the shipped configuration actually hear?
2. Do a bigger Vosk model or a constrained grammar help?
3. Would a local Whisper model be better?

No parser rule was relaxed, no command was executed and no frame was sent.
`VoiceResult.executionStatus` stayed `notExecuted` throughout.

## Method

A repeatable offline harness feeds WAV files through the **same** `dart:ffi`
bindings the app uses, then scores the raw transcript with the **same** parser
and parameter summary the UI uses:

- `walsey_voice_speech/bin/voice_accuracy.dart` — corpus runner and metrics.
- `tools/voice_accuracy/make_tts_corpus.ps1` + `commands.txt` — deterministic
  30-command corpus spoken by two locally installed Windows SAPI voices
  (Microsoft David, Microsoft Zira) at 16 kHz mono PCM16.
- `tools/voice_accuracy/run_whisper_corpus.ps1` — runs whisper.cpp on the same
  WAVs and writes a transcript TSV that `--transcripts` scores with the same
  metric/parser code.

Every metric is reported twice where it matters:

| Metric | Meaning |
|---|---|
| exact sentence (verbatim) | normalized transcript equals the expected sentence |
| exact sentence (numbers folded) | same, with "fifty" → "50" folded on both sides |
| word error rate | Levenshtein over words, mean per file, same two variants |
| transcript parses | the raw transcript is a valid Stage 1 command |
| same command | transcript parses to the same intent *and* the same parameters as the expected sentence |
| real time factor | decode seconds / audio seconds |

The verbatim figure is primary. The folded figure exists because Vosk always
writes numbers as words while the corpus is written with digits; that is an
output-format difference, not a recognition error, and reporting it separately
keeps both numbers honest.

### Reproduction

```powershell
# 1. corpus (once; writes WAVs + expected.tsv to %TEMP%\walsey_voice_corpus)
powershell -ExecutionPolicy Bypass -File tools/voice_accuracy/make_tts_corpus.ps1

# 2. run Vosk (put the Vosk DLL folder on PATH first: libvosk.dll needs
#    libstdc++-6.dll, libgcc_s_seh-1.dll and libwinpthread-1.dll next to it)
$env:PATH = "apps\walsey_voice_test\build\windows\x64\runner\Debug;$env:PATH"
cd walsey_voice_speech
dart run bin/voice_accuracy.dart `
  --model "$env:APPDATA\com.walsey\walsey_voice_test\walsey_models\vosk-model-small-en-us-0.15" `
  --corpus "$env:TEMP\walsey_voice_corpus" `
  --library "..\apps\walsey_voice_test\build\windows\x64\runner\Debug\libvosk.dll" `
  --out result.json --verbose

# 3. optional: constrained grammar
dart run bin/voice_accuracy.dart ... --grammar [--unk]

# 4. optional: score another engine on the same recordings
powershell -ExecutionPolicy Bypass -File tools\voice_accuracy\run_whisper_corpus.ps1 `
  -CorpusDirectory "$env:TEMP\walsey_voice_corpus" `
  -WhisperCli <path>\whisper-cli.exe -Model <path>\ggml-base.en.bin
dart run bin/voice_accuracy.dart ... --transcripts "$env:TEMP\walsey_voice_corpus\whisper.tsv"
```

The harness rejects any WAV that is not 16 kHz, mono, 16-bit PCM instead of
resampling it, so a format mistake cannot masquerade as a recognition problem.

## Diagnostic mode in the app

`walsey_voice_test` now exposes the measurement data the manual checklist needs
(`walsey_voice_speech/lib/src/diagnostics/`):

- raw Vosk transcript shown next to the parsed result;
- per-session stats: duration, format, chunk sizes, peak/RMS dBFS, clipping,
  trailing silence, bytes after the last partial;
- **rate check** (audio seconds / wall-clock seconds; 1.00 means the requested
  16 kHz mono PCM16 was honoured, ~3.0 would mean a 48 kHz stream mislabelled);
- **first audio** delay: how long after the session started the first chunk
  arrived;
- WAV export (16 kHz mono PCM16) of the captured audio, capped at 30 s / 4 MB;
- `--record-selftest --seconds N --out <dir>` runs the real microphone through
  the production capture path and writes `record_selftest.{json,wav,log}`.

## Capture path verification (Windows 11, this machine)

`--record-selftest` (4 s window, three runs):

| Fact | Measured |
|---|---|
| Format | `pcm_s16le`, 16000 Hz, mono, 16-bit (ffprobe) |
| Chunks | 80–81 × 960/1920 B |
| Rate honoured | audio/wall-span 1.008, 1.009, 1.011 |
| First chunk | **747–762 ms** after the session started |
| Tail | last chunk 3967–4006 ms, stop at 4003–4005 ms → 0–36 ms gap, no tail loss |
| Level | digital silence (peak −80.8 dBFS once, otherwise all zeros) |

The microphone itself is the problem here, not the plugin: direct
`ffmpeg -f dshow` capture from both the Realtek microphone array and a Bluetooth
headset reports `mean_volume −91.0 dB`, `max_volume −90.3 dB`. Real signal
level, clipping and end-to-end speech capture therefore could **not** be
verified on Windows.

The ~750 ms first-chunk delay is real and matters: anything said immediately
after tapping the microphone is never delivered. It is a capture device open
cost, not a recognition error, and the diagnostics panel now shows it.

## Results

60 utterances (30 commands × 2 voices), 133.78 s of audio, 2,140,480 samples,
0 clipped samples in every run.

| Configuration | Model size | Exact (verbatim) | Exact (digits folded) | WER (verbatim) | WER (digits) | Same command | RTF |
|---|---|---|---|---|---|---|---|
| `vosk-model-small-en-us-0.15`, unconstrained (shipped) | 67.6 MB | 30/60 (50.0%) | 37/60 (61.7%) | 0.2492 | 0.1492 | 54/60 | 0.295 |
| `vosk-model-en-us-0.22-lgraph`, unconstrained | 204.1 MB | 30/60 (50.0%) | 35/60 (58.3%) | 0.2525 | 0.1525 | 55/60 | 1.588 |
| `small-en-us-0.15` + constrained grammar (1,994 phrases) | 67.6 MB | 32/60 (53.3%) | 50/60 (83.3%) | 0.1650 | 0.0650 | 51/60 | 0.024 |
| whisper.cpp `ggml-base.en.bin` (scored via `--transcripts`) | 141.1 MiB | 39/60 (65.0%) | 39/60 (65.0%) | 0.1233 | 0.1233 | 53/60 | 0.500 |

Split by whether the utterance starts with the invented wake word (10 of the 60):

| Configuration | Same command, non-wake (n=50) | Same command, wake (n=10) |
|---|---|---|
| small unconstrained | 48/50 (96%) | 6/10 |
| 0.22-lgraph | 47/50 (94%) | 8/10 |
| small + grammar | **50/50 (100%)** | **1/10** |
| whisper base.en | 49/50 (98%) | 4/10 |

Latency and memory (harness process; 60 files):

| Configuration | Model load | Mean decode/file | Total decode | RSS after model load | Peak process memory |
|---|---|---|---|---|---|
| small unconstrained | 355 ms | 0.658 s | 39.46 s | 317.8 MB (+116 MB over the Dart baseline) | — |
| 0.22-lgraph | 829 ms | 3.540 s | 212.42 s | 533.2 MB (+332 MB) | — |
| small + grammar | ~310 ms | 0.054 s | 3.23 s | ~318 MB | — |
| whisper base.en | ~152 ms | 1.116 s | 66.95 s | — | 409.6 MB working set |

The whisper figure is the whole `whisper-cli.exe` process polled every 100 ms
during a 134 s decode, so it includes the executable and audio buffers; it is
not directly comparable with the Vosk "RSS above the Dart VM baseline" numbers.

### What the errors actually are

- **Digit format only** (parses correctly, counted as "not exact"): every
  brightness and effect sentence, because Vosk writes "fifty" and the corpus
  writes "50". 18 of the 60 utterances for the small model.
- **"red" → "read"** (both voices): the parser correctly refuses, because
  "read" is not a controlled colour. This is a genuine recognition error on a
  word that is acoustically ambiguous in isolation.
- **"turn the" → "turned the"**: both Vosk and Whisper hear the SAPI
  pronunciation as "turned the", which the parser rejects. This is a
  corpus/pronunciation artifact that affects both engines equally; it is not
  evidence about the app's own microphone path.
- **The wake word** is the dominant failure. "walsey" is not in Vosk's
  vocabulary; unconstrained decoding either drops it or replaces it with
  unrelated words ("well said he", "city", "well see"), and Whisper writes
  "Volsity", "Vulsati", "Walsi", "while she".

## Constrained grammar

Vosk supports runtime grammar (`vosk_recognizer_new_grm`) only on models with a
dynamic graph (`HCLr.fst` + `Gr.fst`). The binding now checks this: the harness
and the recognizer refuse grammar for a static-graph model and for a library
build without the symbol, because calling it there aborts the native process.

The grammar was generated from the *command vocabulary* (power phrases, every
colour, every brightness percentage 0–100, every documented effect id, with and
without a leading "walsey"), 1,994 phrases total. It was **not** generated from
the test sentences, but it necessarily overlaps with them; the result measures
the best case for this closed command set, not general English.

Findings:

- Command accuracy on non-wake utterances is perfect (50/50) and decoding is
  about 12× faster (RTF 0.024).
- It makes the wake-word problem **worse** (1/10 vs 6/10 unconstrained).
  `walsey` is absent from the lexicon, so Vosk prints
  `WARNING ... Ignoring word missing in vocabulary: 'walsey'`, and the decoder
  is then forced to fill the slot with the nearest in-vocabulary words
  ("one set turn the lights on", "white set activate effect seven").
- Adding `[unk]` to the phrase list is accepted but had no observable effect on
  these recordings.

**Decision: grammar stays off in the app and in the testbed.** The plumbing is
kept (opt-in `VoskSpeechRecognizer(grammar: ...)`, harness `--grammar`) because
it is correct and becomes attractive once a wake word that actually exists in
the model vocabulary (or a separate Stage 3 keyword spotter) is introduced.

## Whisper comparison

`whisper.cpp` b5454 (prebuilt Windows x64) with `ggml-base.en.bin`, same 60
recordings, scored by the same code.

- Best word accuracy: WER 0.123 vs 0.249, exact 65% vs 50%.
- Best command accuracy on non-wake utterances: 49/50 vs 48/50.
- But it is slower (RTF 0.50 vs 0.30), ~3.5× the peak memory, 6× the model
  size, and it needs a second native dependency (whisper.cpp) that has no
  equivalent of the Vosk Android AAR used today.
- It normalizes numbers and units itself ("50%", "FX7"). "50%" still parses,
  but "FX7" does not, so a Whisper adapter would need a small transcript
  canonicalizer on the recognizer side. That would not touch the parser, but it
  is extra code that the Vosk path does not need.

## Recommendation

1. **Ship `vosk-model-small-en-us-0.15` with unconstrained decoding** — the
   current default. It is the smallest, fastest configuration, needs no new
   dependency, and reaches 96% command accuracy on clean, non-wake speech.
2. **Do not adopt the larger `0.22-lgraph` model.** It is 3× larger and 5.4×
   slower with no accuracy gain on this vocabulary.
3. **Do not enable the grammar by default.** Keep it as an opt-in experiment
   until the wake word is redesigned; on wake-word utterances it is markedly
   worse than unconstrained decoding.
4. **Do not adopt Whisper in Stage 2.** It is the most accurate engine measured,
   but the gain does not justify a second native stack, 6× the model size and
   1.7× the latency while Android packaging is unresolved. Revisit only if
   accuracy becomes the binding constraint.
5. **Treat the wake word as the real accuracy problem**, not the acoustic model.
   Every configuration fails most wake-word utterances; that belongs in Stage 3
   (a vocabulary-backed wake word or a dedicated keyword spotter), not in parser
   tuning.
6. **Account for the ~750 ms microphone open delay** in Stage 3 UX: show
   "listening" only once audio is actually flowing, or users lose their first
   syllable. No auto-start and no background listening is implied.

## Limits of this measurement

- The corpus is **synthetic SAPI speech** with two American voices. It is a
  deterministic regression baseline, not evidence about human accents, distance,
  room noise or the S21+ microphone.
- Windows capture was verified for format, rate, timing and tail only. This
  machine's microphones deliver digital silence, so level, clipping and
  end-to-end recognition of real speech could not be checked.
- No Android device was connected, so nothing here is an Android result.
- Recognition accuracy is a property of the installed model plus the audio
  path; the parser was not changed and none of these numbers authorize LED
  execution.

## Files

- `walsey_voice_speech/bin/voice_accuracy.dart` — harness (Vosk, grammar,
  external-transcript scoring).
- `walsey_voice_speech/lib/src/diagnostics/` — `wav.dart`, `audio_stats.dart`,
  `session_diagnostics.dart`.
- `walsey_voice_speech/lib/src/vosk/vosk_model_info.dart` — model graph, size,
  sample rate and grammar support.
- `apps/walsey_voice_test/lib/record_selftest.dart` — real-microphone self-test.
- `tools/voice_accuracy/` — command list, TTS corpus generator, whisper runner.

No model archive, DLL, WAV or transcript file is committed.
