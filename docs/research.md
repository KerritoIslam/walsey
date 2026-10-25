# Protocol research report (Stage 1)

Status: **research only. Nothing here has been verified on the target controller.**
Date of research: 2026-10-23.

## 1. Sources read

| # | Source | What I read | How |
|---|---|---|---|
| S1 | `chameleonbr/LED_UNION` README | Family table, status, protocol "gotchas" | fetched |
| S2 | `docs/protocol/ledble.md` | Transport, handshake, `7B…BF` frame tables, pacing | fetched |
| S3 | `src/lib/protocol/ffe0.ts` | Actual driver: `layoutFor()`, builders, `NEEDS_AUTH`, `minGapMs` | cloned, read |
| S4 | `docs/protocol/variants.md` | Cross-check against `elkbledom` (hardware-sniffed) | cloned, read |
| S5 | `docs/protocol/dmx_model.tsv`, `dmx03_model.tsv` | Effect id tables | cloned, diffed |
| S6 | `tools/difftest/README.md`, `src/lib/protocol/frames.test.ts` | What the verification actually covers | cloned, read |
| S7 | pub.dev `bluetooth_low_energy` 6.2.1 docs + `CentralManager` API page | Platform matrix, method signatures | fetched |

Not read: the decompiled vendor app itself (not published by LED_UNION), the Portuguese docs, the BLEDIM/ELK/MELK specs (different families), `elkbledom`'s own repo.
LED_UNION licence: **MIT** (verified in `LICENSE`). Its README states the repo contains only protocol facts, no vendor code.

## 2. Which variant matches the controller?

**Not yet determinable. This is the central finding.**

What we know about the physical unit: vendor app *LED LAMP*, listed as "LED DMX", power in V+/V−/VCC, output GND/DAT/VCC.

- The single **DAT** output wire indicates an addressable (SPI/pixel) strip. That is consistent with the LEDDMX/LEDCAR family, which S2 says drives addressable strips. It does **not** distinguish between LEDDMX sub-variants.
- "LED DMX" is the vendor app's display label. It is not a BLE advertised name, and per S3 the layout is chosen **purely by the advertised-name prefix**; nothing is read back from the device.
- The two layouts differ by one byte of shift in every frame (see §4). Sending the wrong one is not an error the controller reports.

**Decision rule implemented** (`resolveVariant`): only an advertised `LEDDMX-NN[-suffix]` is accepted; `00/01/03 → filler`, `02/04 → shifted`, anything else, including the literal "LED DMX", → `UnsupportedVariant`. The BLE probe (`tools/ble_probe`) exists to read the real advertised name.

Not yet covered: LEDCAR-01/02 share these layouts but have their own power frame / flags (S2). They are rejected rather than approximated.

## 3. Evidence levels

| Level | Meaning | Applies to |
|---|---|---|
| **H** hardware-confirmed | Seen working on a real controller | LED_UNION claims this **only** for `LEDBLE-00` (`7E…EF`): connect, `2A` handshake, colour. **No LEDDMX variant is hardware-confirmed**, by LED_UNION or by us. |
| **D** decompiled | Byte-matched to the vendor app's code | All `7B…BF` frames. LED_UNION's difftest: 221/221 frames match the app. |
| **U** unknown/inferred | Not in any source | See §6 |

**What the difftest does and does not prove (S6).** It matches positions the app pins to constants; variable-filled positions are "free". So it proves frame *shape* equals the app's, not that the value bytes (e.g. the brightness scaling) are computed the same way.

**Transport connectivity is hardware-observed (2026-10-23).** On Android, the
probe connected to `LEDDMX-03-6B4A` and discovered FFE0, FFE1 and FFE2 (details
in §4). This confirms GATT compatibility only. No frames were sent, so the
frame tables below remain D-level hypotheses and no `Evidence` may be raised to
`hardwareConfirmed`.

**Hardware evidence that decompiled ≠ real firmware (S4).** For LEDBLE, hardware-sniffed frames from `elkbledom` differ from the decompiled ones in byte 1 and padding (`7E FF 04 01 00 FF FF 00 EF` vs `7E 00 04 01 00 00 00 00 EF`). LED_UNION's own conclusion: *"firmware varies between units that advertise the same name."* Treat every D-level frame as a hypothesis for our unit.

LED_UNION also reports one unexplained hardware observation (S2): on an `LEDBLE-00`, the default colour frame (byte 7 = `FF`) changed only one of several physical outputs, so byte 7 may be an output selector the docs don't map. Not known to apply to LEDDMX; flagged for the hardware checklist.

## 4. Protocol facts (all D-level unless stated)

**Transport**: service `0000ffe0-0000-1000-8000-00805f9b34fb`; write + notify characteristic `0000ffe1-…`. Write type "never set by the app → default (with response)". Notifications via CCCD `0x2902 = 0100`. *Divergence (S4):* `elkbledom` lists `ffe1` write / `ffe2` read for LEDBLE, whereas S2 says `ffe1` is write+notify and `ffe2` unused. **Observed on the target `LEDDMX-03-6B4A` (Android, 2026-10-23):** `ffe1` exposes read, write, write without response and notify; `ffe2` exists with **notify only**. This is a GATT-layout observation only — no frames were sent.

**Frames**: always 9 bytes, no checksum, never fragmented.

| Command | `filler` (LEDDMX-00/01/03) | `shifted` (LEDDMX-02/04) |
|---|---|---|
| power | `7B 04 04 <1\|0> FF FF FF FF BF` | `7B 04 <1\|0> FF FF FF FF FF BF` |
| rgb | `7B FF 07 r g b 00 FF BF` | `7B 07 r g b 00 FF FF BF` |
| brightness | `7B FF 01 <⌊v·32/100⌋> <v> 00 FF FF BF` | `7B 01 <v> 00 FF FF FF FF BF` |
| built-in effect | `7B FF 03 <id> FF FF FF FF BF` | `7B 03 <id> FF FF FF FF FF BF` |

The flag byte in brightness (`00`) is not stated in S2 (it shows `<f>`); it comes from S3's code. The shifted-layout RGB byte 5 is a white channel; S3 sends `0`.

**Handshake**: ~300 ms after connect, `2A 02 p0 p1 p2 p3 <tb> <min> AF`, default password `A1 23 45 67`, `tb = (weekIndex<<5)|hour24` (Mon=1…Sun=7). S1/S3: controller **ignores all commands until this is sent**. Side effect: it sets the controller's clock. Password query `2A 05 FF×6 AF`; reply `2A 05 <status>` (1 wrong password, 2 all-same-digit, 3 resend). That reply is the **only** notification the vendor app decodes; **there is no state read-back**. Consequence: "last command sent" ≠ device state. Only the password status reply exists.

**Pacing**: original app uses a *time gate that drops* writes inside the window (RGB 50 ms, brightness 30 ms, list upload 100 ms, dynamic DIY 300 ms). LED_UNION uses a serial queue with `minGapMs = 50` for this family. Our queue will serialize and wait ≥ 50 ms, never drop. Is 50 ms enough on Windows? Unknown.

**Effects**: ids `1..210` plus `255 = AUTO` (211 entries). **The two tables `dmx_model.tsv` and `dmx03_model.tsv` agree for ids 1–72 and diverge from id 73 to 210**, and S3 only ever uses `dmx_model`. So an effect id ≥ 73 may play a different effect on `-03`. Neither table contains an effect named "rainbow"; the nearest are `3 Forward 7 Colors` / `4 Backward 7 Colors` (identical in both tables). Any "rainbow" voice alias will therefore be an explicit, documented choice of id 3, pending hardware confirmation. Ids 1–72 only.

**Addressable-strip configuration**: LEDDMX drives pixel strips and "without configuration, effects render with the wrong colours or on part of the strip, and nothing reports an error" (S1). Config frame: `7B FF 05 04 <pixHi> <pixLo> <order> FF BF` (filler) / `7B 05 <order> <pixHi> <pixLo> FF FF FF BF` (shifted). **Not implemented**: whether the controller persists it, and what the vendor app already configured, is unknown. Colour mismatches on first test are expected to be configuration, not a bug.

## 5. `bluetooth_low_energy` evaluation (S7)

- Version documented: **6.2.1**, Flutter plugin (**not pure Dart**). So BLE transport cannot live in the core package; it goes behind an interface in a separate package.
- Platform matrix (docs): `connect`, `disconnect`, `discoverGATT`, `read/writeCharacteristic`, `setCharacteristicNotifyState`, `startDiscovery`, `getMaximumWriteLength` are ticked for Android **and** Windows.
- Limitations relevant to us: `authorize` Android-only; `requestMTU` Android-only (frames are 9 bytes, so MTU is irrelevant); `readRSSI` and `retrieveConnectedPeripherals` not on Windows (we use neither); Android `minSdk` **24**; BLE does not work on emulators.
- Write API requires an explicit `GATTCharacteristicWriteType` (`withResponse` matches S2's "default").
- **Hardware verification status: unknown.** The docs publish an API matrix, not a test report. I found no statement that Windows or Android behaviour was verified against LED controllers. Alternatives (e.g. `flutter_blue_plus`) were **not evaluated** in this stage.
- Not compiled here: the authoring sandbox has no Dart SDK and no pub.dev access (see README).

## 6. Uncertainties (each is a hardware-checklist item)

1. Actual advertised name → layout (H1).
2. FFE0/FFE1 present, and FFE1's real property set (H2).
3. Whether LEDDMX accepts the documented handshake and default password; whether the vendor app changed the password (H4).
4. Brightness scaling: floor (`(v*32)/100`, docs/Java) vs round (S3 driver). They differ for **48 of 101** percentages, by one step on a 0–32 scale. We emit floor (H7).
5. Effect id semantics ≥ 73 per sub-variant (H8).
6. Pixel count / colour-order configuration needed before colours look right (H9).
7. Byte 7 as an output selector (H5).
8. Write pacing on Windows vs Android (H10).
9. Disconnect behaviour: does the controller keep its last state, and does it accept reconnects without the vendor app closed (H3, H11).
