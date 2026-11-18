# Voice recognition accuracy (measured 2026-10-25, expanded 2026-11-06)

This is a measurement report, not a feature. It answers five questions about
the Stage 2 pipeline (`record` → Vosk/Whisper → `SpeechRecognizer` → Stage 1
parser or Stage 2 plan parser):

1. What does the shipped configuration actually hear?
2. Do a bigger Vosk model or a constrained grammar help?
3. Would a local Whisper model be better?
4. Does the app's own FFI path (not the CLI) behave like the measured baseline —
   and do decoder parameters (`initial_prompt`, greedy candidate count) change
   accuracy, latency or safety?
5. Does a recognized sentence become the **same command/plan** — and are
   unsafe sentences still rejected?

No parser rule was relaxed, no command was executed and no frame was sent.
`VoiceResult.executionStatus` stayed `notExecuted` throughout.

## Method

A repeatable offline harness feeds WAV files through the **same** `dart:ffi`
bindings the app uses, then scores the raw transcript with the **same** parser
and parameter summary the UI uses:

- `walsey_voice_speech/bin/voice_accuracy.dart` — corpus runner and metrics.
- `tools/voice_accuracy/make_tts_corpus.ps1` + `commands.txt` — deterministic
  command corpus spoken by two locally installed Windows SAPI voices
  (Microsoft David, Microsoft Zira) at 16 kHz mono PCM16. As of 2026-11-06 it
  holds **54 positives + 18 negatives** (unsafe/unsupported sentences that must
  stay rejected).
- `tools/voice_accuracy/commands_plan.txt` — **21 positives + 10 negatives** for
  multi-step/device requests; scored with `--plan` so it goes through
  `VoicePlanParser` instead of the single-command parser.
- `walsey_voice_speech/bin/check_corpus.dart` — validates corpus polarity with
  the real parser (`--plan` for the plan corpus). Run it after every edit; it
  fails on a negative that parses or a positive that does not.
- `tools/voice_accuracy/wake.txt` and `bin/wake_accuracy.dart` — the separate
  wake-phrase benchmark (see `docs/wake_word.md`).
- `tools/voice_accuracy/run_whisper_corpus.ps1` — runs whisper.cpp on the same
  WAVs and writes a transcript TSV that `--transcripts` scores with the same
  metric/parser code.

The two corpora are deliberately split. `commands.txt` stays on the
single-command parser so its numbers remain comparable with the 2026-10-25
baseline; compound and device sentences live in `commands_plan.txt` because the
app interprets speech with `VoicePlanParser`, and that layer has its own
refusals (connectors, device targets, implied scan/connect steps).

Every metric is reported twice where it matters:

| Metric | Meaning |
|---|---|
| exact sentence (verbatim) | normalized transcript equals the expected sentence |
| exact sentence (numbers folded) | same, with "fifty" → "50" folded on both sides |
| word error rate | Levenshtein over words, mean per file, same two variants |
| transcript parses | the raw transcript is a valid Stage 1 command (or plan, with `--plan`) |
| same command | transcript parses to the same intent *and* the same parameters as the expected sentence |
| false-command rate | a negative sentence that still became a command (**must be 0**) |
| rejection rate | negative sentences correctly refused |
| entity accuracy | colour/brightness/effect/target values match the reference (plan mode) |
| decode p50/p95 | per-file decode wall-clock distribution |
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

Corpus validation and plan scoring:

```powershell
cd walsey_voice_speech
dart run bin/check_corpus.dart ../tools/voice_accuracy/commands.txt
dart run bin/check_corpus.dart ../tools/voice_accuracy/commands_plan.txt --plan
dart run bin/voice_accuracy.dart --model <model> --corpus <dir> --plan
```
Each JSON report now contains:

- `rawExact`: exact bytes of text, including capitalization and punctuation;
- `exact`: case/punctuation/whitespace-normalized sentence accuracy;
- WER and CER on normalized text, plus separate number-folded variants.

Number folding is limited to documented English number words and is reported
separately; it never changes the raw transcript.

## Human-speech benchmark (required before an engine decision)

The checked-in corpus is synthetic and is only a regression baseline. It must
not be used to claim real-speaker accuracy. To create a human corpus, record at
least 50 utterances on each target platform (or copy the same source WAVs to
both platforms), with the speaker reading a separate reference list covering
conversation, numbers, colours, quiet/normal speech, and different lengths and
speeds. Keep the original WAVs and write one `file<TAB>reference` row per file
in `expected.tsv`; do not transcribe from the engine output. Run the Vosk
harness and any alternative engine transcript exporter against that same
directory, then compare `rawExact`, normalized exact accuracy, WER, CER, model
size, RSS, decode time and real-time factor. Record the platform, OS, model
hash/version and capture diagnostics alongside each run.

No human recordings are present in this repository, and no Android device was
available for this investigation. Therefore human Windows/Android WER, CER,
latency, memory and engine-selection measurements remain blocked rather than
invented. The self-test below is the collection procedure.

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
| Tail | last chunk 3967–4006 ms, stop at 4003–4005 ms → 0–36 ms gap, no tail loss |
| First chunk | 747–762 ms in this run; **~65 ms** on a later run (see below) |
| Level | reported as digital silence; **retracted** — it was ambient room noise (see below) |

Two of that run's conclusions were later withdrawn:

- **First chunk.** The 747–762 ms delay did not reproduce. A later run on the
  same machine delivered the first chunk **~65 ms** after start (also recorded in
  [`voice_stage2.md`](voice_stage2.md)). The diagnostics panel still shows it as
  "First audio".
- **Level.** The "digital silence" was an empty room, not a dead microphone. The
  captured audio was ambient noise at **peak −11.45 dBFS**, so the `record` path
  does deliver real signal. A person speaking commands into this microphone has
  still not been measured, and clipping during loud speech is still unverified.

Direct `ffmpeg -f dshow` capture on the same machine had also reported
`mean_volume −91.0 dB`, `max_volume −90.3 dB`; that figure measured the room, so
it says nothing about the capture path. Format, rate and tail were verified and
are unaffected.

## Baseline results (2026-10-25, 60 utterances)

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

## Expanded corpus (measured 2026-11-06)

The corpus was doubled in size and split into two harness runs. Both use the
same SAPI voices, the same `vosk-model-small-en-us-0.15` and unconstrained
decoding. Numbers below are new measurements, not extrapolations from the
2026-10-25 baseline.

### Single-command corpus (`commands.txt`)

144 clips = (54 positives + 18 negatives) × 2 voices, 326.4 s of audio.

| Metric | Result |
|---|---|
| Exact sentence, raw | 70/144 (48.6%) |
| Exact sentence, normalized | 75/144 (52.1%) |
| Exact sentence, digits folded | 88/144 (61.1%) |
| WER, verbatim / digits folded | 0.2495 / 0.1791 |
| **Exact command (positives)** | **92/108 (85.2%)** |
| **Negative rejected** | **36/36 (100.0%)** |
| **False commands** | **0/36 (0.0%)** |
| Entity accuracy | 58/70 (82.9%) |
| — colour | 22/32 |
| — brightness | 20/20 |
| — effect | 16/18 |
| Decode mean / p95 | 679 ms / 836 ms |
| Real time factor | 0.300 |
| Model load | 443 ms |
| RSS after load | 322.4 MB |
| Clipping | 0 / 5,222,160 samples |

By voice: David 44/72 exact-command files, Zira 48/72.

### Plan corpus (`commands_plan.txt --plan`)

62 clips = (21 positives + 10 negatives) × 2 voices, 196.8 s of audio. This is
the first measured run of the plan layer; the 2026-10-25 report only covered
single commands.

| Metric | Result |
|---|---|
| Exact sentence, normalized | 27/62 (43.5%) |
| **Exact command (positives)** | **30/42 (71.4%)** |
| Same command, all files | 50/62 (80.6%) |
| **Negative rejected** | **20/20 (100.0%)** |
| **False commands** | **0/20 (0.0%)** |
| Entity accuracy | 18/24 (75.0%) |
| — colour | 8/14 |
| — brightness | 10/10 |
| Decode mean / p95 | 816 ms / 1,041 ms |
| Real time factor | 0.257 |
| RSS after load | 321.9 MB |

Plan accuracy is lower than single-command accuracy because a plan must
recognize **every** clause and then produce the same ordered steps; the
transcript can be perfectly understandable while one clause misses a device
target. The safety half is unaffected: all 20 negative plan sentences were
rejected and no unsafe sentence became a plan.

Reproduction:

```powershell
powershell -ExecutionPolicy Bypass -File tools/voice_accuracy/make_tts_corpus.ps1 `
  -CommandFile tools/voice_accuracy/commands.txt `
  -OutputDirectory "$env:TEMP\walsey_voice_corpus_v2"
dart run bin/voice_accuracy.dart --model <model> `
  --corpus "$env:TEMP\walsey_voice_corpus_v2" `
  --library <libvosk.dll> --out "$env:TEMP\walsey_voice_v2.json"

powershell -ExecutionPolicy Bypass -File tools/voice_accuracy/make_tts_corpus.ps1 `
  -CommandFile tools/voice_accuracy/commands_plan.txt `
  -OutputDirectory "$env:TEMP\walsey_plan_corpus"
dart run bin/voice_accuracy.dart --model <model> `
  --corpus "$env:TEMP\walsey_plan_corpus" `
  --library <libvosk.dll> --plan --out "$env:TEMP\walsey_plan_v2.json"
```

## App-path measurement (2026-11-06): decoder bias and greedy candidates

The CLI runs above approximate the app: `whisper-cli` is a different binary
surface from the app's `dart:ffi` calls. `walsey_voice_speech/bin/whisper_corpus.dart`
removes that gap — it links the app's own `WhisperBindings`, creates parameters
with `whisper_full_default_params_by_ref(0)` exactly as the app does, and writes
the same `<file>\t<transcript>\t<ms>` TSV that `voice_accuracy.dart
--transcripts` scores.

Two shipped defaults turned out to matter.

**Greedy candidates.** `whisper_full_default_params(GREEDY)` keeps
`greedy.best_of = 5`. That is five decoder candidates per window for no accuracy
gain here: identical 103/108 with one or five, but 1,030 ms vs 1,976 ms mean
and 1,198 ms vs 4,757 ms p95. The engine now asks for one candidate through the
guarded struct write, falling back to the library default if the layout guard
rejects it.

**Vocabulary bias.** The command words are out of this model's vocabulary, so it
substitutes ordinary English: "Walsey" → `Volsidy`/`Volsity`/`Havalsevie`,
"LEDDMX-03-6B4A" → `Letting 0.03-6B4A`, "green" → `screen`, "scan" → `Skin`,
"effect 7" → `FX7`. The engine now sets `initial_prompt` to a fixed sentence of
the product's own vocabulary (wake word, device-name shape, colour words,
`percent`, `effect`, `scan for devices`, `then`). It only changes which spelling
the decoder prefers; the transcript still goes through the unchanged parser.

Measured with the app path, both corpora, greedy with one candidate:

| Configuration | Single-command corpus | Plan corpus (`--plan`) |
|---|---|---|
| five candidates, no prompt (previous app defaults) | 103/108 (95.4%), RTF 0.872, p95 4,757 ms | not run through FFI |
| one candidate, no prompt | 103/108 (95.4%), RTF 0.455, p95 1,198 ms | 32/42 (76.2%), RTF 0.338, p95 1,122 ms |
| one candidate + first prompt | 107/108 (99.1%), RTF 0.548, p95 1,408 ms | 38/42 (90.5%), RTF 0.376, p95 1,278 ms |
| **one candidate + shipped prompt** | **108/108 (100%)**, RTF 0.488, p95 1,174 ms | **42/42 (100%)**, RTF 0.365, p95 1,274 ms |

Decode latency varies between runs on this machine: a rerun of the final code
measured mean 894 ms / p95 960 ms (RTF 0.394) on the single corpus and mean
929 ms / p95 1,002 ms (RTF 0.293) on the plan corpus. Read the latency columns as
0.9–1.2 s mean, ≤ 1.3 s p95.

Safety half, unchanged in every configuration: **0 false commands** (0/36 single,
0/20 plan) and every negative sentence rejected.

Entity accuracy on the shipped configuration: 70/70 single (colour 32/32,
brightness 20/20, effect 18/18) and 24/24 plan (colour 14/14, brightness 10/10).

**Beam search was measured and rejected.** With the same CLI harness,
`-BeamSize 5` scored 100/108 at RTF 0.666 against 103/108 at RTF 0.506 for greedy
on the single corpus, and 34/42 either way on the plan corpus. It was worse on
both axes, so the engine keeps greedy decoding with one candidate.

Failure classes that the prompt fixes, checked clip by clip: the wake-word
prefix, `activate effect 7`/`FX7`, `make the lights green`/`screen`,
`make the lights cyan`/`on`, `scan for devices`/`skin`, `LEDDMX-03-6B4A`/
`letting 0`/`LEDDMX03`, and `on then set`/`on the Anset`.

**This is an in-sample result.** The prompt was chosen while looking at these
same clips, so 100% is an upper bound, not an expectation for new speakers. What
the measurement does establish: the prompt adds no vocabulary the parser does
not already accept, it converts no negative into a command, and the remaining
safety property (zero unsafe commands) is untouched. A human-speech benchmark is
still required; see the section below.

## Safety changes made while measuring (2026-11-06)

The negative half of the corpus exposed two ways a spoken question could still
become an executed command. Both are now refused, and both are covered by
literal tests in `walsey_voice_core`:

- **Interrogative openers.** Speech has no question mark, and
  `should I turn the lights on` previously reached the power intent. The parsers
  now treat `should/do/does/did/is/are/am/may` as question markers and return
  `unsupported`. `can/could/would you ...` intentionally stays executable: the
  project already treats it as a polite request (`parser_power_test`), and
  changing that would break a documented behaviour.
- **Half-executed compound sentences.** `turn on the lights and play music`
  parsed the first clause and dropped the rest. The plan layer now rejects the
  whole sentence with `unsupported` when a connector introduces an unsupported
  clause, instead of silently executing half of it.

Neither change loosens anything: the registry allowlist, parameter validation,
negation, contradiction and ambiguity rules are unchanged. Core tests went from
151 to 154 with the new cases.

## Understanding changes (2026-11-12, not re-measured)

The recognition stack was not changed in this round; the parser learned more
everyday phrasings. None of the measurements above were re-run, so the numbers
in this document remain the 2026-11-06 results.

- **Literal paraphrase layer** (`walsey_voice_core/lib/src/parser/paraphrase.dart`):
  request prefixes (`could you`, `I want`, `let's`), a short phrase table
  (`get the lights working`, `power up`, `switch off`) and word aliases
  (`lighting` → `lights`, `enabled` → `on`). It is literal, runs before the
  unchanged grammar, and cannot introduce an action the registry does not
  allow. Negation, question and statement guards still run first.
- **Absolute brightness qualifiers**: `half` = 50, `quarter` = 25, `full` /
  `maximum` = 100, `minimum` = 0. These are fixed percentages, not a guess; the
  `0..100` validation and the encoder's floor scaling are untouched.
- **Status questions** (`are the lights on`, `what is the brightness`) are now
  recognized as `queryStatus` instead of being refused as questions. The
  executor reports that the protocol has no state read-back and sends nothing.
  Interrogative shape is required, so `the lights are on` is still refused.
- **Expiring follow-up memory** (`VoiceConversation`, 10-minute default) can add
  a reconnect step for pronoun follow-ups. It never stores LED state and never
  bypasses validation or device capability checks.

`bin/check_corpus.dart` was re-run after these edits (2026-11-12): commands.txt
54 positives / 18 negatives and commands_plan.txt 21 / 10, **0 problems**. The
negative `is the light on` now parses as `queryStatus`; the checker reports it as
`NON-WRITING` rather than a failure because that intent sends nothing, while any
other parsed negative still fails the check.

Recognition itself was not re-measured: no audio model/engine changed, so the
numbers above remain the 2026-11-06 results.

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
- It normalizes numbers and units itself ("50%", "FX7"). "50%" parses, but "FX7"
  does not — which is exactly what the vocabulary prompt now prevents; the
  parser itself was not loosened.

## Recommendation

1. **Whisper is the shipped primary engine**, with `ggml-base.en.bin` and the
   vocabulary prompt above; Vosk stays as the kept fallback. The prompt and the
   single-candidate decode close the accuracy gap that previously argued against
   Whisper, and the Android packaging (JNI libs built from source) exists.
2. **Do not use Vosk's larger `0.22-lgraph` model.** It is 3× larger and 5.4×
   slower with no accuracy gain on this vocabulary.
3. **Do not enable a Vosk grammar by default.** Keep it as an opt-in experiment
   for the fallback path; on wake-word utterances it is markedly worse than
   unconstrained decoding.
4. **Keep the decoder bias inside the recognizer, not in the parser.** The prompt
   only steers spelling; every command still passes the unchanged Stage 1
   validation, and a rejected parameter or an unsupported sentence still fails
   honestly.
5. **Treat the wake word as the real remaining accuracy problem**, not the
   acoustic model. Every configuration fails most wake-word utterances; that
   belongs in Stage 3 (a vocabulary-backed wake word or a dedicated keyword
   spotter), not in parser tuning. The measured result of the streaming Vosk
   proxy — 0/36 synthetic positives, 0/60 false activations — is in
   `docs/wake_word.md`.
6. **Show "listening" only once audio is actually flowing.** The measured
   first-chunk delay is small (~65 ms) but non-zero, and a slower device can open
   later. No auto-start and no background listening is implied.

## Limits of this measurement

- The corpus is **synthetic SAPI speech** with two American voices. It is a
  deterministic regression baseline, not evidence about human accents, distance,
  room noise or the S21+ microphone.
- Windows capture was verified for format, rate, timing, tail and (after the
  retraction above) signal level, but not with a person speaking commands into
  the microphone, and clipping during loud speech is unmeasured.
- No Android device was connected, so nothing here is an Android result.
- Recognition accuracy is a property of the installed model plus the audio
  path; the parser was not changed and none of these numbers authorize LED
  execution.

## Files

- `walsey_voice_speech/bin/voice_accuracy.dart` — harness (Vosk, grammar,
  external-transcript scoring, `--plan`, safety metrics).
- `walsey_voice_speech/bin/check_corpus.dart` — corpus polarity validator.
- `walsey_voice_speech/bin/whisper_corpus.dart` — app-path Whisper harness: the
  shipping `WhisperBindings`, parameters, prompt and greedy setting, writing the
  TSV that `voice_accuracy.dart --transcripts` scores.
- `walsey_voice_speech/bin/wake_accuracy.dart` — wake-phrase benchmark.
- `walsey_voice_speech/lib/src/wake/` — `PhoneticWakeMatcher`,
  `VoskWakeWordDetector`, `OnnxWakeWordDetector`, start exception.
- `walsey_voice_speech/lib/src/diagnostics/` — `wav.dart`, `audio_stats.dart`,
  `session_diagnostics.dart`.
- `walsey_voice_speech/lib/src/vosk/vosk_model_info.dart` — model graph, size,
  sample rate and grammar support.
- `apps/walsey_voice_test/lib/record_selftest.dart` — real-microphone self-test.
- `walsey_voice_speech/lib/src/audio/pcm16.dart` — preserves samples split
  across recorder chunks and rejects a truncated final sample.
- `tools/voice_accuracy/` — command list, TTS corpus generator, whisper runner.

No model archive, DLL, WAV or transcript file is committed.
