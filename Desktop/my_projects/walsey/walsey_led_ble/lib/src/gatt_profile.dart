// Pure Dart (no Flutter, no BLE plugin) description and validation of the GATT
// transport expected from an LEDDMX controller.
//
// Source for the UUIDs and the expected properties: docs/research.md
// (service FFE0, characteristic FFE1). FFE2 is not required by the protocol;
// it is recorded because the target unit exposes it with notify only.
//
// This is a Stage 2 copy of the Stage 1 probe's validation, kept in sync
// deliberately: the probe stays frozen as the read-only reference.
// The probe's version intentionally forbids writes; this package's connection
// layer writes only complete 9-byte frames through FFE1.

/// Documented LEDDMX transport service.
const String ffe0ServiceUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';

/// Documented LEDDMX transport characteristic (write + notify).
const String ffe1CharacteristicUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';

/// Extra characteristic observed on the target unit (notify only).
const String ffe2CharacteristicUuid = '0000ffe2-0000-1000-8000-00805f9b34fb';

/// Characteristic property, mirrored from the BLE plugin so this layer stays
/// testable without importing the plugin.
enum GattProperty { read, write, writeWithoutResponse, notify, indicate }

final class GattCharacteristicSnapshot {
  const GattCharacteristicSnapshot({
    required this.uuid,
    required this.properties,
  });

  final String uuid;
  final List<GattProperty> properties;

  bool has(GattProperty property) => properties.contains(property);

  String get propertyLabel =>
      properties.isEmpty ? '(none)' : properties.map((p) => p.name).join(', ');
}

final class GattServiceSnapshot {
  const GattServiceSnapshot({
    required this.uuid,
    required this.characteristics,
  });

  final String uuid;
  final List<GattCharacteristicSnapshot> characteristics;
}

/// Result of checking a discovered GATT tree against the documented transport.
final class TransportGattReport {
  const TransportGattReport({
    required this.hasFfe0,
    required this.ffe1,
    required this.ffe2,
    required this.findings,
  });

  final bool hasFfe0;
  final GattCharacteristicSnapshot? ffe1;
  final GattCharacteristicSnapshot? ffe2;

  /// Fully qualified human-readable findings, prefixed `OK:`, `FAIL:` or
  /// `NOTE:` so the UI and logs do not have to reinterpret them.
  final List<String> findings;

  bool get hasFfe1 => ffe1 != null;

  bool get ffe1Writable =>
      ffe1 != null &&
      (ffe1!.has(GattProperty.write) ||
          ffe1!.has(GattProperty.writeWithoutResponse));

  bool get ffe1Notifies => ffe1?.has(GattProperty.notify) ?? false;

  /// Required transport pieces: FFE0 present, FFE1 present and writable.
  /// Notify on FFE1 is recorded but not required for command writes.
  bool get isUsable => hasFfe0 && ffe1Writable;

  List<String> get blockers =>
      findings.where((finding) => finding.startsWith('FAIL:')).toList();
}

/// Case-insensitive UUID comparison. Also accepts the 16-bit short form
/// (`ffe0`) because some platforms print short UUIDs.
bool uuidMatches(String candidate, String fullUuid) {
  final value = candidate.trim().toLowerCase();
  final expected = fullUuid.toLowerCase();
  if (value == expected) return true;
  if (value.length == 4) return expected.startsWith('0000$value-');
  return false;
}

/// Checks the discovered services/characteristics for the documented LEDDMX
/// transport. Pure: no I/O, safe to unit test.
TransportGattReport validateTransportGatt(
  List<GattServiceSnapshot> services,
) {
  final findings = <String>[];
  final hasFfe0 =
      services.any((service) => uuidMatches(service.uuid, ffe0ServiceUuid));

  GattCharacteristicSnapshot? findCharacteristic(String fullUuid) {
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (uuidMatches(characteristic.uuid, fullUuid)) {
          return characteristic;
        }
      }
    }
    return null;
  }

  final ffe1 = findCharacteristic(ffe1CharacteristicUuid);
  final ffe2 = findCharacteristic(ffe2CharacteristicUuid);

  if (hasFfe0) {
    findings.add('OK: FFE0 transport service present');
  } else {
    findings.add('FAIL: FFE0 transport service not found');
  }

  if (ffe1 == null) {
    findings.add('FAIL: FFE1 transport characteristic not found');
  } else if (!ffe1.has(GattProperty.write) &&
      !ffe1.has(GattProperty.writeWithoutResponse)) {
    findings.add(
      'FAIL: FFE1 has neither write nor writeWithoutResponse '
      '(properties: ${ffe1.propertyLabel})',
    );
  } else {
    findings.add('OK: FFE1 is writable (${ffe1.propertyLabel})');
  }

  if (ffe1 != null) {
    if (ffe1.has(GattProperty.notify)) {
      findings.add('NOTE: FFE1 notify present (password-status replies)');
    } else {
      findings.add(
        'NOTE: FFE1 notify absent; password-status replies will not be '
        'available',
      );
    }
    if (!ffe1.has(GattProperty.read)) {
      findings.add('NOTE: FFE1 read absent');
    }
  }

  if (ffe2 == null) {
    findings.add('NOTE: FFE2 not present (not required by the protocol)');
  } else {
    findings.add(
      'NOTE: FFE2 present with properties [${ffe2.propertyLabel}] '
      '(observed notify-only; unused)',
    );
  }

  return TransportGattReport(
    hasFfe0: hasFfe0,
    ffe1: ffe1,
    ffe2: ffe2,
    findings: List.unmodifiable(findings),
  );
}
