/// Deterministic paraphrase normalization for the command parsers.
///
/// Speech is not typed: people say "could you switch the lighting on", "I want
/// the lights enabled", "let's get the lights working". The Stage 1 grammar is
/// intentionally a closed, reviewed vocabulary, so instead of loosening the
/// safety rules this layer rewrites a *small, explicit* set of everyday
/// phrasings into the canonical forms the parser already validates.
///
/// Rules:
/// * politeness/request prefixes are dropped (`could you`, `I want`, `let's`);
/// * a short phrase table rewrites idiomatic power requests;
/// * a word table rewrites common synonyms (`lighting` → `lights`,
///   `enabled` → `on`, `enable` → `turn on`).
///
/// Every mapping is literal — there is no fuzzy matching, stemming or scoring.
/// The result is still fed through the unchanged parser, so negation,
/// questions, the registry allowlist, parameter validation and ambiguity keep
/// deciding the outcome. Nothing here can turn an unrelated sentence into a
/// command: an unmapped sentence is returned exactly as it arrived.
library;

/// Prefixes that only express politeness or desire, never an action.
///
/// Longest first: a two-word prefix must win over its one-word suffix
/// (`i want to` before `i want`).
const List<List<String>> _requestPrefixes = [
  ['i', 'just', 'want', 'to'],
  ['i', 'would', 'like', 'to'],
  ['i', 'would', 'like'],
  ['id', 'like', 'to'],
  ['id', 'like'],
  ['i', 'want', 'to'],
  ['i', 'want'],
  ['i', 'need', 'to'],
  ['i', 'need'],
  ['could', 'you', 'please'],
  ['could', 'you'],
  ['can', 'you', 'please'],
  ['can', 'you'],
  ['would', 'you', 'please'],
  ['would', 'you'],
  ['will', 'you', 'please'],
  ['will', 'you'],
  ['help', 'me', 'to'],
  ['help', 'me'],
  ['lets', 'get'],
  ['let', 'us', 'get'],
  ['lets'],
  ['let', 'us'],
  ['please'],
];

/// Idiomatic phrases rewritten into canonical imperative forms.
const List<(List<String>, List<String>)> _phrases = [
  (
    ['get', 'the', 'lights', 'working'],
    ['turn', 'the', 'lights', 'on'],
  ),
  (
    ['get', 'the', 'leds', 'working'],
    ['turn', 'the', 'leds', 'on'],
  ),
  (
    ['get', 'the', 'lighting', 'working'],
    ['turn', 'the', 'lights', 'on'],
  ),
  (
    ['make', 'the', 'lights', 'work'],
    ['turn', 'the', 'lights', 'on'],
  ),
  (
    ['make', 'the', 'leds', 'work'],
    ['turn', 'the', 'leds', 'on'],
  ),
  (
    ['get', 'the', 'lights', 'going'],
    ['turn', 'the', 'lights', 'on'],
  ),
  (['power', 'up'], ['turn', 'on']),
  (['power', 'down'], ['turn', 'off']),
  (['switch', 'on'], ['turn', 'on']),
  (['switch', 'off'], ['turn', 'off']),
];

/// Single-word synonyms. A value may expand to more than one token.
const Map<String, List<String>> _wordAliases = {
  'lighting': ['lights'],
  'illumination': ['lights'],
  'enabled': ['on'],
  'disabled': ['off'],
  'enable': ['turn', 'on'],
  'disable': ['turn', 'off'],
  // "let's get the lights working" loses its "get" to the prefix table, so
  // the remainder ("the lights working") must still reach the terse power
  // grammar. "working" never carries another LED meaning here.
  'working': ['on'],
};

/// Rewrites a normalized token list into the parser's canonical vocabulary.
///
/// Returns a new list; [tokens] is never modified. A sentence without a known
/// paraphrase is returned unchanged (same order, same length).
List<String> normalizeParaphrases(List<String> tokens) {
  if (tokens.isEmpty) return const [];

  var work = _stripRequestPrefixes(tokens);
  if (work.isEmpty) return work;

  // Phrase and word rewrites can expose another phrase at the same position
  // ("let's get the lights working" → prefix strip → phrase table). Repeat a
  // bounded number of times instead of guessing a full fixpoint.
  for (var pass = 0; pass < 3; pass++) {
    final next = _applyWordAliases(_applyPhrases(work));
    final stable = _sameTokens(work, next);
    work = next;
    if (stable) break;
  }
  return _stripRequestPrefixes(work);
}

List<String> _stripRequestPrefixes(List<String> tokens) {
  var result = tokens;
  var changed = true;
  while (changed) {
    changed = false;
    for (final prefix in _requestPrefixes) {
      if (prefix.length >= result.length) continue;
      if (_matchesAt(result, prefix, 0)) {
        result = result.sublist(prefix.length);
        changed = true;
        break;
      }
    }
  }
  return result;
}

List<String> _applyPhrases(List<String> tokens) {
  final out = <String>[];
  var i = 0;
  while (i < tokens.length) {
    var matched = false;
    for (final (phrase, replacement) in _phrases) {
      if (_matchesAt(tokens, phrase, i)) {
        out.addAll(replacement);
        i += phrase.length;
        matched = true;
        break;
      }
    }
    if (!matched) {
      out.add(tokens[i]);
      i++;
    }
  }
  return out;
}

List<String> _applyWordAliases(List<String> tokens) {
  final out = <String>[];
  for (final token in tokens) {
    out.addAll(_wordAliases[token] ?? [token]);
  }
  return out;
}

bool _matchesAt(List<String> tokens, List<String> pattern, int start) {
  if (start + pattern.length > tokens.length) return false;
  for (var offset = 0; offset < pattern.length; offset++) {
    if (tokens[start + offset] != pattern[offset]) return false;
  }
  return true;
}

bool _sameTokens(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
