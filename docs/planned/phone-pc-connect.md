# Plan: Phone ↔ PC connect

**Status: not implemented. The Connect page explains the requirement and
contains no pairing, transfer, clipboard or notification code.**

## Goal

One Walsey ecosystem across a phone and a PC:

- file transfer in both directions;
- clipboard sync (text and links);
- phone → PC notification mirroring;
- optional remote input (PC controls phone).

This is separate from BLE LED control. It must not be added to the LED stack or
weaken its safety rules.

## Hard problems to decide first

1. **Transport and network.** Phone and PC may be on the same LAN, different
   networks, or offline. A cloud relay contradicts the offline-first stance; a
   LAN-only design needs a clear explanation when the devices are apart.
2. **Trust.** Pairing must use an explicit code shown on both devices, a stored
   device identity and a way to revoke it. No silent auto-pair.
3. **Encryption.** Local traffic still needs authenticated encryption. Do not
   invent a custom cipher; use a reviewed library and pin the protocol version.
4. **Platform permissions.**
   - Android notification access needs the notification-listener permission and
     a user-facing explanation.
   - Clipboard access differs by Android version and Windows session.
   - File access must use scoped storage / document pickers, not broad paths.
5. **Honesty.** Progress bars must reflect real bytes. Cancellation, resume and
   partial files must be real states, not animations.

## Proposed staged delivery

### Stage 1 — discovery + pairing

- LAN discovery (mDNS or an explicit address entry).
- Pairing code + persistent key + revoke.
- A visible "paired devices" list.
- Tests with two real devices on the same network.

### Stage 2 — clipboard text

- Explicit **Send clipboard** and optional auto-sync while both apps are open.
- Size limit, conflict policy, no history by default.
- Never upload clipboard content anywhere.

### Stage 3 — file transfer

- Chunked transfer with real progress, pause/cancel, resume by offset and a
  content digest.
- Destination chosen by the receiving user.
- No background transfer without a visible indicator.

### Stage 4 — notification mirroring

- Android listener → PC display.
- Per-app opt-in/opt-out, redaction of sensitive fields, no storage by default.
- Clear "notification access" permission flow.

### Stage 5 — remote input

- Explicit pairing and a visible "remote control active" state on the phone.
- Bounded actions; no silent keyboard capture.
- A one-tap stop on both sides.

## Architecture sketch

```
apps/walsey (Windows)                    apps/walsey (Android)
  PairingService  ← authenticated channel →  PairingService
  TransferService                            TransferService
  ClipboardAdapter                           ClipboardAdapter
  NotificationAdapter                        NotificationListener
  RemoteInputAdapter                         RemoteInputAdapter
```

- Put the shared protocol/model in a new pure-Dart package if more than one
  package needs it; do not put it in `walsey_led_core` or either voice package.
- Platform code stays behind adapter interfaces so unit tests use fakes.
- No dependency on the LED connection state.

## Tests

- Pairing: wrong code, expired code, revoked key, replay rejection.
- Transfer: chunk order, digest mismatch, cancel, resume, disk-full, partial
  cleanup.
- Clipboard: size limit, conflict, no history by default.
- Notifications: opt-out, redaction, permission denial.
- Remote input: unauthorized peer rejected, stop closes the channel.
- Two-device manual test before any "working" claim.

## Acceptance

- Pairing is explicit and revocable.
- No cloud relay and no telemetry by default.
- Progress and outcomes are real.
- The LED app remains usable when the PC/phone link is unavailable.
