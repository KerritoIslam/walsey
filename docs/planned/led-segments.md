# Plan: LED segments / split-by-parts

**Status: deliberately unsupported. No segment frame exists, and Studio shows
the feature as not supported.**

Reference: [`../led_segments.md`](../led_segments.md).

## Why it is blocked

The protocol evidence contains no per-zone or per-segment paint command:

- every command is 9 bytes, `7B … BF`, one value per frame;
- the only multi-pixel structure is the **addressable-strip configuration**
  frame (pixel count + channel order), not a zone paint;
- effects ≥ 73 may animate across the strip, but that is effect behaviour, not
  addressable control;
- there is no read-back, so the app cannot discover zones, lengths or whether a
  zone command was accepted.

A fake "segment 1 / segment 2" UI would imply a capability the app cannot
verify, and would tempt a future change to send guessed bytes to a live
controller.

## What would have to be true first

1. Hardware checklist rows for power/colour/brightness/effect pass on **both**
   Windows and Android.
2. A vendor-app capture or a decompiled frame with a plausible offset/length
   field is documented in [`../research.md`](../research.md) with exact bytes.
3. A human observer confirms that changing one zone leaves the others unchanged
   (`USER OBSERVATION:`), on more than one variant.
4. The frame can be expressed as a pure encoder plus a validated value object
   (zone index/length ranges enforced, unknown variants refused).
5. Failure modes are defined: out-of-range zone, unsupported variant, queue
   timeout, link loss mid-sequence.

## Implementation shape if the evidence appears

- Add a validated `Segment` / `SegmentColor` value object in
  `walsey_led_core/lib/src/domain/`.
- Add a pure encoder in `leddmx_frames.dart`. Keep it free of I/O and timing.
- Add literal expected-byte tests, hand-written from the spec.
- Route through `LeddmxDriver` and `WriteQueue`; no direct transport access.
- Refuse the command when the resolved variant does not document it.
- Add the hardware checklist rows and raise evidence only after both platforms
  pass.
- Only then expose UI controls. Until then, keep "Not supported".

## Tests

- Value-object ranges and invalid input.
- Literal frame bytes for each documented layout.
- Variant refusal for unsupported names.
- Queue serialisation and timeout behaviour.
- No UI control exists before the encoder does.

## Acceptance

- There is a documented, exact frame — not a guess.
- A human observation confirms per-zone behaviour.
- Every write still goes through the single queue and the same evidence rules.
