# Split-by-parts ("segments") investigation

Status: **not implemented, deliberately.** The Studio page lists segments as an
unsupported feature. No segment frame exists in this repository, and no
segment behaviour has been observed on the target controller. The conditions for
implementing it are in [`planned/led-segments.md`](planned/led-segments.md).

## What "segments" would mean

Two different features are commonly called segments:

1. **Addressable-strip zones.** A pixel strip is divided into logical zones
   (for example two halves of a strip, or several connected strips), each with
   its own colour/effect.
2. **Multiple outputs.** One controller drives several physical outputs and the
   vendor app addresses them separately.

Nothing in the collected protocol evidence distinguishes these from "configure
the whole strip" with a different colour. There is no confirmed per-zone command.

## What the evidence actually says

- Every command frame is **9 bytes**, `7B … BF`, no checksum, no fragmentation
  (`docs/research.md`).
- The only multi-pixel structure found in the decompiled app is the
  **addressable-strip configuration** frame:
  - filler: `7B FF 05 04 <pixHi> <pixLo> <order> FF BF`
  - shifted: `7B 05 <order> <pixHi> <pixLo> FF FF FF BF`

  It configures the strip length and channel order. It is not a per-segment
  paint command.
- Colour, brightness, power and effect frames carry one value each. There is no
  documented offset/length field.
- Effect ids ≥ 73 are variant-dependent; some effects may render across the
  strip in ways that look segmented. That is effect behaviour, not addressable
  control.
- The protocol has **no read-back**. The app cannot discover the strip length,
  the current zones, or whether a zone command was accepted. The vendor app's
  configuration is unknown.

## Why it is not simulated

A fake "segment 1 / segment 2" UI would imply a capability the app cannot
verify. Worse, it would tempt a future change to send guessed byte
combinations to a live controller. The project rule is explicit: report an
unsupported feature rather than simulate it (`docs/architecture.md`).

## What would have to be true before implementing

1. Hardware checklist rows for power/colour/brightness/effect pass on both
   Windows and Android.
2. A capture of the vendor app sending a zone-specific change, or a decompiled
   frame with a plausible offset/length field, is documented in
   `docs/research.md` **with the exact bytes**.
3. A human observer confirms that changing one zone leaves the others
   unchanged (`USER OBSERVATION:`), on more than one variant.
4. The frame can be expressed as a pure encoder plus a validated value object
   (zone index/length ranges enforced, unknown variants refused).
5. Failure modes are defined: out-of-range zone, unsupported variant, queue
   timeout, and link loss mid-sequence.

Only then would a `SetSegmentColor` command (or similar) be added to
`walsey_led_core`, with literal expected-byte tests and a `WriteQueue` path.
Until then, the honest answer to "split by parts" is: **unknown, not
supported**.

## Related

- `docs/research.md` — decompiled frame evidence and open questions.
- `docs/hardware_checklist.md` — the rows that must pass first.
- `docs/music_mode.md` — the other unverified Studio feature.
