import '../context/voice_conversation.dart';
import '../domain/voice_intent.dart';
import '../domain/voice_parameters.dart';
import '../domain/voice_result.dart';
import '../parser/normalization.dart';
import '../parser/paraphrase.dart';
import '../parser/voice_command_parser.dart';
import 'command_interpreter.dart';
import 'voice_plan.dart';

/// Turns one sentence into an ordered [VoicePlan].
///
/// This is a planning layer, **not** a replacement for the Stage 1 parser:
///
/// * A single lighting sentence is delegated to [VoiceCommandParser] first, so
///   every existing guarantee (negation, questions, registry allowlist,
///   parameter validation, ambiguity) still decides the outcome.
/// * Only sentences Stage 1 explicitly cannot express as one command are
///   decomposed into steps. Parameter-level failures (`invalidParameter`,
///   `missingParameter`, or an ambiguity that names an intent) are returned
///   unchanged and are never split into several actions.
/// * A plan is data. Nothing in this package can execute a step, and the
///   registry remains the authorization allowlist.
///
/// The connector vocabulary is deliberately small and explicit; there is no
/// fuzzy matching.
final class VoicePlanParser implements CommandInterpreter {
  VoicePlanParser({VoiceCommandParser? parser, this.conversation})
      : _parser = parser ?? VoiceCommandParser();

  final VoiceCommandParser _parser;

  /// Optional follow-up memory. When present, a pronoun-only lighting request
  /// ("make them blue") can plan a reconnect to the recently targeted device.
  /// It never bypasses validation or device capability checks.
  final VoiceConversation? conversation;

  /// Stage 1 parser used for individual lighting segments and for guards.
  VoiceCommandParser get parser => _parser;

  /// [CommandInterpreter] entry point; identical to [parse].
  @override
  VoicePlanResult interpret(String input) => parse(input);

  /// Analyzes [input] and returns a ready plan or an explicit failure.
  VoicePlanResult parse(String input) {
    final normalized = normalizeCommandText(input);
    if (normalized.isEmpty) {
      return _failureFrom(
        _parser.parse(input),
        'Enter a command sentence, for example "turn the lights on".',
      );
    }

    final whole = _parser.parse(input);
    // Same literal paraphrase table the Stage 1 parser uses, so a split step
    // sees exactly the canonical vocabulary that a whole-sentence parse would.
    final tokens = normalizeParaphrases(_stripGreeting(normalized.tokens));
    final hasDeviceAction = _containsAny(tokens, _deviceVerbs);
    // A sentence with an explicit connector is a plan candidate even when the
    // whole sentence also happens to parse as one command. Otherwise
    // "turn on the lights and play music" would plan the light step and
    // silently ignore the unsupported half.
    final hasConnector = _containsAny(tokens, _connectors);
    if (whole is VoiceCommandResult && !hasDeviceAction && !hasConnector) {
      final step = _stepFor(whole.command);
      if (step != null) {
        return VoicePlanReady(
          sourceText: input,
          plan: VoicePlan(sourceText: input, steps: [step]),
        );
      }
      return _relativeFailure(input);
    }
    if (whole is VoiceFailure) {
      // Parameter problems are not repaired by splitting the sentence.
      if (whole.intent != null) return _planFailure(whole);
      if (whole.kind != VoiceFailureKind.unsupported &&
          whole.kind != VoiceFailureKind.ambiguous &&
          whole.kind != VoiceFailureKind.emptyInput) {
        return _planFailure(whole);
      }
      if (whole.kind == VoiceFailureKind.emptyInput) return _planFailure(whole);
    }

    if (tokens.isEmpty) return _planFailure(whole);

    final segments = _split(tokens);
    if (segments.length == 1) {
      final segment = segments.single;
      final result = _planSegment(segment, soFar: const []);
      if (result.ready) {
        return VoicePlanReady(
          sourceText: input,
          plan: VoicePlan(sourceText: input, steps: _finalize(result.steps)),
        );
      }
      // A single sentence that Stage 1 could not express and the plan grammar
      // does not know either keeps Stage 1's explanation — except when the
      // plan grammar recognized a specific device/scene failure.
      final failure = result.failure;
      if (failure != null &&
          (failure.kind != VoiceFailureKind.unsupported ||
              failure.explanation.startsWith('Scenes'))) {
        return VoicePlanFailure(
          sourceText: input,
          kind: failure.kind,
          explanation: failure.explanation,
          intent: failure.intent,
        );
      }
      return _planFailure(whole);
    }

    final steps = <VoicePlanStep>[];
    for (final segment in segments) {
      final result = _planSegment(segment, soFar: steps);
      if (!result.ready) {
        return VoicePlanFailure(
          sourceText: input,
          kind: result.kind,
          explanation: result.explanation,
          intent: result.intent,
        );
      }
      steps.addAll(result.steps);
    }

    if (steps.isEmpty) return _planFailure(whole);

    final plansPowerOn = steps.any((s) => s is SetPowerStep && s.on);
    final plansPowerOff = steps.any((s) => s is SetPowerStep && !s.on);
    if (plansPowerOn && plansPowerOff) {
      return VoicePlanFailure(
        sourceText: input,
        kind: VoiceFailureKind.ambiguous,
        explanation: 'The sentence asks for both "on" and "off". Nothing was '
            'executed.',
      );
    }

    return VoicePlanReady(
      sourceText: input,
      plan: VoicePlan(sourceText: input, steps: _finalize(steps)),
    );
  }

  // --------------------------------------------------------------------------
  // Segments
  // --------------------------------------------------------------------------

  List<List<String>> _split(List<String> tokens) {
    final segments = <List<String>>[];
    var current = <String>[];
    for (final token in tokens) {
      if (_connectors.contains(token)) {
        if (current.isNotEmpty) segments.add(current);
        current = <String>[];
      } else {
        current.add(token);
      }
    }
    if (current.isNotEmpty) segments.add(current);
    return segments;
  }

  _SegmentResult _planSegment(List<String> tokens, {required List<VoicePlanStep> soFar}) {
    final text = tokens.join(' ');

    // A terse continuation such as "turn the lights on and off" arrives as a
    // bare "off" segment. It is still the same Stage 1 power command.
    if (tokens.length == 1 && (tokens.single == 'on' || tokens.single == 'off')) {
      return _ready([SetPowerStep(on: tokens.single == 'on')]);
    }

    // Stage 1 safety guards win before any device/intent is recognized, so
    // "don't scan" or "open the door and turn on the lights" never plan work.
    if (_hasGuardWord(tokens)) {
      final guarded = _parser.parse(text);
      if (guarded is VoiceFailure) {
        return _failedPlan(_planFailure(guarded));
      }
    }

    final device = _planDevice(tokens);
    if (device != null) return device;

    return _planLighting(tokens, soFar: soFar);
  }

  _SegmentResult? _planDevice(List<String> tokens) {
    if (tokens.contains('reconnect')) {
      return _ready([const ReconnectLastDeviceStep()]);
    }
    if (tokens.contains('disconnect')) {
      return _ready([const DisconnectDeviceStep()]);
    }
    if (_isScanRequest(tokens)) {
      return _ready([const ScanDevicesStep()]);
    }
    if (tokens.contains('scene') || tokens.contains('scenes')) {
      if (tokens.contains('save') || tokens.contains('store')) {
        return _ready([const SaveSceneStep()]);
      }
      return _failed(
        const _SegmentFailure(
          kind: VoiceFailureKind.unsupported,
          explanation: 'Scenes are not implemented in this app yet, so nothing '
              'was applied or saved.',
        ),
      );
    }
    if (_containsAny(tokens, const {'connect', 'pair'})) {
      final steps = _connectSteps(tokens);
      return _ready(steps);
    }
    return null;
  }

  List<VoicePlanStep> _connectSteps(List<String> tokens) {
    final rest = tokens.skip(_connectIndex(tokens) + 1).toList();
    if (rest.contains('last')) {
      return const [
        SelectDeviceStep(target: VoiceDeviceTarget.lastAvailable),
        ConnectDeviceStep(),
      ];
    }
    if (rest.contains('first')) {
      return const [
        SelectDeviceStep(target: VoiceDeviceTarget.firstAvailable),
        ConnectDeviceStep(),
      ];
    }
    final nameTokens = [
      for (final token in rest)
        if (!_connectStopWords.contains(token)) token,
    ];
    if (nameTokens.isEmpty ||
        nameTokens.every(_genericDeviceWords.contains)) {
      return const [
        SelectDeviceStep(target: VoiceDeviceTarget.knownOrFirst),
        ConnectDeviceStep(),
      ];
    }
    return [
      SelectDeviceStep(
        target: VoiceDeviceTarget.named,
        name: nameTokens.join(' '),
      ),
      const ConnectDeviceStep(),
    ];
  }

  int _connectIndex(List<String> tokens) =>
      tokens.indexWhere((t) => t == 'connect' || t == 'pair');

  _SegmentResult _planLighting(
    List<String> tokens, {
    required List<VoicePlanStep> soFar,
  }) {
    final text = tokens.join(' ');
    final highlights = _parser.parse(text);
    if (highlights is VoiceCommandResult) {
      final step = _stepFor(highlights.command);
      if (step == null) return _failedPlan(_relativeFailure(text));
      return _ready(_withDeviceSteps(step, tokens, soFar));
    }

    // "turn it on", "change it to blue": the sentence relies on the device
    // already in focus. Adding the documented light noun lets the same Stage 1
    // parser validate the command without inventing a new grammar.
    if (!_hasLightNoun(tokens) && _refersToDevice(tokens)) {
      final contextText = _contextLightingText(tokens);
      final resolved = _parser.parse('the lights $contextText');
      if (resolved is VoiceCommandResult) {
        final step = _stepFor(resolved.command);
        if (step == null) return _failedPlan(_relativeFailure(text));
        return _ready(
          _withDeviceSteps(step, tokens, soFar, pronoun: true),
        );
      }
      if (resolved is VoiceFailure && (resolved.explanation.isNotEmpty)) {
        // Keep the resolved failure only when it is about the parameters of a
        // recognized action; otherwise report the original failure.
        if (resolved.intent != null) {
          return _failed(
        _SegmentFailure(
              kind: resolved.kind,
              explanation: 'Part "$text": ${resolved.explanation}',
              intent: resolved.intent,
            ),
          );
        }
      }
    }

    final failure = highlights as VoiceFailure;
    return _failed(
        _SegmentFailure(
        kind: failure.kind,
        explanation: 'Part "$text": ${failure.explanation}',
        intent: failure.intent,
      ),
    );
  }

  /// Adds Select+Connect before a lighting step that refers to a device after
  /// a scan, e.g. "scan for devices and turn the first one on".
  ///
  /// For a pronoun-only follow-up ("make them blue"), fresh conversation
  /// memory instead adds a reconnect step, so the follow-up does not fail just
  /// because the link dropped between commands. The executor skips the
  /// reconnect when the link is still open.
  List<VoicePlanStep> _withDeviceSteps(
    VoicePlanStep step,
    List<String> tokens,
    List<VoicePlanStep> soFar, {
    bool pronoun = false,
  }) {
    if (!_refersToDevice(tokens)) return [step];
    if (pronoun) {
      // A plan that already scanned/selected/connected in an earlier clause
      // keeps its own device steps; only a bare follow-up uses memory.
      final alreadyPlannedDeviceWork = soFar.any(
        (s) =>
            s is ScanDevicesStep ||
            s is SelectDeviceStep ||
            s is ConnectDeviceStep ||
            s is ReconnectLastDeviceStep,
      );
      if (!alreadyPlannedDeviceWork && (conversation?.hasFreshTarget ?? false)) {
        return [const ReconnectLastDeviceStep(), step];
      }
    }
    final hasConnectionStep = soFar.any(
      (s) => s is ConnectDeviceStep || s is ReconnectLastDeviceStep,
    );
    final hasScan = soFar.any(
      (s) =>
          s is ScanDevicesStep ||
          s is SelectDeviceStep ||
          s is ConnectDeviceStep ||
          s is ReconnectLastDeviceStep,
    );
    if (hasConnectionStep || !hasScan) return [step];

    final target = tokens.contains('last')
        ? VoiceDeviceTarget.lastAvailable
        : VoiceDeviceTarget.firstAvailable;
    return [
      SelectDeviceStep(target: target),
      const ConnectDeviceStep(),
      step,
    ];
  }

  VoicePlanStep? _stepFor(VoiceCommand command) {
    final parameters = command.parameters;
    switch (command.intent) {
      case VoiceIntent.powerOn:
        return const SetPowerStep(on: true);
      case VoiceIntent.powerOff:
        return const SetPowerStep(on: false);
      case VoiceIntent.setColor:
        return parameters is ColorParameters
            ? SetColorStep(parameters.color)
            : null;
      case VoiceIntent.setBrightness:
        return parameters is BrightnessParameters
            ? SetBrightnessStep(parameters.brightness)
            : null;
      case VoiceIntent.applyEffect:
        return parameters is EffectParameters
            ? ApplyEffectStep(parameters.effect)
            : null;
      case VoiceIntent.queryStatus:
        return const QueryStatusStep();
      case VoiceIntent.increaseBrightness:
      case VoiceIntent.decreaseBrightness:
        return null;
    }
  }

  /// Ensures a first/last selection has real scan results to choose from.
  List<VoicePlanStep> _finalize(List<VoicePlanStep> input) {
    final steps = <VoicePlanStep>[];
    var scanSeen = false;
    for (final step in input) {
      if (step is ScanDevicesStep) scanSeen = true;
      if (step is SelectDeviceStep &&
          !scanSeen &&
          (step.target == VoiceDeviceTarget.firstAvailable ||
              step.target == VoiceDeviceTarget.lastAvailable)) {
        steps.add(const ScanDevicesStep());
        scanSeen = true;
      }
      steps.add(step);
    }
    return List.unmodifiable(steps);
  }

  // --------------------------------------------------------------------------
  // Vocabulary and helpers
  // --------------------------------------------------------------------------

  bool _isScanRequest(List<String> tokens) =>
      _containsAny(tokens, _discoveryVerbs) &&
      _containsAny(tokens, _deviceNouns);

  bool _hasLightNoun(List<String> tokens) => _containsAny(tokens, _lightNouns);

  bool _refersToDevice(List<String> tokens) {
    if (_hasLightNoun(tokens)) return false;
    return _containsAny(tokens, _devicePronouns);
  }

  /// Drops ordinal/pronoun fillers so "turn the first one on" reaches the
  /// Stage 1 grammar as "turn on". Words that can carry a value are kept.
  String _contextLightingText(List<String> tokens) {
    if (_containsAny(tokens, _valueNouns)) return tokens.join(' ');
    return [
      for (final token in tokens)
        if (!_pronounFillers.contains(token)) token,
    ].join(' ');
  }

  bool _hasGuardWord(List<String> tokens) =>
      _containsAny(tokens, _negations) ||
      _containsAny(tokens, _questionWords) ||
      _containsAny(tokens, _unregisteredActions) ||
      (_containsAny(tokens, _otherDevices) && !_hasLightNoun(tokens));

  List<String> _stripGreeting(List<String> tokens) {
    var start = 0;
    while (start < tokens.length && _greetings.contains(tokens[start])) {
      start++;
    }
    if (start < tokens.length && tokens[start] == 'walsey') start++;
    return tokens.sublist(start);
  }

  bool _containsAny(List<String> tokens, Set<String> words) =>
      tokens.any(words.contains);

  VoicePlanFailure _planFailure(VoiceResult result) => switch (result) {
        VoiceCommandResult(:final command) => VoicePlanFailure(
            sourceText: command.sourceText,
            kind: VoiceFailureKind.unsupported,
            explanation: 'The sentence was understood as ${command.intent.label} '
                'but it does not fit a plan.',
          ),
        VoiceFailure(
          :final sourceText,
          :final kind,
          :final explanation,
          :final intent,
        ) =>
          VoicePlanFailure(
            sourceText: sourceText,
            kind: kind,
            explanation: explanation,
            intent: intent,
          ),
      };

  VoicePlanFailure _failureFrom(VoiceResult result, String fallback) =>
      result is VoiceFailure
          ? VoicePlanFailure(
              sourceText: result.sourceText,
              kind: result.kind,
              explanation: result.explanation,
              intent: result.intent,
            )
          : VoicePlanFailure(
              sourceText: '',
              kind: VoiceFailureKind.emptyInput,
              explanation: fallback,
            );

  VoicePlanFailure _relativeFailure(String text) => VoicePlanFailure(
        sourceText: text,
        kind: VoiceFailureKind.unsupported,
        explanation: 'Relative brightness or effect selection needs device '
            'state, which the controller protocol cannot read. Ask for an '
            'absolute value instead.',
        
      );

  _SegmentResult _ready(List<VoicePlanStep> steps) =>
      _SegmentResult.ready(steps);

  _SegmentResult _failed(_SegmentFailure failure) =>
      _SegmentResult.failed(failure);

  _SegmentResult _failedPlan(VoicePlanFailure failure) => _SegmentResult.failed(
        _SegmentFailure(
          kind: failure.kind,
          explanation: failure.explanation,
          intent: failure.intent,
        ),
      );
}

final class _SegmentResult {
  const _SegmentResult._({
    this.steps = const [],
    this.failure,
  });

  factory _SegmentResult.ready(List<VoicePlanStep> steps) =>
      _SegmentResult._(steps: steps);

  factory _SegmentResult.failed(_SegmentFailure failure) =>
      _SegmentResult._(failure: failure);

  final List<VoicePlanStep> steps;
  final _SegmentFailure? failure;

  bool get ready => failure == null;
  VoiceFailureKind get kind => failure?.kind ?? VoiceFailureKind.unsupported;
  String get explanation => failure?.explanation ?? '';
  VoiceIntent? get intent => failure?.intent;
}

final class _SegmentFailure {
  const _SegmentFailure({
    required this.kind,
    required this.explanation,
    this.intent,
  });

  final VoiceFailureKind kind;
  final String explanation;
  final VoiceIntent? intent;
}

const _connectors = {'and', 'then', 'also', 'plus', 'afterwards'};

const _greetings = {'hey', 'ok', 'okay'};

// Mirrors the Stage 1 guard vocabulary. Kept in sync deliberately: the plan
// layer only runs these checks so a device/step sentence cannot bypass them.
const _negations = {
  'not', 'dont', 'doesnt', 'didnt', 'never', 'wont', //
  'cannot', 'cant', 'shouldnt', 'wouldnt', 'without',
};

const _questionWords = {
  'what', 'why', 'who', 'where', 'when', 'how', 'which', 'tell', //
  'should', 'do', 'does', 'did', 'is', 'are', 'am', 'may',
};

const _unregisteredActions = {
  'open', 'launch', 'close', 'mute', 'screenshot', 'shutdown', 'restart',
};

const _otherDevices = {
  'tv', 'television', 'fan', 'music', 'volume', //
  'computer', 'laptop', 'phone', 'car', 'oven', 'heater',
};

const _discoveryVerbs = {
  'scan', 'search', 'find', 'discover', 'look', 'list', 'show',
};

/// Device-management verbs. When any of these appear, the sentence is planned
/// instead of being accepted as one Stage 1 lighting command: Stage 1 ignores
/// them, and a compound sentence like "connect ... and set blue" would
/// otherwise silently drop the connection step.
const _deviceVerbs = {
  'scan', 'search', 'find', 'discover', 'connect', 'pair', 'disconnect',
  'reconnect',
};

const _deviceNouns = {
  'device', 'devices', 'led', 'leds', 'light', 'lights', 'strip', 'strips',
  'controller', 'controllers', 'bluetooth', 'nearby', 'available',
};

const _lightNouns = {
  'light', 'lights', 'led', 'leds', 'lamp', 'lamps', //
  'strip', 'strips', 'neon',
};

const _devicePronouns = {
  'it', 'them', 'that', 'this', 'one', 'device', 'devices', 'controller',
  'controllers',
};

const _pronounFillers = {
  'it', 'them', 'that', 'this', 'one', 'device', 'devices', 'controller',
  'controllers', 'first', 'second', 'third', 'last',
};

const _valueNouns = {'brightness', 'bright', 'effect', 'effects'};

const _genericDeviceWords = {
  'device', 'devices', 'controller', 'controllers', 'led', 'leds', 'light',
  'lights', 'strip', 'strips', 'one', 'it', 'that', 'this', 'current',
  'available', 'supported', 'nearby',
};

const _connectStopWords = {
  'to', 'the', 'a', 'an', 'my', 'our', 'with', 'please', 'now',
};
