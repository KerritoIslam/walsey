import 'package:flutter/material.dart';
import 'package:walsey_voice_core/walsey_voice_core.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

import 'model_manager_dialog.dart';

/// Stage 2 voice testing screen.
///
/// Speech and typed input share the exact same [VoiceCommandParser] and the
/// result still says "not executed". This page imports the voice core and the
/// speech adapter only: there is no BLE dependency, so no code path here can
/// change the LEDs.
class VoiceTestPage extends StatefulWidget {
  const VoiceTestPage({
    super.key,
    this.recognizer,
    this.modelStore,
    this.parser,
    this.diagnostics,
  });

  /// Test seam: a fake recognizer keeps widget tests microphone-free.
  final SpeechRecognizer? recognizer;

  /// Test seam for the model manager.
  final ModelStore? modelStore;

  /// Optional parser override; production uses [VoiceCommandParser].
  final VoiceCommandParser? parser;

  /// Measurement seam. Production creates its own; tests can pre-populate one
  /// to render the diagnostics panel without a microphone.
  final SessionDiagnostics? diagnostics;

  @override
  State<VoiceTestPage> createState() => _VoiceTestPageState();
}

class _VoiceTestPageState extends State<VoiceTestPage> {
  final TextEditingController _controller = TextEditingController();

  late final SpeechRecognizer _recognizer;
  late final ModelStore _modelStore;
  late final VoiceCommandParser _parser;
  late final PushToTalkController _voice;
  late final SessionDiagnostics _diagnostics;
  late final bool _ownsDiagnostics;

  bool? _modelInstalled;
  int _modelCheckGeneration = 0;

  static const List<String> _problemCases = [
    'Turn the lights on and off',
    'Set brightness to 150 percent',
    'Make the lights teal',
    'Tell me a joke',
    "I don't want the lights on",
    'Activate the next effect',
  ];

  @override
  void initState() {
    super.initState();
    _ownsDiagnostics = widget.diagnostics == null;
    _diagnostics = widget.diagnostics ?? SessionDiagnostics();
    _diagnostics.addListener(_onVoiceChanged);
    _recognizer =
        widget.recognizer ??
        VoskSpeechRecognizer.platform(diagnostics: _diagnostics);
    _modelStore = widget.modelStore ?? ModelStore.platform();
    _parser = widget.parser ?? VoiceCommandParser();
    _voice = PushToTalkController(
      recognizer: _recognizer,
      parser: _parser,
    )..addListener(_onVoiceChanged);
    _refreshModelStatus();
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceChanged);
    _voice.dispose();
    _diagnostics.removeListener(_onVoiceChanged);
    if (_ownsDiagnostics) {
      _diagnostics.dispose();
    }
    _controller.dispose();
    super.dispose();
  }

  void _onVoiceChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _refreshModelStatus() async {
    final generation = ++_modelCheckGeneration;
    final model = _voice.language.model;
    if (model == null) {
      if (mounted) {
        setState(() => _modelInstalled = false);
      }
      return;
    }
    if (mounted && _modelInstalled != null) {
      setState(() => _modelInstalled = null);
    }
    bool installed;
    try {
      installed = await _modelStore.isInstalled(model);
    } on Object {
      installed = false;
    }
    if (mounted && generation == _modelCheckGeneration) {
      setState(() => _modelInstalled = installed);
    }
  }

  void _analyze() {
    if (_voice.status.isActive) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _voice.analyzeTyped(_controller.text);
  }

  void _clear() {
    if (_voice.status.isActive) {
      return;
    }
    _controller.clear();
    _voice.clear();
    _diagnostics.clear();
  }

  void _useExample(String example) {
    _controller.text = example;
    _analyze();
  }

  Future<void> _onMicPressed() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_voice.status == PushToTalkStatus.listening) {
      await _voice.stopListening();
    } else {
      await _voice.startListening();
    }
  }

  Future<void> _openModelManager() async {
    await showDialog<void>(
      context: context,
      builder: (_) => ModelManagerDialog(store: _modelStore),
    );
    await _refreshModelStatus();
  }

  void _onLanguageChanged(SpeechLanguage? language) {
    if (language == null) {
      return;
    }
    _voice.selectLanguage(language);
    _refreshModelStatus();
  }

  bool _savingWav = false;

  Future<void> _saveWav() async {
    if (_savingWav) {
      return;
    }
    setState(() => _savingWav = true);
    try {
      final file = await _diagnostics.saveWavToAppFolder();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            file == null
                ? 'No audio was captured in the last take.'
                : 'Saved a 16 kHz mono PCM16 WAV to ${file.path}',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the recording: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _savingWav = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final examples = [
      for (final action in _parser.registry.actions) action.example,
    ];
    final interpretation = _voice.interpretation;

    return Scaffold(
      appBar: AppBar(title: const Text('Walsey voice — Stage 2 test')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _StageBanner(),
              const SizedBox(height: 16),
              _VoicePanel(
                controller: _voice,
                modelInstalled: _modelInstalled,
                onMicPressed: _onMicPressed,
                onCancel: _voice.cancel,
                onRetry: _voice.retry,
                onManageModels: _openModelManager,
                onLanguageChanged: _onLanguageChanged,
              ),
              if (_diagnostics.hasSession) ...[
                const SizedBox(height: 12),
                if (_diagnostics.rawTranscript != null)
                  _RawTranscriptCard(text: _diagnostics.rawTranscript!),
                const SizedBox(height: 12),
                _DiagnosticsCard(
                  diagnostics: _diagnostics,
                  saving: _savingWav,
                  onSave: _saveWav,
                  onClear: _diagnostics.clear,
                ),
              ],
              const SizedBox(height: 20),
              const _SectionTitle('Typed command (works without a microphone)'),
              const SizedBox(height: 6),
              TextField(
                controller: _controller,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Command text',
                  hintText: 'For example: Turn the lights blue.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _voice.status.isActive ? null : _analyze,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Analyze'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _voice.status.isActive ? null : _clear,
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const _SectionTitle('Example commands'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final example in examples)
                    ActionChip(
                      label: Text(example),
                      onPressed: () => _useExample(example),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const _SectionTitle('Problem cases to inspect'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final example in _problemCases)
                    ActionChip(
                      label: Text(example),
                      onPressed: () => _useExample(example),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              if (interpretation == null)
                const _IdleHint()
              else
                _Interpretation(
                  result: interpretation,
                  source: _voice.interpretationSource,
                ),
              const SizedBox(height: 20),
              const _LimitationsNote(),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoicePanel extends StatelessWidget {
  const _VoicePanel({
    required this.controller,
    required this.modelInstalled,
    required this.onMicPressed,
    required this.onCancel,
    required this.onRetry,
    required this.onManageModels,
    required this.onLanguageChanged,
  });

  final PushToTalkController controller;
  final bool? modelInstalled;
  final Future<void> Function() onMicPressed;
  final Future<void> Function() onCancel;
  final Future<void> Function() onRetry;
  final Future<void> Function() onManageModels;
  final ValueChanged<SpeechLanguage?> onLanguageChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status = controller.status;

    final modelLabel = switch (controller.language.model) {
      null => 'No model exists',
      _ when modelInstalled == null => 'Model: checking…',
      _ when modelInstalled == true => 'Model installed',
      _ => 'Model missing',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.graphic_eq, color: colors.primary),
                const SizedBox(width: 8),
                const Text(
                  'Push to talk',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Chip(
                  label: Text(status.label),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: switch (status) {
                    PushToTalkStatus.error => colors.errorContainer,
                    PushToTalkStatus.listening => colors.primaryContainer,
                    PushToTalkStatus.result => colors.secondaryContainer,
                    _ => colors.surfaceContainerHighest,
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<SpeechLanguage>(
                    value: controller.language,
                    isExpanded: true,
                    onChanged: status.isActive ? null : onLanguageChanged,
                    items: [
                      for (final language in SpeechLanguage.all)
                        DropdownMenuItem(
                          value: language,
                          child: Text(
                            language.isSupported
                                ? language.label
                                : '${language.label} (unsupported)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(modelLabel, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            if (controller.language.model != null) ...[
              const SizedBox(height: 2),
              Text(
                controller.language.model!.id,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (controller.partialText != null) ...[
              const SizedBox(height: 8),
              Text(
                '"${controller.partialText}"',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: switch (status) {
                    PushToTalkStatus.listening => onMicPressed,
                    PushToTalkStatus.initializing ||
                    PushToTalkStatus.recognizing => null,
                    _ => controller.canStart ? onMicPressed : null,
                  },
                  icon: Icon(
                    switch (status) {
                      PushToTalkStatus.listening => Icons.stop,
                      PushToTalkStatus.initializing ||
                      PushToTalkStatus.recognizing => Icons.hourglass_top,
                      _ => Icons.mic,
                    },
                  ),
                  label: Text(
                    switch (status) {
                      PushToTalkStatus.listening => 'Stop & recognize',
                      PushToTalkStatus.initializing => 'Initializing…',
                      PushToTalkStatus.recognizing => 'Recognizing…',
                      _ => 'Start listening',
                    },
                  ),
                ),
                if (controller.canCancel)
                  OutlinedButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close),
                    label: const Text('Cancel'),
                  ),
                if (controller.canRetry)
                  OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                OutlinedButton.icon(
                  onPressed: onManageModels,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Language models'),
                ),
              ],
            ),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.failureKind?.label ?? 'Recognition error',
                      style: TextStyle(
                        color: colors.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      controller.errorMessage!,
                      style: TextStyle(color: colors.onErrorContainer),
                    ),
                    if (controller.failureKind ==
                        SpeechFailureKind.modelNotInstalled)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton(
                          onPressed: onManageModels,
                          child: const Text('Set up a language model'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (controller.notice != null) ...[
              const SizedBox(height: 10),
              Text(
                controller.notice!,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
            if (controller.finalText != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Recognized text',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(controller.finalText!),
                    const SizedBox(height: 6),
                    Text(
                      'Vosk · ${controller.language.label} · on this device. '
                      'Nothing was executed.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Verbatim Vosk output, shown before the parser sees the sentence.
///
/// Keeping it separate from "Recognized text" makes a mishearing obvious: if
/// the raw text is already wrong, the parser was never the problem.
class _RawTranscriptCard extends StatelessWidget {
  const _RawTranscriptCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Raw transcript (Vosk, verbatim)',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            SelectableText(
              text,
              style: TextStyle(color: colors.onSurface),
            ),
            const SizedBox(height: 6),
            Text(
              'Exactly what the engine returned, before normalization. '
              'The parser result below is derived from this text.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Diagnostic mode: what the microphone delivered and what can be exported.
class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({
    required this.diagnostics,
    required this.saving,
    required this.onSave,
    required this.onClear,
  });

  final SessionDiagnostics diagnostics;
  final bool saving;
  final Future<void> Function() onSave;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rows = diagnostics.summaryRows;
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final wavPath = diagnostics.wavPath;
    return Card(
      color: colors.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Diagnostic mode — audio actually captured',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 190,
                      child: Text(
                        label,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                    Expanded(child: Text(value)),
                  ],
                ),
              ),
            if (diagnostics.bufferTruncated) ...[
              const SizedBox(height: 6),
              Text(
                'Only the first part of this take is buffered; the WAV export '
                'is shorter than the measured duration.',
                style: TextStyle(color: colors.error),
              ),
            ],
            if (wavPath != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                'WAV: $wavPath',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: saving ? null : onSave,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save test recording (WAV)'),
                ),
                TextButton(
                  onPressed: onClear,
                  child: const Text('Clear diagnostics'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Diagnostic only: the WAV is written locally under the app '
              'support folder, never uploaded. Recognition still uses the live '
              'stream, not the file.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _StageBanner extends StatelessWidget {
  const _StageBanner();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, color: colors.onTertiaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Stage 2 test mode — execution disabled.\n'
                'Speech is recognized offline with Vosk and parsed exactly like '
                'typed text. Nothing you type here can change the LEDs, and no '
                'LED command is ever sent.',
                style: TextStyle(color: colors.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdleHint extends StatelessWidget {
  const _IdleHint();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Press the microphone and say a command, or type one below. '
          'Recognition and parsing are deterministic, local and read-only.',
        ),
      ),
    );
  }
}

class _Interpretation extends StatelessWidget {
  const _Interpretation({required this.result, required this.source});

  final VoiceResult result;
  final InterpretationSource? source;

  @override
  Widget build(BuildContext context) {
    // A local enables promotion; a widget field cannot be promoted.
    final result = this.result;
    final colors = Theme.of(context).colorScheme;
    final (label, background, foreground) = switch (result) {
      VoiceCommandResult() => (
        'Valid command',
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      VoiceFailure(:final kind) => (
        kind.label,
        kind == VoiceFailureKind.ambiguous
            ? colors.tertiaryContainer
            : colors.errorContainer,
        kind == VoiceFailureKind.ambiguous
            ? colors.onTertiaryContainer
            : colors.onErrorContainer,
      ),
    };

    final command = result is VoiceCommandResult ? result.command : null;
    final failure = result is VoiceFailure ? result : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Interpretation',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _InfoRow(label: 'Input', value: result.sourceText),
            if (source != null) _InfoRow(label: 'Source', value: source!.label),
            if (command != null) ...[
              _InfoRow(label: 'Intent', value: command.intent.label),
              _InfoRow(label: 'Action id', value: command.actionId),
              _InfoRow(
                label: 'Parameters',
                value: command.parameters.summary.isEmpty
                    ? 'None'
                    : command.parameters.summary.join('\n'),
              ),
              const _InfoRow(label: 'Validation', value: 'Valid command'),
            ] else ...[
              _InfoRow(
                label: 'Intent',
                value: failure?.intent?.label ?? 'Unknown',
              ),
              _InfoRow(label: 'Validation', value: failure!.kind.label),
              _InfoRow(label: 'Explanation', value: failure.explanation),
            ],
            const Divider(height: 24),
            _InfoRow(label: 'Execution', value: result.executionStatus.label),
            if (command != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Parsing and validation succeeded. No LED command was sent: '
                  'Stage 2 only previews commands.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleSmall);
  }
}

class _LimitationsNote extends StatelessWidget {
  const _LimitationsNote();

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return Text(
      'Notes: Vosk needs one explicit per-language model download (about '
      '40–100 MB) and runs fully offline once installed; no cloud service is '
      'used. English (US) is the tested language; French and Modern Standard '
      'Arabic models can be installed but the command parser is English-only, '
      'and no Algerian Darija model exists. Brightness is validated as a whole '
      'percentage 0..100 and is never clamped. Colours come from a fixed list. '
      'Effects are documented ids only (1..210 or 255).',
      style: textStyle,
    );
  }
}
