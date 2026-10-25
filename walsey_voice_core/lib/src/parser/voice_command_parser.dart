import '../domain/errors.dart';
import '../domain/voice_intent.dart';
import '../domain/voice_parameters.dart';
import '../domain/voice_result.dart';
import '../registry/command_registry.dart';
import 'normalization.dart';

/// Deterministic, offline text-to-command parser.
///
/// It knows one domain (LED control), emits only [VoiceIntent] values that are
/// registered in [CommandRegistry], and never executes anything. Speech
/// recognition (Stage 2) can feed it a transcript; an executor (Stage 3) can
/// consume its results — neither changes this class.
final class VoiceCommandParser {
  VoiceCommandParser({CommandRegistry? registry})
      : _registry = registry ?? CommandRegistry.ledDefaults();

  final CommandRegistry _registry;

  /// The allowlist this parser authorizes against.
  CommandRegistry get registry => _registry;

  /// Analyzes [input] and returns a validated command or an explicit failure.
  VoiceResult parse(String input) {
    final normalized = normalizeCommandText(input);
    if (normalized.isEmpty) {
      return _failure(
        input,
        VoiceFailureKind.emptyInput,
        'Enter a command sentence, for example "turn the lights on".',
      );
    }

    final tokens = _stripWakeWord(normalized.tokens);
    if (tokens.isEmpty) {
      return _failure(
        input,
        VoiceFailureKind.unsupported,
        'Only the wake word was said. Add a command, for example '
        '"turn the lights on".',
      );
    }

    if (_anyOf(_negations, tokens)) {
      return _failure(
        input,
        VoiceFailureKind.unsupported,
        'Negated or hypothetical requests are not turned into actions. '
        'Nothing was executed.',
      );
    }

    if (_anyOf(_questionWords, tokens)) {
      return _failure(
        input,
        VoiceFailureKind.unsupported,
        'That looks like a question or an information request, not an LED '
        'command. Nothing was executed.',
      );
    }

    if (_anyOf(_unregisteredActions, tokens)) {
      return _failure(
        input,
        VoiceFailureKind.unsupported,
        'That action belongs to a domain that is not registered in Stage 1. '
        'Only LED commands can be analyzed; nothing was executed.',
      );
    }

    final hasLight = _anyOf(_lightNouns, tokens);
    if (!hasLight && _anyOf(_otherDevices, tokens)) {
      return _failure(
        input,
        VoiceFailureKind.unsupported,
        'Walsey Stage 1 only understands LED commands. Other devices and '
        'system actions are not registered; nothing was executed.',
      );
    }

    final numbers = _numbersWithoutDurations(tokens, _numbers(tokens));
    final colors = <VoiceColor>[];
    for (final token in tokens) {
      final color = VoiceColor.fromWord(token);
      if (color != null && !colors.contains(color)) colors.add(color);
    }

    final hasOn = tokens.contains('on');
    final hasOff = tokens.contains('off');
    final hasBrightnessNoun = _anyOf(_brightnessNouns, tokens);
    final hasEffectNoun = _anyOf(_effectNouns, tokens);
    final hasColorNoun = _anyOf(_colorNouns, tokens);
    final hasSettingVerb = _anyOf(_settingVerbs, tokens);
    final hasPowerVerb = _anyOf(_powerVerbs, tokens);
    final hasPercent = tokens.contains('percent');

    final ambiguities = <String>[];
    final candidates = <VoiceIntent>{};

    // Power: an imperative verb, or the terse "lights on" form. Statements
    // such as "the lights are on" are not commands.
    if (hasLight &&
        (hasOn || hasOff) &&
        (hasPowerVerb || _isTersePower(tokens, hasOn: hasOn, hasOff: hasOff))) {
      if (hasOn && hasOff) {
        ambiguities.add('it asks for both "on" and "off"');
      } else {
        candidates.add(hasOn ? VoiceIntent.powerOn : VoiceIntent.powerOff);
      }
    }

    // Relative brightness: only with a light/brightness subject.
    if (hasLight || hasBrightnessNoun) {
      if (_anyOf(_increaseWords, tokens)) {
        candidates.add(VoiceIntent.increaseBrightness);
      }
      if (_anyOf(_decreaseWords, tokens)) {
        candidates.add(VoiceIntent.decreaseBrightness);
      }
    }

    // Effect: a specific id is required. "next"/"previous" is refused earlier.
    if (hasEffectNoun && _anyOf(_relativeEffectWords, tokens)) {
      return _failure(
        input,
        VoiceFailureKind.unsupported,
        'Relative effect selection ("next", "previous", "random") cannot be '
        'resolved reliably: the controller protocol has no effect-state '
        'read-back. Ask for a specific effect id instead (1..210 or 255).',
        intent: VoiceIntent.applyEffect,
      );
    }
    if (hasEffectNoun && (hasSettingVerb || hasLight || numbers.isNotEmpty)) {
      candidates.add(VoiceIntent.applyEffect);
    }

    // Absolute brightness: a number plus a brightness/light/percent context.
    final brightnessContext = hasBrightnessNoun ||
        (hasLight && hasPercent) ||
        (hasLight && hasSettingVerb);
    if (brightnessContext && numbers.isNotEmpty) {
      candidates.add(VoiceIntent.setBrightness);
    }

    // Colour: a recognized name in a command-shaped sentence.
    final colorContext =
        colors.isNotEmpty && (hasColorNoun || (hasLight && hasSettingVerb));
    if (colorContext) {
      if (colors.length > 1) {
        ambiguities.add('it mentions more than one colour '
            '(${colors.map((c) => c.label).join(', ')})');
      } else {
        candidates.add(VoiceIntent.setColor);
      }
    }

    if (ambiguities.isNotEmpty) {
      return _failure(
        input,
        VoiceFailureKind.ambiguous,
        'The requested action could not be determined reliably: '
        '${ambiguities.join('; ')}. Nothing was executed.',
      );
    }

    if (candidates.length > 1) {
      final names = candidates.map((intent) => intent.label).join(', ');
      return _failure(
        input,
        VoiceFailureKind.ambiguous,
        'The sentence contains more than one action ($names). Stage 1 '
        'analyzes one command at a time. Nothing was executed.',
      );
    }

    if (candidates.isEmpty) {
      return _noCandidate(input, tokens, numbers,
          hasColorNoun: hasColorNoun,
          hasBrightnessNoun: hasBrightnessNoun,
          hasEffectNoun: hasEffectNoun,
          hasLight: hasLight,
          hasSettingVerb: hasSettingVerb,
          hasOn: hasOn,
          hasOff: hasOff);
    }

    final intent = candidates.single;
    final action = _registry.lookup(intent);
    if (action == null) {
      return _failure(
        input,
        VoiceFailureKind.unsupported,
        'The action "${intent.label}" is not in this command registry, so it '
        'cannot be authorized. Nothing was executed.',
        intent: intent,
      );
    }

    return switch (intent) {
      VoiceIntent.powerOn ||
      VoiceIntent.powerOff ||
      VoiceIntent.increaseBrightness ||
      VoiceIntent.decreaseBrightness =>
        _command(input, tokens, intent, const NoParameters()),
      VoiceIntent.setColor => _buildColor(input, tokens, colors),
      VoiceIntent.setBrightness => _buildBrightness(input, tokens, numbers),
      VoiceIntent.applyEffect => _buildEffect(input, tokens, numbers),
    };
  }

  VoiceResult _noCandidate(
    String input,
    List<String> tokens,
    List<_NumberRef> numbers, {
    required bool hasColorNoun,
    required bool hasBrightnessNoun,
    required bool hasEffectNoun,
    required bool hasLight,
    required bool hasSettingVerb,
    required bool hasOn,
    required bool hasOff,
  }) {
    final brightnessShape = hasBrightnessNoun ||
        (hasLight && _anyOf(_brightnessNouns, tokens)) ||
        (hasLight && _anyOf(_increaseWords, tokens)) ||
        (hasLight && _anyOf(_decreaseWords, tokens));

    if (hasColorNoun) {
      final unknown = _firstMeaningfulAfter(tokens, _colorNouns, _colorSkip);
      if (unknown != null) {
        return _failure(
          input,
          VoiceFailureKind.invalidParameter,
          'The colour "$unknown" is not in the controlled list. Supported '
          'colours: ${VoiceColor.values.map((c) => c.label).join(', ')}. '
          'Nothing was executed.',
          intent: VoiceIntent.setColor,
        );
      }
      return _failure(
        input,
        VoiceFailureKind.missingParameter,
        'A colour is required. Supported colours: '
        '${VoiceColor.values.map((c) => c.label).join(', ')}.',
        intent: VoiceIntent.setColor,
      );
    }

    if (hasBrightnessNoun) {
      final unknown = _firstMeaningfulAfter(
        tokens,
        _brightnessNouns,
        _brightnessSkip,
      );
      if (unknown != null && _wordNumber(unknown) == null) {
        return _failure(
          input,
          VoiceFailureKind.invalidParameter,
          'Brightness must be a whole number from 0 to 100 percent, not '
          '"$unknown". Nothing was executed.',
          intent: VoiceIntent.setBrightness,
        );
      }
      return _failure(
        input,
        VoiceFailureKind.missingParameter,
        'Brightness needs a value between 0 and 100 percent.',
        intent: VoiceIntent.setBrightness,
      );
    }

    if (hasEffectNoun) {
      return _failure(
        input,
        VoiceFailureKind.missingParameter,
        'An effect id is required (1..210 or 255). The existing controller '
        'API exposes effect numbers, not effect names.',
        intent: VoiceIntent.applyEffect,
      );
    }

    // A setting verb + light with no other signal could be an unknown colour.
    if (hasLight &&
        hasSettingVerb &&
        !hasOn &&
        !hasOff &&
        numbers.isEmpty &&
        !brightnessShape) {
      final unknown = _unknownWordAfterLight(tokens);
      if (unknown != null) {
        return _failure(
          input,
          VoiceFailureKind.invalidParameter,
          'Walsey could not match "$unknown" to a controlled colour. '
          'Supported colours: '
          '${VoiceColor.values.map((c) => c.label).join(', ')}. '
          'Nothing was executed.',
          intent: VoiceIntent.setColor,
        );
      }
    }

    return _failure(
      input,
      VoiceFailureKind.unsupported,
      'Walsey does not recognize this as a supported LED command. '
      'Nothing was executed.',
    );
  }

  VoiceResult _buildColor(
      String input, List<String> tokens, List<VoiceColor> colors) {
    if (colors.length != 1) {
      return _failure(
        input,
        VoiceFailureKind.ambiguous,
        'More than one colour was mentioned. Nothing was executed.',
        intent: VoiceIntent.setColor,
      );
    }
    return _command(
      input,
      tokens,
      VoiceIntent.setColor,
      ColorParameters(colors.single),
    );
  }

  VoiceResult _buildBrightness(
    String input,
    List<String> tokens,
    List<_NumberRef> numbers,
  ) {
    var refs = _numbersNear(tokens, numbers, _brightnessValueKeywords);
    if (refs.isEmpty) refs = numbers;
    if (refs.isEmpty) {
      return _failure(
        input,
        VoiceFailureKind.missingParameter,
        'Brightness needs a value between 0 and 100 percent.',
        intent: VoiceIntent.setBrightness,
      );
    }
    if (refs.map((r) => r.value).toSet().length > 1) {
      return _failure(
        input,
        VoiceFailureKind.ambiguous,
        'The sentence contains more than one brightness value. Nothing was '
        'executed.',
        intent: VoiceIntent.setBrightness,
      );
    }
    final ref = refs.first;
    if (!ref.isWhole) {
      return _failure(
        input,
        VoiceFailureKind.invalidParameter,
        'Brightness must be a whole number from 0 to 100 percent, not '
        '${ref.value}. Nothing was executed.',
        intent: VoiceIntent.setBrightness,
      );
    }
    // Check the range before converting: a huge double must not reach `round()`.
    if (ref.value < 0 || ref.value > 100) {
      return _failure(
        input,
        VoiceFailureKind.invalidParameter,
        'Brightness must be 0..100 percent, got ${ref.value}. Nothing was '
        'executed.',
        intent: VoiceIntent.setBrightness,
      );
    }
    try {
      final brightness = VoiceBrightness(ref.whole);
      return _command(
        input,
        tokens,
        VoiceIntent.setBrightness,
        BrightnessParameters(brightness),
      );
    } on VoiceParameterException catch (error) {
      return _failure(
        input,
        VoiceFailureKind.invalidParameter,
        '${error.message}. Nothing was executed.',
        intent: VoiceIntent.setBrightness,
      );
    }
  }

  VoiceResult _buildEffect(
    String input,
    List<String> tokens,
    List<_NumberRef> numbers,
  ) {
    final refs = _numbersNear(tokens, numbers, _effectNouns);
    if (refs.isEmpty) {
      return _failure(
        input,
        VoiceFailureKind.missingParameter,
        'An effect id is required (1..210 or 255).',
        intent: VoiceIntent.applyEffect,
      );
    }
    if (refs.map((r) => r.value).toSet().length > 1) {
      return _failure(
        input,
        VoiceFailureKind.ambiguous,
        'The sentence contains more than one effect id. Nothing was executed.',
        intent: VoiceIntent.applyEffect,
      );
    }
    final ref = refs.first;
    if (!ref.isWhole) {
      return _failure(
        input,
        VoiceFailureKind.invalidParameter,
        'An effect id must be a whole number (1..210 or 255).',
        intent: VoiceIntent.applyEffect,
      );
    }
    // Check before converting: a huge double must not reach `round()`.
    if (ref.value < 1 || (ref.value > 210 && ref.value != VoiceEffect.autoId)) {
      return _failure(
        input,
        VoiceFailureKind.invalidParameter,
        'effect id ${ref.value} is not in the documented set (1..210 or 255). '
        'Nothing was executed.',
        intent: VoiceIntent.applyEffect,
      );
    }
    try {
      final effect = VoiceEffect(ref.whole);
      return _command(
        input,
        tokens,
        VoiceIntent.applyEffect,
        EffectParameters(effect),
      );
    } on VoiceParameterException catch (error) {
      return _failure(
        input,
        VoiceFailureKind.invalidParameter,
        '${error.message}. Nothing was executed.',
        intent: VoiceIntent.applyEffect,
      );
    }
  }

  VoiceResult _command(
    String input,
    List<String> tokens,
    VoiceIntent intent,
    VoiceParameters parameters,
  ) {
    return VoiceCommandResult(
      sourceText: input,
      command: VoiceCommand(
        intent: intent,
        parameters: parameters,
        sourceText: input,
        normalizedText: tokens.join(' '),
      ),
    );
  }

  VoiceFailure _failure(
    String input,
    VoiceFailureKind kind,
    String explanation, {
    VoiceIntent? intent,
  }) {
    return VoiceFailure(
      sourceText: input,
      kind: kind,
      explanation: explanation,
      intent: intent,
    );
  }
}

// ---------------------------------------------------------------------------
// Vocabulary. Kept as data so the grammar can be reviewed and extended without
// turning into a pile of substring checks.
// ---------------------------------------------------------------------------

const _lightNouns = {
  'light', 'lights', 'led', 'leds', 'lamp', 'lamps', //
  'strip', 'strips', 'neon',
};

const _greetings = {'hey', 'ok', 'okay'};

const _negations = {
  'not', 'dont', 'doesnt', 'didnt', 'never', 'wont', //
  'cannot', 'cant', 'shouldnt', 'wouldnt', 'without',
};

const _questionWords = {
  'what',
  'why',
  'who',
  'where',
  'when',
  'how',
  'which',
  'tell',
};

/// Actions from future domains. Mentioning one is refused instead of being
/// silently ignored while an LED command in the same sentence is executed.
const _unregisteredActions = {
  'open',
  'launch',
  'close',
  'mute',
  'screenshot',
  'shutdown',
  'restart',
};

const _otherDevices = {
  'tv', 'television', 'fan', 'music', 'volume', //
  'computer', 'laptop', 'phone', 'car', 'oven', 'heater',
};

const _powerVerbs = {'turn', 'switch', 'power', 'flip', 'shut'};

const _settingVerbs = {
  'turn', 'switch', 'set', 'change', 'make', 'put', 'paint', 'adjust', //
  'dial', 'activate', 'apply', 'start', 'enable', 'disable', 'power',
  'dim', 'brighten', 'darken', 'raise', 'lower', 'increase', 'decrease',
  'boost', 'reduce',
};

const _increaseWords = {
  'increase',
  'raise',
  'boost',
  'brighter',
  'brighten',
  'higher',
  'up',
};

const _decreaseWords = {
  'decrease',
  'lower',
  'reduce',
  'dim',
  'dimmer',
  'darken',
  'darker',
  'down',
};

const _brightnessNouns = {'brightness', 'bright'};

/// Keywords that anchor a brightness number. `percent` is included so
/// "50 and 60 percent" exposes both candidates instead of silently picking the
/// one nearest to `brightness`.
const _brightnessValueKeywords = {'brightness', 'bright', 'percent'};

const _colorNouns = {'color', 'colors', 'colour', 'colours'};

const _effectNouns = {'effect', 'effects'};

const _relativeEffectWords = {'next', 'previous', 'last', 'random', 'another'};

const _timeUnits = {
  'minute',
  'minutes',
  'second',
  'seconds',
  'hour',
  'hours',
  'day',
  'days',
};

const _colorSkip = {
  'to', 'the', 'a', 'an', 'be', 'is', 'should', 'my', 'our', 'for', 'me', //
  'please', 'now', 'lights', 'light', 'led', 'leds', 'lamp', 'lamps',
  'strip', 'strips', 'color', 'colors', 'colour', 'colours',
};

const _brightnessSkip = {
  'to', 'the', 'a', 'an', 'be', 'is', 'at', 'of', 'my', 'our', 'for', //
  'me', 'please', 'now', 'percent', 'lights', 'light', 'on', 'off',
};

const _numberWords = {
  'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, //
  'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9,
  'ten': 10, 'eleven': 11, 'twelve': 12, 'thirteen': 13,
  'fourteen': 14, 'fifteen': 15, 'sixteen': 16, 'seventeen': 17,
  'eighteen': 18, 'nineteen': 19, 'twenty': 20, 'thirty': 30,
  'forty': 40, 'fifty': 50, 'sixty': 60, 'seventy': 70,
  'eighty': 80, 'ninety': 90,
};

// ---------------------------------------------------------------------------
// Small helpers.
// ---------------------------------------------------------------------------

final class _NumberRef {
  const _NumberRef(this.index, this.value);

  final int index;
  final num value;

  bool get isWhole => value == value.roundToDouble();

  int get whole => value.round();
}

bool _anyOf(Set<String> words, List<String> tokens) =>
    tokens.any(words.contains);

List<String> _stripWakeWord(List<String> tokens) {
  var start = 0;
  while (start < tokens.length && _greetings.contains(tokens[start])) {
    start++;
  }
  if (start < tokens.length && tokens[start] == 'walsey') {
    start++;
  }
  return tokens.sublist(start);
}

bool _isTersePower(List<String> tokens,
    {required bool hasOn, required bool hasOff}) {
  final meaningful = [
    for (final token in tokens)
      if (token != 'the' && token != 'please' && token != 'now') token,
  ];
  if (meaningful.length != 2) return false;
  final state = hasOn && !hasOff ? 'on' : (hasOff && !hasOn ? 'off' : null);
  return state != null &&
      _lightNouns.contains(meaningful[0]) &&
      meaningful[1] == state;
}

String? _firstMeaningfulAfter(
  List<String> tokens,
  Set<String> keywords,
  Set<String> skip,
) {
  final index = tokens.indexWhere(keywords.contains);
  if (index < 0) return null;
  for (var i = index + 1; i < tokens.length; i++) {
    final token = tokens[i];
    if (skip.contains(token)) continue;
    return token;
  }
  return null;
}

String? _unknownWordAfterLight(List<String> tokens) {
  final lightIndex = tokens.indexWhere(_lightNouns.contains);
  if (lightIndex < 0) return null;
  for (var i = lightIndex + 1; i < tokens.length; i++) {
    final token = tokens[i];
    if (_knownWords.contains(token)) continue;
    return token;
  }
  return null;
}

List<_NumberRef> _numbers(List<String> tokens) {
  final refs = <_NumberRef>[];
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    final direct = double.tryParse(token);
    if (direct != null) {
      refs.add(_NumberRef(i, direct));
      continue;
    }
    final word = _wordNumber(token);
    if (word == null) continue;
    if (i + 1 < tokens.length &&
        tokens[i + 1] == 'hundred' &&
        word >= 1 &&
        word <= 9) {
      refs.add(_NumberRef(i, word * 100));
      i++;
      continue;
    }
    // Compound tens: "seventy two", "fifty five".
    if (word >= 20 && word % 10 == 0 && i + 1 < tokens.length) {
      final ones = _numberWords[tokens[i + 1]];
      if (ones != null && ones >= 1 && ones <= 9) {
        refs.add(_NumberRef(i, word + ones));
        i++;
        continue;
      }
    }
    refs.add(_NumberRef(i, word));
  }
  return refs;
}

int? _wordNumber(String token) {
  if (token == 'hundred') return 100;
  return _numberWords[token];
}

List<_NumberRef> _numbersWithoutDurations(
  List<String> tokens,
  List<_NumberRef> refs,
) {
  return [
    for (final ref in refs)
      if (ref.index + 1 >= tokens.length ||
          !_timeUnits.contains(tokens[ref.index + 1]))
        ref,
  ];
}

List<_NumberRef> _numbersNear(
  List<String> tokens,
  List<_NumberRef> refs,
  Set<String> keywords, {
  int window = 3,
}) {
  final positions = <int>[
    for (var i = 0; i < tokens.length; i++)
      if (keywords.contains(tokens[i])) i,
  ];
  if (positions.isEmpty) return refs;
  return [
    for (final ref in refs)
      if (positions.any((position) => (ref.index - position).abs() <= window))
        ref,
  ];
}

/// Words that can legitimately follow a light noun without naming a colour.
///
/// Runtime `final` on purpose: the source sets overlap, and a const literal
/// rejects duplicate spread elements.
final _knownWords = <String>{
  ..._lightNouns,
  ..._settingVerbs,
  ..._increaseWords,
  ..._decreaseWords,
  ..._brightnessNouns,
  ..._colorNouns,
  ..._effectNouns,
  ..._powerVerbs,
  ..._timeUnits,
  'on',
  'off',
  'percent',
  'to',
  'the',
  'a',
  'an',
  'at',
  'and',
  'please',
  'now',
  'my',
  'our',
  'me',
  'for',
  'of',
  'with',
  'brighter',
  'dimmer',
};
