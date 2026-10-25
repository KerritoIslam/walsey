import 'package:test/test.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';

void main() {
  group('normalizeCommandText', () {
    test('lowercases, trims and collapses repeated whitespace', () {
      final result = normalizeCommandText('  TURN   the   LIGHTS    ON  ');
      expect(result.text, 'turn the lights on');
      expect(result.tokens, ['turn', 'the', 'lights', 'on']);
    });

    test('keeps the untouched original for display', () {
      final result = normalizeCommandText('  Turn the lights ON!  ');
      expect(result.original, '  Turn the lights ON!  ');
    });

    test('drops punctuation attached to words', () {
      expect(
        normalizeCommandText('Walsey, turn the lights on.').tokens,
        ['walsey', 'turn', 'the', 'lights', 'on'],
      );
    });

    test('removes apostrophes so contractions stay one token', () {
      expect(normalizeCommandText("Don't").tokens, ['dont']);
    });

    test('turns a percent sign into the word percent', () {
      final result = normalizeCommandText('brightness 50%');
      expect(result.tokens, ['brightness', '50', 'percent']);
      expect(result.text, 'brightness 50 percent');
    });

    test('keeps decimal and negative numbers as single tokens', () {
      expect(
          normalizeCommandText('brightness -5').tokens, ['brightness', '-5']);
      expect(
        normalizeCommandText('brightness 50.5').tokens,
        ['brightness', '50.5'],
      );
    });

    test('splits non-numeric hyphens but not a negative sign', () {
      expect(
          normalizeCommandText('led-strip -5').tokens, ['led', 'strip', '-5']);
    });

    test('a punctuation-only input has no tokens', () {
      expect(normalizeCommandText('!!! ???').isEmpty, isTrue);
      expect(normalizeCommandText('   ').isEmpty, isTrue);
    });
  });
}
