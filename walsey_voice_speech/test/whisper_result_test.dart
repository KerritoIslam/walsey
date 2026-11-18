import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// The transcript assembler is the only code allowed to touch what Whisper
/// heard. These tests pin the exact contract: join, trim, collapse — and
/// nothing else. If a transcription error and a parser error are to stay
/// visibly separate, the text must pass through verbatim.
void main() {
  group('whisperTranscriptText', () {
    test('joins segments with single spaces', () {
      expect(
        whisperTranscriptText(['Turn the', 'lights on.']),
        'Turn the lights on.',
      );
    });

    test('trims each segment before joining', () {
      expect(
        whisperTranscriptText(['  Turn  ', 'the lights on.  ']),
        'Turn the lights on.',
      );
    });

    test('collapses whitespace runs inside a segment', () {
      expect(
        whisperTranscriptText(['set   brightness\n to\tfifty']),
        'set brightness to fifty',
      );
    });

    test('drops empty and whitespace-only segments', () {
      expect(
        whisperTranscriptText(['', '   ', 'Turn the lights on.', '']),
        'Turn the lights on.',
      );
    });

    test('keeps punctuation and capitalisation verbatim', () {
      expect(
        whisperTranscriptText(['"Change the color to BLUE," he said.']),
        '"Change the color to BLUE," he said.',
      );
    });

    test('a whisper hallucination artefact is preserved, not corrected', () {
      // whisper.cpp sometimes appends trailing filler like " Thanks for
      // watching!" on silence. The assembler must not second-guess it: the
      // parser rejects such text and that outcome is the honest one.
      expect(
        whisperTranscriptText(['Turn the lights on.', 'Thanks for watching!']),
        'Turn the lights on. Thanks for watching!',
      );
    });

    test('no segments at all is no transcript', () {
      expect(whisperTranscriptText(const []), isNull);
    });

    test('only empty segments is no transcript', () {
      expect(whisperTranscriptText(['', '   ']), isNull);
    });
  });
}
