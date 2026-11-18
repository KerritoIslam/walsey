/// Conservative text-side wake-phrase matcher.
///
/// The exclusive purpose of this class is to decide whether a *transcript* (or
/// a stream of transcript words) contains the trigger phrase "Walsey". It never
/// starts, stops or interprets a command and it never talks to the parser.
///
/// Why a conservative allow-list instead of fuzzy string matching alone:
///
/// * The phrase is invented, so every engine spells it differently. The
///   accepted forms below are the ones actually observed in the project's
///   measurements (`docs/voice_accuracy.md`): Whisper wrote "Volsity",
///   "Vulsati", "Walsi", Vosk wrote "well see", "city", "well said he".
/// * Common English words must never trigger the assistant. In particular
///   "well see", "well say", "will say", "while she" and "city" are excluded on
///   purpose even though engines emit them for the spoken wake phrase: as a
///   standalone detector they would fire during ordinary conversation.
///   A real always-on detector needs an acoustic model trained for this phrase;
///   this matcher is only the transcript-side gate used by the benchmark
///   harness and any future spotter.
library;

/// Position and quality of a wake phrase inside a word list.
final class WakePhraseMatch {
  const WakePhraseMatch({
    required this.startWord,
    required this.endWord,
    required this.matchedText,
    required this.editDistance,
    required this.isVariant,
  });

  /// Index of the first phrase word (may be a leading "hey"/"ok").
  final int startWord;

  /// Index *after* the last phrase word, so `words.sublist(endWord)` is the
  /// remaining command.
  final int endWord;

  /// The words that matched, joined with single spaces.
  final String matchedText;

  /// 0 for an accepted canonical spelling, >0 for an edit-distance match.
  final int editDistance;

  /// True when only the observed-engine variant list accepted the token.
  final bool isVariant;

  @override
  String toString() =>
      'WakePhraseMatch("$matchedText", words $startWord..$endWord, '
      'distance=$editDistance, variant=$isVariant)';
}

/// Finds "Walsey" (and "hey/ok/okay Walsey") without guessing.
final class PhoneticWakeMatcher {
  const PhoneticWakeMatcher({
    this.maxEditDistance = 1,
    this.allowEngineVariants = true,
  });

  /// Maximum Levenshtein distance against a canonical spelling.
  ///
  /// One substitution/insertion/deletion is tolerated ("walsea" for the spoken
  /// word). Two or more starts to hit unrelated words, so it stays at 1.
  final int maxEditDistance;

  /// Whether the variant spellings actually observed from Whisper/Vosk are
  /// accepted. They are exact spellings, not fuzzy matches.
  final bool allowEngineVariants;

  /// Canonical spellings of the invented word.
  static const canonicalForms = <String>[
    'walsey',
    'walsy',
    'wolsey',
    'wallsey',
    'waltsey',
    'walsee',
    'walsi',
    'walzi',
    'walsie',
    'wolsy',
  ];

  /// Spellings observed from Whisper on this project's recordings.
  static const engineVariants = <String>[
    'volsity',
    'vulsati',
    'valsay',
    'walsay',
    'walzey',
    'walsea',
  ];

  /// Deliberately NOT accepted (common words/engine artefacts):
  /// `well`, `see`, `say`, `city`, `while`, `she`, `will`, `wall`.
  static const excludedWords = <String>{
    'well',
    'see',
    'say',
    'city',
    'while',
    'she',
    'will',
    'wall',
  };

  static const _leadingFillers = <String>{'hey', 'ok', 'okay', 'hay'};

  /// Scans [words] left to right and returns the first trigger.
  WakePhraseMatch? findInWords(List<String> words) {
    for (var i = 0; i < words.length; i++) {
      final token = normalizeToken(words[i]);
      if (token.isEmpty) continue;
      final strength = _matchToken(token);
      if (strength == null) continue;

      var start = i;
      if (i > 0 && _leadingFillers.contains(normalizeToken(words[i - 1]))) {
        start = i - 1;
      }
      return WakePhraseMatch(
        startWord: start,
        endWord: i + 1,
        matchedText: [
          for (var w = start; w <= i; w++) normalizeToken(words[w]),
        ].join(' '),
        editDistance: strength.distance,
        isVariant: strength.variant,
      );
    }
    return null;
  }

  /// Splits [text] the same way the transcript assembler does (on anything
  /// that is not a letter or an apostrophe) and scans it.
  WakePhraseMatch? findInText(String text) => findInWords(splitWords(text));

  /// The words after the trigger, or `null` when there is no trigger.
  ///
  /// The caller decides what to do with the remainder; nothing is executed
  /// here. Returns an empty string when the wake phrase is the whole sentence.
  String? commandAfterText(String text) {
    final words = splitWords(text);
    final match = findInWords(words);
    if (match == null) return null;
    return words.sublist(match.endWord).join(' ');
  }

  /// Lower-cases and strips punctuation/possessives from one token.
  ///
  /// Letters **and digits** are kept: callers reuse [splitWords] to build the
  /// command remainder, and dropping digits would silently turn
  /// "set brightness to 60 percent" into "set brightness to  percent".
  static String normalizeToken(String raw) {
    var token = raw.toLowerCase();
    token = token.replaceAll(RegExp(r"[^a-z0-9']"), '');
    if (token.endsWith("'s")) {
      token = token.substring(0, token.length - 2);
    }
    return token.replaceAll("'", '');
  }

  /// Words in [text], punctuation removed, empty tokens dropped.
  static List<String> splitWords(String text) => text
      .split(RegExp(r"[^A-Za-z0-9']+"))
      .map(normalizeToken)
      .where((word) => word.isNotEmpty)
      .toList(growable: false);

  _TokenStrength? _matchToken(String token) {
    if (excludedWords.contains(token)) return null;
    if (canonicalForms.contains(token)) {
      return const _TokenStrength(0, variant: false);
    }
    if (allowEngineVariants && engineVariants.contains(token)) {
      return const _TokenStrength(0, variant: true);
    }
    final maxDistance = maxEditDistance;
    if (maxDistance <= 0 || token.length < 4) return null;
    // The invented word always starts with a /w/ sound. Engines substitute
    // /v/ for it ("Volsity"), which the variant list already covers, so a
    // fuzzy match may only start with w or v. Without this guard a single
    // edit would turn unrelated words into a trigger ("falsey" → "walsey").
    if (token[0] != 'w' && token[0] != 'v') return null;
    for (final form in canonicalForms) {
      // Only compare words of similar length so one edit cannot turn a short
      // unrelated word into a match.
      if ((token.length - form.length).abs() > maxDistance) continue;
      final distance = _levenshtein(token, form);
      if (distance <= maxDistance) {
        return _TokenStrength(distance, variant: false);
      }
    }
    return null;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);
    for (var i = 0; i < a.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final substitution = previous[j] + (a[i] == b[j] ? 0 : 1);
        final insertion = current[j] + 1;
        final deletion = previous[j + 1] + 1;
        current[j + 1] = substitution < insertion
            ? (substitution < deletion ? substitution : deletion)
            : (insertion < deletion ? insertion : deletion);
      }
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[b.length];
  }
}

final class _TokenStrength {
  const _TokenStrength(this.distance, {required this.variant});

  final int distance;
  final bool variant;
}
