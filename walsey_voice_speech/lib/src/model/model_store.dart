import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

/// What went wrong while installing a model.
class ModelInstallException implements Exception {
  ModelInstallException(this.message);

  /// Plain-language reason, safe to show in the UI.
  final String message;

  @override
  String toString() => 'ModelInstallException: $message';
}

/// Thrown when the caller cancelled an install between chunks.
class ModelInstallCancelled implements Exception {
  const ModelInstallCancelled();
}

/// Phase of an install, so the UI can label its progress bar.
enum ModelInstallPhase { downloading, verifying, extracting }

/// Progress of an explicit model download/extract.
final class ModelInstallProgress {
  const ModelInstallProgress({
    required this.phase,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final ModelInstallPhase phase;
  final int receivedBytes;
  final int totalBytes;

  /// `null` while the size is unknown.
  double? get fraction =>
      totalBytes <= 0 ? null : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

/// Result of [ModelStore.install].
enum ModelInstallOutcome { installed, alreadyInstalled }

/// Stores Vosk models under `<app support>/walsey_models/<model id>`.
///
/// Nothing here runs at startup. [install] is the only network call in the
/// voice testbed and only happens after the user presses "Install" in the model
/// manager; the typed-command flow never touches this class.
///
/// Validity means what Vosk itself requires: `am/final.mdl` exists inside the
/// model directory. A missing marker is reported as "not installed" so the UI
/// can offer a reinstall instead of crashing during recognition.
class ModelStore {
  ModelStore({
    Future<Directory> Function()? baseDirectory,
    http.Client Function()? clientFactory,
    this.folderName = 'walsey_models',
  }) : _baseDirectory = baseDirectory,
       _clientFactory = clientFactory ?? http.Client.new;

  /// Uses the platform application-support directory.
  factory ModelStore.platform() =>
      ModelStore(baseDirectory: getApplicationSupportDirectory);

  final Future<Directory> Function()? _baseDirectory;
  final http.Client Function() _clientFactory;
  final String folderName;

  Future<Directory> baseDirectory() async {
    final provider = _baseDirectory;
    if (provider != null) {
      return provider();
    }
    return getApplicationSupportDirectory();
  }

  /// Directory holding every installed model.
  Future<Directory> modelsDirectory() async {
    final base = await baseDirectory();
    final directory = Directory(p.join(base.path, folderName));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Absolute model path accepted by `vosk_model_new`, or `null` when the
  /// model is not installed (or incomplete).
  Future<String?> installedModelPath(SpeechModel model) async {
    final base = await baseDirectory();
    final directory = Directory(p.join(base.path, folderName, model.id));
    final marker = File(p.join(directory.path, 'am', 'final.mdl'));
    if (!await marker.exists()) {
      return null;
    }
    return directory.path;
  }

  Future<bool> isInstalled(SpeechModel model) async =>
      await installedModelPath(model) != null;

  /// Downloads, verifies and extracts [model].
  ///
  /// The archive is streamed to a temporary file (never held in memory), its
  /// published MD5 is checked before anything is extracted, and extraction runs
  /// in a background isolate. On any failure the partial download is deleted
  /// and the previous installation (if any) is untouched.
  Future<ModelInstallOutcome> install(
    SpeechModel model, {
    void Function(ModelInstallProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (await isInstalled(model)) {
      return ModelInstallOutcome.alreadyInstalled;
    }
    final root = await modelsDirectory();
    final downloads = Directory(p.join(root.path, '.downloads'));
    await downloads.create(recursive: true);
    final archive = File(p.join(downloads.path, '${model.id}.zip'));
    final extractDirectory = Directory(
      p.join(downloads.path, '${model.id}.extract'),
    );
    try {
      await _download(model, archive, onProgress, isCancelled);
      if (isCancelled?.call() ?? false) {
        throw const ModelInstallCancelled();
      }
      onProgress?.call(
        ModelInstallProgress(
          phase: ModelInstallPhase.verifying,
          receivedBytes: model.archiveSizeBytes,
          totalBytes: model.archiveSizeBytes,
        ),
      );
      final digest = await md5.bind(archive.openRead()).first;
      if (digest.toString() != model.archiveMd5) {
        throw ModelInstallException(
          'The downloaded archive is corrupt (MD5 $digest does not match '
          '${model.archiveMd5}). Delete it and try again.',
        );
      }
      if (await extractDirectory.exists()) {
        await extractDirectory.delete(recursive: true);
      }
      onProgress?.call(
        ModelInstallProgress(
          phase: ModelInstallPhase.extracting,
          receivedBytes: model.archiveSizeBytes,
          totalBytes: model.archiveSizeBytes,
        ),
      );
      final archivePath = archive.path;
      final destinationPath = extractDirectory.path;
      try {
        await Isolate.run(
          () => extractModelArchive(
            archivePath: archivePath,
            destinationPath: destinationPath,
          ),
        );
      } on Object catch (error) {
        throw ModelInstallException(
          'The model archive could not be extracted: $error',
        );
      }
      final modelRoot = await _findModelRoot(extractDirectory);
      if (modelRoot == null) {
        throw ModelInstallException(
          'The archive did not contain a Vosk model (am/final.mdl is '
          'missing).',
        );
      }
      final target = Directory(p.join(root.path, model.id));
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await Directory(modelRoot).rename(target.path);
      return ModelInstallOutcome.installed;
    } finally {
      await _deleteIfExists(archive);
      await _deleteIfExists(extractDirectory);
      await _deleteIfEmpty(downloads);
    }
  }

  /// Removes an installed model. Missing directories are not an error.
  Future<void> remove(SpeechModel model) async {
    final base = await baseDirectory();
    final directory = Directory(p.join(base.path, folderName, model.id));
    await _deleteIfExists(directory);
  }

  Future<void> _download(
    SpeechModel model,
    File target,
    void Function(ModelInstallProgress progress)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final client = _clientFactory();
    try {
      final request = http.Request('GET', Uri.parse(model.downloadUrl));
      final http.StreamedResponse response;
      try {
        response = await client.send(request);
      } on Object catch (error) {
        throw ModelInstallException(
          'Could not reach ${Uri.parse(model.downloadUrl).host}: $error',
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        throw ModelInstallException(
          'Download failed with HTTP ${response.statusCode} from '
          '${model.downloadUrl}.',
        );
      }
      final total = response.contentLength ?? model.archiveSizeBytes;
      final sink = target.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          if (isCancelled?.call() ?? false) {
            throw const ModelInstallCancelled();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(
            ModelInstallProgress(
              phase: ModelInstallPhase.downloading,
              receivedBytes: received,
              totalBytes: total,
            ),
          );
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (received == 0) {
        throw ModelInstallException('The downloaded archive was empty.');
      }
    } finally {
      client.close();
    }
  }

  Future<String?> _findModelRoot(Directory directory) async {
    if (!await directory.exists()) {
      return null;
    }
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (name == 'final.mdl' && p.basename(p.dirname(entity.path)) == 'am') {
        return p.dirname(p.dirname(entity.path));
      }
    }
    return null;
  }

  Future<void> _deleteIfEmpty(Directory directory) async {
    try {
      if (!await directory.exists()) {
        return;
      }
      if (await directory.list().isEmpty) {
        await directory.delete();
      }
    } on FileSystemException {
      // Same as above: a leftover empty folder is harmless.
    }
  }

  Future<void> _deleteIfExists(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) {
        await entity.delete(recursive: true);
      }
    } on FileSystemException {
      // A leftover cache entry is not worth failing an otherwise good install.
    }
  }
}

/// Extracts a Vosk model zip into [destinationPath].
///
/// Top-level so it can run through [Isolate.run]. `extractFileToDisk` rejects
/// archive entries that would escape the destination directory.
Future<void> extractModelArchive({
  required String archivePath,
  required String destinationPath,
}) async {
  await extractFileToDisk(archivePath, destinationPath);
}
