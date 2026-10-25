import '../domain/capabilities.dart';

/// Byte layout of the `7B … BF` frames.
///
/// Source: LED_UNION `docs/protocol/ledble.md` ("LEDDMX and LEDCAR frames")
/// and `src/lib/protocol/ffe0.ts` `layoutFor()`.
enum LeddmxLayout {
  /// `7B FF <cmd> …` — LEDDMX-00 / 01 / 03.
  filler,

  /// `7B <cmd> …` — no `FF` filler, parameters shift one byte left.
  /// LEDDMX-02 / 04.
  shifted,
}

/// Outcome of mapping an *advertised BLE name* to a documented layout.
///
/// The vendor app labels the product "LED DMX", but that label is not an
/// advertised name and is deliberately NOT accepted. Only a scanned name of
/// the form `LEDDMX-NN[-suffix]` is.
sealed class VariantResolution {
  const VariantResolution();

  DeviceCapabilities get capabilities;
}

final class SupportedVariant extends VariantResolution {
  const SupportedVariant({required this.layout, required this.advertisedName});

  final LeddmxLayout layout;
  final String advertisedName;

  /// All four capabilities rest on decompiled-app evidence only. None has been
  /// observed on this project's target controller.
  @override
  DeviceCapabilities get capabilities => const DeviceCapabilities({
        Capability.power: CapabilitySupport.supported(Evidence.decompiledApp),
        Capability.color: CapabilitySupport.supported(Evidence.decompiledApp),
        Capability.brightness:
            CapabilitySupport.supported(Evidence.decompiledApp),
        Capability.effect: CapabilitySupport.supported(Evidence.decompiledApp),
      });
}

final class UnsupportedVariant extends VariantResolution {
  const UnsupportedVariant(this.reason);

  final String reason;

  @override
  DeviceCapabilities get capabilities => DeviceCapabilities.noneBecause(reason);
}

final _leddmxName = RegExp(r'^LEDDMX-(\d{2})(?!\d)', caseSensitive: false);

/// Maps an advertised name to a layout, or explains why it can't.
VariantResolution resolveVariant(String? advertisedName) {
  final name = advertisedName?.trim();
  if (name == null || name.isEmpty) {
    return const UnsupportedVariant('device advertised no name');
  }

  final match = _leddmxName.firstMatch(name);
  if (match == null) {
    return UnsupportedVariant(
        'advertised name "$name" is not an LEDDMX-NN name; no documented '
        'layout is implemented for it');
  }

  switch (match.group(1)) {
    case '00':
    case '01':
    case '03':
      return SupportedVariant(
          layout: LeddmxLayout.filler, advertisedName: name);
    case '02':
    case '04':
      return SupportedVariant(
          layout: LeddmxLayout.shifted, advertisedName: name);
    default:
      return UnsupportedVariant(
          'LEDDMX-${match.group(1)} is not among the documented variants '
          '(00, 01, 02, 03, 04)');
  }
}
