/// One normalized sentence and the tokens the parser works on.
///
/// Kept separate from the parser so normalization has a single, testable job.
final class NormalizedText {
  const NormalizedText({
    required this.original,
    required this.text,
    required this.tokens,
  });

  /// The user's text, untouched.
  final String original;

  /// Lowercase, punctuation-free, whitespace-collapsed text.
  final String text;

  /// [text] split into meaningful tokens.
  final List<String> tokens;

  bool get isEmpty => tokens.isEmpty;
}

final _numberToken = RegExp(r'^-?\d+(?:\.\d+)?$');

/// Normalizes a sentence without changing its meaning.
///
/// Rules, in order:
/// - lowercase and trim;
/// - drop apostrophes, so `don't` becomes `dont` (used by negation detection);
/// - turn `%` into the word `percent`;
/// - split hyphens that are not part of a negative number;
/// - replace remaining symbols with spaces;
/// - collapse runs of whitespace;
/// - split tokens, keeping decimal/signed numbers intact and dropping
///   punctuation attached to words (`lights.` becomes `lights`).
NormalizedText normalizeCommandText(String input) {
  var text = input.toLowerCase().trim();
  text = text.replaceAll(RegExp("['\u2019]"), '');
  text = text.replaceAll('%', ' percent ');
  text = text.replaceAll(RegExp(r'-(?!\d)'), ' ');
  text = text.replaceAll(RegExp(r'[^a-z0-9.\s-]'), ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

  final tokens = <String>[];
  if (text.isNotEmpty) {
    for (final raw in text.split(' ')) {
      if (_numberToken.hasMatch(raw)) {
        tokens.add(raw);
        continue;
      }
      for (final part in raw.split(RegExp(r'[.\-]'))) {
        if (part.isNotEmpty) tokens.add(part);
      }
    }
  }

  return NormalizedText(
    original: input,
    text: tokens.join(' '),
    tokens: List.unmodifiable(tokens),
  );
}
