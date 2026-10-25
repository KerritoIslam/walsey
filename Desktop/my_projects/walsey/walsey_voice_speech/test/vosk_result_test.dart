import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

void main() {
  group('voskTranscriptText', () {
    test('reads the text field of a result', () {
      expect(
        voskTranscriptText('{"text": "set brightness to fifty percent"}'),
        'set brightness to fifty percent',
      );
    });

    test('reads the partial field of a partial hypothesis', () {
      expect(voskTranscriptText('{"partial": "set bright"}'), 'set bright');
    });

    test('trims surrounding whitespace', () {
      expect(
        voskTranscriptText('{"text": "  turn the lights on  "}'),
        'turn the lights on',
      );
    });

    test('treats empty and missing text as no text', () {
      expect(voskTranscriptText('{"text": ""}'), isNull);
      expect(voskTranscriptText('{"text": "   "}'), isNull);
      expect(voskTranscriptText('{}'), isNull);
      expect(voskTranscriptText(''), isNull);
    });

    test('ignores malformed JSON instead of throwing', () {
      expect(voskTranscriptText('not json at all'), isNull);
      expect(voskTranscriptText('{"text": '), isNull);
      expect(voskTranscriptText('[]'), isNull);
      expect(voskTranscriptText('"just a string"'), isNull);
    });

    test('ignores non-string fields', () {
      expect(voskTranscriptText('{"text": 42}'), isNull);
      expect(voskTranscriptText('{"partial": null}'), isNull);
    });

    test('reads a word-level result with both text and result entries', () {
      const json =
          '{"result":[{"conf":0.9,"start":0.1,"end":0.4,"word":"set"}],'
          '"text":"set"}';
      expect(voskTranscriptText(json), 'set');
    });
  });
}
