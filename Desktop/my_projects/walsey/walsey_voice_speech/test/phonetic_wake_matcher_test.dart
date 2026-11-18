import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// The wake matcher is a *transcript-side gate*, not an acoustic detector and
/// not a command parser. These tests pin both halves of its contract:
///
/// * the spellings the engines actually produced for the spoken word are
///   accepted (see `docs/voice_accuracy.md`);
/// * ordinary English words that engines also produced for the same audio are
///   rejected, because an always-on matcher may not fire on conversation.
///
/// A passing test here does not mean wake-word detection works: that needs the
/// streaming detector and a benchmark with negative audio.
void main() {
  const matcher = PhoneticWakeMatcher();

  group('canonical spellings', () {
    for (final form in PhoneticWakeMatcher.canonicalForms) {
      test('accepts "$form"', () {
        final match = matcher.findInText(form);
        expect(match, isNotNull);
        expect(match!.editDistance, 0);
        expect(match.isVariant, isFalse);
      });
    }
  });

  group('engine variants', () {
    for (final form in PhoneticWakeMatcher.engineVariants) {
      test('accepts "$form" as a known variant', () {
        final match = matcher.findInText(form);
        expect(match, isNotNull);
        expect(match!.isVariant, isTrue);
      });
    }

    test('variants can be turned off explicitly', () {
      const strict = PhoneticWakeMatcher(allowEngineVariants: false);
      expect(strict.findInText('volsity'), isNull);
    });
  });

  group('one-edit tolerance', () {
    test('accepts a single substitution', () {
      // "walsea" is in the variant list; use a spelling that is not.
      expect(matcher.findInText('walset'), isNotNull);
    });

    test('accepts a single insertion', () {
      expect(matcher.findInText('walseyy'), isNotNull);
    });

    test('accepts a single deletion', () {
      expect(matcher.findInText('walse'), isNotNull);
    });

    test('rejects two edits', () {
      expect(matcher.findInText('walsett'), isNull);
    });

    test('distance tolerance can be disabled', () {
      const strict = PhoneticWakeMatcher(maxEditDistance: 0);
      expect(strict.findInText('walset'), isNull);
      expect(strict.findInText('walsey'), isNotNull);
    });
  });

  group('common-word rejections', () {
    for (final word in [
      'well',
      'see',
      'say',
      'city',
      'while',
      'she',
      'will',
      'wall',
      'will see',
      'well say',
      'while she',
      'I will say it',
      'the city lights',
      'well see you later',
      'falsey',
      'palsy',
      'daisy',
    ]) {
      test('does not trigger on "$word"', () {
        expect(matcher.findInText(word), isNull);
      });
    }

    test('explicit exclusion set is not overridden by a close spelling', () {
      // "will" is one edit from "wall" which is also excluded; the exclusion
      // check happens before any distance comparison.
      expect(matcher.findInText('will'), isNull);
      expect(matcher.findInText('wall'), isNull);
    });
  });

  group('phrase position and remainder', () {
    test('finds the phrase at the start and returns the command', () {
      final match = matcher.findInWords(
        PhoneticWakeMatcher.splitWords('Walsey turn the lights on'),
      );
      expect(match, isNotNull);
      expect(match!.startWord, 0);
      expect(match.endWord, 1);
      expect(match.matchedText, 'walsey');
      expect(
        matcher.commandAfterText('Walsey turn the lights on'),
        'turn the lights on',
      );
    });

    test('includes a leading hey and keeps the command intact', () {
      final match = matcher.findInWords(
        PhoneticWakeMatcher.splitWords('Hey Walsey, set brightness to 60%'),
      );
      expect(match, isNotNull);
      expect(match!.startWord, 0);
      expect(match.endWord, 2);
      expect(match.matchedText, 'hey walsey');
      expect(
        matcher.commandAfterText('Hey Walsey, set brightness to 60%'),
        'set brightness to 60',
      );
    });

    test('okay is accepted as a leading filler', () {
      expect(matcher.findInText('Okay Walsey make it blue'), isNotNull);
    });

    test('an unrelated leading word is not swallowed', () {
      final match = matcher.findInWords(
        PhoneticWakeMatcher.splitWords('please Walsey turn it on'),
      );
      expect(match, isNotNull);
      expect(match!.startWord, 1);
      expect(match.matchedText, 'walsey');
    });

    test('wake phrase alone yields an empty remainder', () {
      expect(matcher.commandAfterText('Walsey'), '');
    });

    test('no wake phrase yields null, never an empty command', () {
      expect(matcher.commandAfterText('turn the lights on'), isNull);
    });

    test('stops at the first trigger only', () {
      final match = matcher.findInWords(
        PhoneticWakeMatcher.splitWords('walsey turn on walsey lights'),
      );
      expect(match!.startWord, 0);
      expect(match.endWord, 1);
    });
  });

  group('splitWords', () {
    test('lower-cases and strips punctuation', () {
      expect(
        PhoneticWakeMatcher.splitWords('WALSEY, turn the lights ON!'),
        ['walsey', 'turn', 'the', 'lights', 'on'],
      );
    });

    test('drops possessives and apostrophes', () {
      expect(PhoneticWakeMatcher.splitWords("Walsey's lights"), [
        'walsey',
        'lights',
      ]);
      expect(PhoneticWakeMatcher.splitWords("don't"), ['dont']);
    });

    test('keeps digits so the command remainder is not damaged', () {
      expect(
        PhoneticWakeMatcher.splitWords('Walsey set brightness to 60 percent!'),
        ['walsey', 'set', 'brightness', 'to', '60', 'percent'],
      );
      expect(
        matcher.commandAfterText('Walsey set brightness to 60 percent!'),
        'set brightness to 60 percent',
      );
    });

    test('empty text has no words', () {
      expect(PhoneticWakeMatcher.splitWords('   '), isEmpty);
    });
  });
}
