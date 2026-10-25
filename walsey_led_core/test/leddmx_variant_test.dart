import 'package:test/test.dart';
import 'package:walsey_led_core/walsey_led_core.dart';

void main() {
  LeddmxLayout layoutOf(String name) {
    final r = resolveVariant(name);
    expect(r, isA<SupportedVariant>(), reason: name);
    return (r as SupportedVariant).layout;
  }

  test('00, 01, 03 use the filler layout', () {
    expect(layoutOf('LEDDMX-00'), LeddmxLayout.filler);
    expect(layoutOf('LEDDMX-01'), LeddmxLayout.filler);
    expect(layoutOf('LEDDMX-03'), LeddmxLayout.filler);
  });

  test('02, 04 use the shifted layout', () {
    expect(layoutOf('LEDDMX-02'), LeddmxLayout.shifted);
    expect(layoutOf('LEDDMX-04'), LeddmxLayout.shifted);
  });

  test('suffix and case are tolerated', () {
    expect(layoutOf('LEDDMX-03-1A2B'), LeddmxLayout.filler);
    expect(layoutOf('leddmx-04-ffee'), LeddmxLayout.shifted);
    expect(layoutOf('  LEDDMX-02-9B67 '), LeddmxLayout.shifted);
  });

  group('refuses to guess', () {
    for (final name in [
      'LED DMX', // the vendor app's label, not an advertised name
      'LEDDMX', // no variant number
      'LEDDMX-05', // undocumented
      'LEDDMX-031', // digits run on: not "03"
      'LEDBLE-00-9B67', // documented family, not implemented here
      'LEDCAR-01', // documented family, not implemented here
      'ELK-BLEDOM',
      '',
    ]) {
      test('"$name"', () {
        expect(resolveVariant(name), isA<UnsupportedVariant>());
      });
    }
    test('null name', () {
      expect(resolveVariant(null), isA<UnsupportedVariant>());
    });
  });

  group('capabilities', () {
    test('supported variant: all four capabilities are decompiled-only', () {
      final caps = resolveVariant('LEDDMX-03').capabilities;
      for (final c in Capability.values) {
        expect(caps.of(c).isSupported, isTrue);
        expect(caps.of(c).evidence, Evidence.decompiledApp);
      }
    });

    test('unsupported variant: nothing supported, each carries a reason', () {
      final caps = resolveVariant('LED DMX').capabilities;
      for (final c in Capability.values) {
        expect(caps.of(c).isSupported, isFalse);
        expect(caps.of(c).unsupportedReason, isNotEmpty);
      }
    });
  });
}
