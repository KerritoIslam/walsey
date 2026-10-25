import 'dart:io';

import 'package:path/path.dart' as p;

/// Facts about an installed Vosk model folder that matter to recognition.
///
/// Vosk ships two graph layouts:
///  * static `graph/HCLG.fst` — fast, but `vosk_recognizer_new_grm` cannot use
///    it (Kaldi aborts on "model does not support grammars");
///  * dynamic `graph/HCLr.fst` + `graph/Gr.fst` — the same model can be
///    re-scored against a runtime grammar.
///
/// Checking the files first means a grammar experiment either runs correctly or
/// is refused with an explanation, instead of crashing the process inside the
/// native library.
final class VoskModelInfo {
  const VoskModelInfo({
    required this.path,
    required this.sizeBytes,
    required this.fileCount,
    required this.hasDynamicGraph,
    required this.hasStaticGraph,
    required this.sampleRate,
  });

  /// Absolute model directory, as passed to `vosk_model_new`.
  final String path;

  /// Extracted size on disk.
  final int sizeBytes;

  final int fileCount;

  /// `graph/HCLr.fst` and `graph/Gr.fst` are both present.
  final bool hasDynamicGraph;

  /// `graph/HCLG.fst` is present (static graph).
  final bool hasStaticGraph;

  /// Sample rate declared by `conf/mfcc.conf`, or `null` when unreadable.
  final int? sampleRate;

  /// Runtime grammars are supported only by models with a dynamic graph.
  bool get supportsGrammar => hasDynamicGraph;

  double get sizeMegabytes => sizeBytes / (1024 * 1024);

  String get graphDescription {
    if (hasDynamicGraph) {
      return 'dynamic (HCLr.fst + Gr.fst) — runtime grammar supported';
    }
    if (hasStaticGraph) {
      return 'static (HCLG.fst) — runtime grammar not supported';
    }
    return 'unrecognised (no HCLG.fst, HCLr.fst or Gr.fst found)';
  }

  /// Reads the model folder. Returns `null` when [path] is not a directory.
  static Future<VoskModelInfo?> inspect(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      return null;
    }
    var bytes = 0;
    var files = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        files++;
        try {
          bytes += await entity.length();
        } on FileSystemException {
          // A file disappearing mid-scan is not worth failing the inspection.
        }
      }
    }

    final graph = Directory(p.join(directory.path, 'graph'));
    final hasDynamic =
        await File(p.join(graph.path, 'HCLr.fst')).exists() &&
        await File(p.join(graph.path, 'Gr.fst')).exists();
    final hasStatic = await File(p.join(graph.path, 'HCLG.fst')).exists();

    int? rate;
    try {
      final conf = File(p.join(directory.path, 'conf', 'mfcc.conf'));
      if (await conf.exists()) {
        for (final line in await conf.readAsLines()) {
          final match = RegExp(
            r'--sample-frequency\s*=\s*(\d+)',
          ).firstMatch(line.trim());
          if (match != null) {
            rate = int.parse(match.group(1)!);
          }
        }
      }
    } on FileSystemException {
      rate = null;
    }

    return VoskModelInfo(
      path: directory.path,
      sizeBytes: bytes,
      fileCount: files,
      hasDynamicGraph: hasDynamic,
      hasStaticGraph: hasStatic,
      sampleRate: rate,
    );
  }
}
