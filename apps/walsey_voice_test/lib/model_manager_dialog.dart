import 'package:flutter/material.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// Explicit, user-triggered language-model setup.
///
/// Nothing here runs at startup and nothing is downloaded without pressing
/// "Install". The dialog reports the download size, checksum, licence and the
/// storage folder so the setup is never a hidden network side effect.
class ModelManagerDialog extends StatefulWidget {
  const ModelManagerDialog({
    super.key,
    required this.store,
    this.models = SpeechModel.all,
  });

  final ModelStore store;
  final List<SpeechModel> models;

  @override
  State<ModelManagerDialog> createState() => _ModelManagerDialogState();
}

class _ModelManagerDialogState extends State<ModelManagerDialog> {
  final Map<String, bool> _installed = {};
  final Map<String, ModelInstallProgress> _progress = {};
  final Map<String, String> _errors = {};
  final Set<String> _installing = {};
  bool _cancelRequested = false;
  bool _loading = true;
  String? _storagePath;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final installed = <String, bool>{};
    for (final model in widget.models) {
      installed[model.id] = await widget.store.isInstalled(model);
    }
    String? storage;
    try {
      storage = (await widget.store.modelsDirectory()).path;
    } on Object {
      storage = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _installed
        ..clear()
        ..addAll(installed);
      _storagePath = storage;
      _loading = false;
    });
  }

  Future<void> _install(SpeechModel model) async {
    // One download at a time: the cancel flag and progress reporting are
    // dialog-wide, and serial installs keep the network use explicit.
    if (_installing.isNotEmpty) {
      return;
    }
    setState(() {
      _installing.add(model.id);
      _errors.remove(model.id);
      _cancelRequested = false;
      _progress[model.id] = ModelInstallProgress(
        phase: ModelInstallPhase.downloading,
        receivedBytes: 0,
        totalBytes: model.archiveSizeBytes,
      );
    });
    try {
      await widget.store.install(
        model,
        isCancelled: () => _cancelRequested,
        onProgress: (progress) {
          if (mounted && _installing.contains(model.id)) {
            setState(() => _progress[model.id] = progress);
          }
        },
      );
      if (mounted) {
        setState(() => _installed[model.id] = true);
      }
    } on ModelInstallCancelled {
      if (mounted) {
        setState(() => _errors[model.id] = 'Download cancelled.');
      }
    } on ModelInstallException catch (error) {
      if (mounted) {
        setState(() => _errors[model.id] = error.message);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _errors[model.id] = 'Installation failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _installing.remove(model.id);
          _progress.remove(model.id);
        });
      }
    }
  }

  Future<void> _remove(SpeechModel model) async {
    setState(() => _errors.remove(model.id));
    try {
      await widget.store.remove(model);
      if (mounted) {
        setState(() => _installed[model.id] = false);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _errors[model.id] = 'Could not remove the model: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Offline language models'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Vosk runs entirely on this device. A model is required before '
                'the microphone can be used, so each download is explicit and '
                'one-time. Nothing is downloaded at startup and no cloud '
                'service is ever used.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              if (_storagePath != null)
                Text(
                  'Storage: $_storagePath',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 12),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                )
              else
                for (final model in widget.models) ...[
                  _ModelCard(
                    model: model,
                    installed: _installed[model.id] ?? false,
                    busy: _installing.contains(model.id),
                    canInstall: _installing.isEmpty,
                    progress: _progress[model.id],
                    error: _errors[model.id],
                    onInstall: () => _install(model),
                    onCancel: _installing.contains(model.id)
                        ? () => setState(() => _cancelRequested = true)
                        : null,
                    onRemove: () => _remove(model),
                  ),
                  const SizedBox(height: 8),
                ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.model,
    required this.installed,
    required this.busy,
    required this.canInstall,
    required this.progress,
    required this.error,
    required this.onInstall,
    required this.onCancel,
    required this.onRemove,
  });

  final SpeechModel model;
  final bool installed;
  final bool busy;

  /// False while another model is installing.
  final bool canInstall;
  final ModelInstallProgress? progress;
  final String? error;
  final VoidCallback onInstall;
  final VoidCallback? onCancel;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final progress = this.progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${model.languageLabel} — ${model.id}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Chip(
                  label: Text(installed ? 'Installed' : 'Not installed'),
                  backgroundColor: installed
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${model.archiveSizeMegabytes} MB · ${model.license} · '
              'checksum verified after download',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(model.caveat, style: Theme.of(context).textTheme.bodySmall),
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress?.fraction),
              const SizedBox(height: 4),
              Text(
                switch (progress?.phase) {
                  ModelInstallPhase.verifying =>
                    'Verifying the archive checksum…',
                  ModelInstallPhase.extracting => 'Extracting the model…',
                  _ =>
                    'Downloading ${progress?.receivedBytes ?? 0} of '
                        '${progress?.totalBytes ?? model.archiveSizeBytes} bytes…',
                },
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: TextStyle(color: colors.error),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (busy)
                  TextButton(onPressed: onCancel, child: const Text('Cancel'))
                else if (installed)
                  OutlinedButton.icon(
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  )
                else
                  FilledButton.icon(
                    onPressed: canInstall ? onInstall : null,
                    icon: const Icon(Icons.download),
                    label: const Text('Install'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
