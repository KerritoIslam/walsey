import 'package:ble_probe/ble/gatt_profile.dart';
import 'package:flutter_test/flutter_test.dart';

GattCharacteristicSnapshot characteristic(
  String uuid,
  List<GattProperty> properties,
) =>
    GattCharacteristicSnapshot(uuid: uuid, properties: properties);

GattServiceSnapshot service(
  String uuid,
  List<GattCharacteristicSnapshot> characteristics,
) =>
    GattServiceSnapshot(uuid: uuid, characteristics: characteristics);

/// Mirrors the Android result for LEDDMX-03-6B4A.
List<GattServiceSnapshot> targetGatt({bool includeFfe2 = true}) => [
      service(ffe0ServiceUuid, [
        characteristic(ffe1CharacteristicUuid, [
          GattProperty.read,
          GattProperty.write,
          GattProperty.writeWithoutResponse,
          GattProperty.notify,
        ]),
        if (includeFfe2)
          characteristic(ffe2CharacteristicUuid, [GattProperty.notify]),
      ]),
    ];

void main() {
  test('accepts the target FFE0/FFE1/FFE2 transport', () {
    final report = validateTransportGatt(targetGatt());

    expect(report.hasFfe0, isTrue);
    expect(report.hasFfe1, isTrue);
    expect(report.ffe1Writable, isTrue);
    expect(report.ffe2, isNotNull);
    expect(report.ffe2!.properties, [GattProperty.notify]);
    expect(report.isUsable, isTrue);
    expect(report.blockers, isEmpty);
    expect(
      report.findings,
      contains(startsWith('OK: FFE0 transport service present')),
    );
    expect(
      report.findings,
      contains(contains('FFE2 present with properties [notify]')),
    );
  });

  test('FFE2 is optional and does not affect usability', () {
    final report = validateTransportGatt(targetGatt(includeFfe2: false));

    expect(report.ffe2, isNull);
    expect(report.isUsable, isTrue);
    expect(report.findings, contains(contains('FFE2 not present')));
  });

  test('missing FFE0 is a blocker', () {
    final report = validateTransportGatt([
      service('00001800-0000-1000-8000-00805f9b34fb', [
        characteristic(ffe1CharacteristicUuid, [GattProperty.write]),
      ]),
    ]);

    expect(report.hasFfe0, isFalse);
    expect(report.isUsable, isFalse);
    expect(report.blockers, contains('FAIL: FFE0 transport service not found'));
  });

  test('missing FFE1 is a blocker', () {
    final report = validateTransportGatt([
      service(ffe0ServiceUuid, [
        characteristic(ffe2CharacteristicUuid, [GattProperty.notify]),
      ]),
    ]);

    expect(report.hasFfe1, isFalse);
    expect(report.isUsable, isFalse);
    expect(
      report.blockers,
      contains('FAIL: FFE1 transport characteristic not found'),
    );
  });

  test('FFE1 without a write property is a blocker', () {
    final report = validateTransportGatt([
      service(ffe0ServiceUuid, [
        characteristic(ffe1CharacteristicUuid, [
          GattProperty.read,
          GattProperty.notify,
        ]),
      ]),
    ]);

    expect(report.ffe1Writable, isFalse);
    expect(report.isUsable, isFalse);
    expect(
      report.blockers,
      contains(
        'FAIL: FFE1 has neither write nor writeWithoutResponse '
        '(properties: read, notify)',
      ),
    );
  });

  test('writeWithoutResponse alone satisfies writability', () {
    final report = validateTransportGatt([
      service(ffe0ServiceUuid, [
        characteristic(
          ffe1CharacteristicUuid,
          [GattProperty.writeWithoutResponse],
        ),
      ]),
    ]);

    expect(report.isUsable, isTrue);
  });

  test('accepts short and uppercase UUIDs', () {
    final report = validateTransportGatt([
      service('FFE0', [
        characteristic('FFE1', [GattProperty.write]),
      ]),
    ]);

    expect(report.hasFfe0, isTrue);
    expect(report.hasFfe1, isTrue);
    expect(report.isUsable, isTrue);
  });

  test('unknown services and characteristics are tolerated', () {
    final report = validateTransportGatt([
      service('00001800-0000-1000-8000-00805f9b34fb', [
        characteristic('00002a00-0000-1000-8000-00805f9b34fb', [
          GattProperty.read,
        ]),
      ]),
      ...targetGatt(),
    ]);

    expect(report.isUsable, isTrue);
    expect(report.blockers, isEmpty);
  });

  test('empty GATT discovery is not usable', () {
    final report = validateTransportGatt(const []);

    expect(report.isUsable, isFalse);
    expect(report.blockers, isNotEmpty);
  });

  test('uuidMatches is case-insensitive and compares the full UUID', () {
    expect(uuidMatches(ffe0ServiceUuid.toUpperCase(), ffe0ServiceUuid), isTrue);
    expect(uuidMatches(' ffe0 ', ffe0ServiceUuid), isTrue);
    expect(uuidMatches(ffe1CharacteristicUuid, ffe0ServiceUuid), isFalse);
    expect(uuidMatches('ffe', ffe0ServiceUuid), isFalse);
  });
}
