# Music-reactive mode: investigation and prototype

Status: **not implemented, no audio is sent to the LEDs.** This document records
what a music-reactive mode would need, what was prototyped (an offline spectrum
analyzer with tests), and exactly which questions require hardware.

## What exists

- `apps/walsey/lib/music/spectrum.dart` — pure-Dart, offline analysis:
  iterative radix-2 FFT, Hann window, half-spectrum magnitudes, dominant
  frequency and bass/mid/treble band energy for one PCM16 window.
- `apps/walsey/test/spectrum_test.dart` — 7 tests with generated sines and DC:
  peak frequency, band placement, silence, empty window, non-power-of-two
  refusal, no hidden streaming state.

It does **not**:

- open a microphone or capture playback audio;
- run on a timer or in an isolate;
- call `LedTransport`, `LeddmxDriver`, `LedControlService` or any encoder;
- ship in any UI path.

The analyzer is deterministic and testable, which is the part that can be built
without hardware. Everything below is the part that cannot.

## Why it is not wired up

### 1. No LED effect is confirmed on hardware

No LEDDMX frame has ever been observed changing an LED on the target controller
(see `docs/hardware_checklist.md`). A music mode would send frames continuously,
far faster than the manual command path, so shipping it before the basic
colour/power/effect checklist would multiply unverified assumptions.

### 2. Frame rate vs. the write queue

`WriteQueue` serialises writes with a ≥ 50 ms gap and a 5 s timeout. That caps
any reactive mode at roughly **20 frames/second** even before BLE latency and
the controller's own processing. A smooth 30–60 fps visualiser is not possible
through this protocol as documented. Any implementation must:

- resample/downsample the analysis to the achievable frame rate;
- coalesce frames instead of queueing an unbounded backlog;
- drop stale frames rather than delaying them (a late colour is worse than no
  colour);
- stop sending when the queue reports block-after-timeout.

### 3. Unknown protocol capabilities

- The 9-byte command frames carry one colour/brightness/effect each. There is no
  documented per-segment or per-pixel command.
- The addressable-strip configuration frame (`7B FF 05 04 …`) exists in the
  decompiled app but its persistence and the vendor app's configuration are
  unknown (`docs/research.md` §addressable-strip configuration).
- Effects 73+ are variant-dependent and unspecified. A "music mode" built on an
  unknown effect id would be guessing.

### 4. Audio capture on Android is not free

- Capturing the **microphone** while music plays records the room, not the
  stream, and needs `RECORD_AUDIO` plus a visible foreground service for
  background operation (see `docs/wake_word.md`).
- Capturing **other apps' playback** requires `MediaProjection` consent and, on
  Android 10+, `AudioPlaybackCaptureConfiguration`; many apps opt out. This app
  has no MediaProjection flow, and adding one is a product/privacy decision, not
  a flag.
- Windows would use WASAPI loopback, another native dependency with its own
  packaging cost.

### 5. Latency and honesty

A reactive mode must not claim synchronisation it cannot measure. The measured
microphone first-chunk delay is small (~65 ms on this Windows machine, see
`docs/voice_accuracy.md`), but decoder windows, BLE connection interval and
controller processing add more. The UI would have to show "approximate", not
"in sync".

## Minimal prototype that would be defensible next

1. Finish the hardware checklist for power/colour/brightness/effect, including
   the addressable-strip configuration rows.
2. Add a **file-based** analysis harness: decode a WAV, run `SpectrumAnalyzer`
   in fixed windows, map bands to `RgbColor`, and print the frame sequence. No
   transport, no timer, no microphone — this validates the mapping and pacing
   offline.
3. Add a **fake transport** test that runs the same sequence through
   `WriteQueue` and asserts: bounded queue, stale-frame dropping, stop on
   timeout, no write after stop.
4. Only then test on hardware with a fixed test tone and a human observer,
   recording `USER OBSERVATION:` separately from `BLE WRITE OK`.

Until steps 1–4 exist, the Studio page correctly reports music modes as
unsupported rather than simulating them.

## Safety rules for any future implementation

- Explicit user start/stop; no auto-start on connection.
- Stop sending immediately when the user disables it, the app backgrounds (unless
  a visible foreground service is active), the link drops, or the queue reports a
  timeout.
- No hidden recording, no audio upload, no cloud analysis.
- Band→colour mapping is deterministic and documented; never invent an effect id.
- Log writes as writes; a human observation is the only confirmation.
