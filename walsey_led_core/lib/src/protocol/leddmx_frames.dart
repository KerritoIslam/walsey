import 'dart:typed_data';

import '../domain/errors.dart';
import '../domain/values.dart';
import 'leddmx_variant.dart';

// Pure frame encoders for LEDDMX controllers (service FFE0, characteristic
// FFE1). No I/O, no state, no timing.
//
// EVIDENCE: every layout below is taken from LED_UNION (MIT,
// https://github.com/chameleonbr/LED_UNION), which derived it by decompiling
// the vendor app "LED+LAMP 4.3.5". It has NOT been observed working on this
// project's controller. See docs/research.md.
//
// Frames are always 9 bytes with no checksum.

const int _f = 0xFF; // filler byte
const int _head = 0x7B;
const int _tail = 0xBF;

/// Default controller password documented by LED_UNION: A1 23 45 67.
const List<int> defaultPassword = [0xA1, 0x23, 0x45, 0x67];

/// `7B 04 04 <on> FF FF FF FF BF` (filler) / `7B 04 <on> FF FF FF FF FF BF`
/// (shifted).
Uint8List encodePower(LeddmxLayout layout, {required bool on}) {
  final v = on ? 0x01 : 0x00;
  return switch (layout) {
    LeddmxLayout.filler => _frame([_head, 0x04, 0x04, v, _f, _f, _f, _f, _tail]),
    LeddmxLayout.shifted => _frame([_head, 0x04, v, _f, _f, _f, _f, _f, _tail]),
  };
}

/// `7B FF 07 r g b 00 FF BF` (filler) / `7B 07 r g b 00 FF FF BF` (shifted).
///
/// In the shifted layout byte 5 is documented as a white channel. LED_UNION's
/// driver sends 0 "to keep it out of the mix"; that value is an assumption
/// until verified on hardware.
Uint8List encodeRgb(LeddmxLayout layout, RgbColor c) {
  return switch (layout) {
    LeddmxLayout.filler =>
      _frame([_head, _f, 0x07, c.r, c.g, c.b, 0x00, _f, _tail]),
    LeddmxLayout.shifted =>
      _frame([_head, 0x07, c.r, c.g, c.b, 0x00, _f, _f, _tail]),
  };
}

/// Filler: `7B FF 01 <(v*32)/100> <v> 00 FF FF BF` — brightness is sent twice,
/// scaled to 0..32 and raw. Shifted: `7B 01 <v> 00 FF FF FF FF BF`.
///
/// OPEN QUESTION: the scaled byte uses integer division (floor), matching the
/// documented formula `(v*32)/100` from the decompiled Java. LED_UNION's own
/// driver uses `Math.round`, which differs for e.g. 30% (9 vs 10). Neither has
/// been confirmed on hardware; see docs/hardware_checklist.md H7.
Uint8List encodeBrightness(LeddmxLayout layout, BrightnessLevel b) {
  final v = b.percent;
  return switch (layout) {
    LeddmxLayout.filler =>
      _frame([_head, _f, 0x01, (v * 32) ~/ 100, v, 0x00, _f, _f, _tail]),
    LeddmxLayout.shifted =>
      _frame([_head, 0x01, v, 0x00, _f, _f, _f, _f, _tail]),
  };
}

/// Built-in effect: `7B FF 03 <id> FF FF FF FF BF` (filler) /
/// `7B 03 <id> FF FF FF FF FF BF` (shifted).
///
/// `0x03` is the BUILT-IN mode opcode; `0x13` is user DIY patterns and is
/// intentionally not exposed.
Uint8List encodeEffect(LeddmxLayout layout, LedEffect e) {
  return switch (layout) {
    LeddmxLayout.filler =>
      _frame([_head, _f, 0x03, e.id, _f, _f, _f, _f, _tail]),
    LeddmxLayout.shifted =>
      _frame([_head, 0x03, e.id, _f, _f, _f, _f, _f, _tail]),
  };
}

/// Authentication handshake: `2A 02 p0 p1 p2 p3 <tb> <min> AF`.
///
/// LED_UNION reports the controller ignores every other command until it
/// receives this; the original app sends it 300 ms after connecting. NOTE: it
/// also sets the controller's clock from [now].
///
/// `tb = (weekIndex << 5) | hour24`, with weekIndex Mon=1 … Sun=7, which is
/// exactly Dart's [DateTime.weekday].
Uint8List encodeHandshake(DateTime now,
    {List<int> password = defaultPassword}) {
  if (password.length != 4) {
    throw InvalidCommandException(
        'password must be exactly 4 bytes, got ${password.length}');
  }
  for (final b in password) {
    if (b < 0 || b > 255) {
      throw InvalidCommandException('password byte out of range: $b');
    }
  }
  final tb = (now.weekday << 5) | now.hour;
  return _frame([0x2A, 0x02, ...password, tb, now.minute, 0xAF]);
}

/// Password status query `2A 05 FF FF FF FF FF FF AF`. Per LED_UNION this is
/// also what enables notifications.
Uint8List encodePasswordQuery() =>
    _frame([0x2A, 0x05, _f, _f, _f, _f, _f, _f, 0xAF]);

Uint8List _frame(List<int> bytes) {
  assert(bytes.length == 9, 'frames are always 9 bytes');
  assert(bytes.every((b) => b >= 0 && b <= 255), 'byte out of range');
  return Uint8List.fromList(bytes);
}
