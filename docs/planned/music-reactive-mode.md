# Plan: music-reactive mode

**Status: analysis prototype only. No audio is sent to the LEDs, and no shipped
UI path calls the analyzer.**

Reference: [`../music_mode.md`](../music_mode.md).

## What exists

- `apps/walsey/lib/music/spectrum.dart` — pure-Dart radix-2 FFT, Hann window,
  half-spectrum magnitudes, dominant frequency and bass/mid/treble band energy.
- 7 tests with generated sines, DC, silence, empty windows and a
  non-power-of-two refusal.
- It is not open in any page, runs on no timer, captures no audio and calls no
  transport.

## Constraints that shape the design

1. **Hardware is unverified.** No LEDDMX frame has ever been observed changing
   the strip. Music mode sends many frames per second, so it must come after the
   basic power/colour/brightness/effect checklist passes.
2. **Frame rate.** `WriteQueue` enforces a ≥ 50 ms gap, so the ceiling is roughly
   20 frames/s before BLE latency and controller processing. A 60 fps
   visualiser is not possible through this protocol.
3. **No backlog.** Coalesce frames and drop stale ones. A late colour is worse
   than no colour. Stop when the queue reports block-after-timeout.
4. **Audio source.** Microphone capture records the room, not the stream. System
   playback capture needs `MediaProjection` + `AudioPlaybackCaptureConfiguration`
   on Android and WASAPI loopback on Windows. Each is a product/privacy decision,
   not a flag.
5. **Honesty.** The UI can say "approximate", never "in sync".

## Proposed path

### Step 1 — file-based mapping harness (no hardware)

- Decode a WAV, run `SpectrumAnalyzer` in fixed windows, map bands to `RgbColor`
  deterministically, and print the frame sequence.
- Validate the mapping with unit tests (bass → red, mid → green, treble → blue,
  silence → off, clipping handling).
- No timer, no microphone, no transport.

### Step 2 — pacing over a fake transport

- Feed the sequence through `WriteQueue` with a fake transport and a fake clock.
- Assert: bounded queue, ≥ 50 ms spacing, stale-frame dropping, stop on timeout,
  no write after stop.

### Step 3 — explicit UI session

- Start/stop button; no auto-start on connection or launch.
- Choose the source (microphone vs system playback) with an explanation of what
  each captures.
- Show "approximate" latency and the measured send rate.
- Stop on link loss, queue block, app background (unless a visible foreground
  service is active) and user stop.

### Step 4 — hardware trial

- Use a fixed test tone and a human observer. Record `USER OBSERVATION:`
  separately from `BLE WRITE OK`.
- Measure the smallest reliable interval on the target controller (checklist
  H10).
- If frames are dropped or the strip resets, stop and document it; do not
  increase the rate.

## Out of scope until hardware is verified

- Per-pixel / addressable-strip effects (see [`led-segments.md`](led-segments.md)).
- Effect-id-driven "music modes" — ids ≥ 73 are variant-dependent and unspecified.
- Beat detection marketed as synchronisation.

## Tests

- Analyzer: existing 7 plus band mapping, window edges, silence and clipping.
- Scheduler: coalescing, drop-stale, bounded queue, stop on timeout.
- App: explicit start, no launch auto-start, stop on lifecycle/link loss, no
  fake amplitude meter.

## Acceptance

- Nothing is sent until the basic hardware checklist passes.
- The send rate is honestly bounded and measured.
- A human observation is the only proof of visible output.
- No hidden recording, no audio upload.
