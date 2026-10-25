import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

/// Builds the smallest archive that looks like a Vosk model to the store.
List<int> buildModelArchive({String prefix = 'vosk-model-test'}) {
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('$prefix/am/final.mdl', const [1, 2, 3]))
    ..addFile(
      ArchiveFile.bytes(
        '$prefix/conf/mfcc.conf',
        utf8.encode('sample-rate=16000'),
      ),
    )
    ..addFile(ArchiveFile.bytes('$prefix/README', utf8.encode('test model')));
  return ZipEncoder().encode(archive);
}

void main() {
  late Directory tempDirectory;
  late HttpServer server;
  late List<int> payload;
  late int statusCode;
  late int requests;
  late SpeechModel model;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('walsey_model_test');
    payload = buildModelArchive();
    statusCode = HttpStatus.ok;
    requests = 0;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.statusCode = statusCode;
      if (statusCode == HttpStatus.ok) {
        request.response.headers.contentType = ContentType(
          'application',
          'zip',
        );
        request.response.contentLength = payload.length;
        request.response.add(payload);
      }
      await request.response.close();
    });

    model = SpeechModel(
      id: 'vosk-model-test',
      languageId: 'xx',
      languageLabel: 'Test',
      downloadUrl: 'http://127.0.0.1:${server.port}/model.zip',
      archiveSizeBytes: payload.length,
      archiveMd5: md5.convert(payload).toString(),
      license: 'Apache License 2.0',
      caveat: 'Test model only.',
    );
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  ModelStore buildStore() =>
      ModelStore(baseDirectory: () async => tempDirectory);

  test('install downloads, verifies, extracts and cleans up', () async {
    final store = buildStore();
    final phases = <ModelInstallPhase>[];

    final outcome = await store.install(
      model,
      onProgress: (progress) => phases.add(progress.phase),
    );

    expect(outcome, ModelInstallOutcome.installed);
    expect(requests, 1);
    expect(await store.isInstalled(model), isTrue);

    final installed = await store.installedModelPath(model);
    expect(installed, isNotNull);
    expect(
      await File(
        '$installed${Platform.pathSeparator}am'
        '${Platform.pathSeparator}final.mdl',
      ).exists(),
      isTrue,
    );
    expect(phases, contains(ModelInstallPhase.downloading));
    expect(phases, contains(ModelInstallPhase.extracting));

    final downloads = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}walsey_models'
      '${Platform.pathSeparator}.downloads',
    );
    expect(
      await downloads.exists(),
      isFalse,
      reason: 'temp files must be removed',
    );
  });

  test('a corrupt checksum is rejected and nothing is installed', () async {
    final store = buildStore();
    final broken = SpeechModel(
      id: model.id,
      languageId: model.languageId,
      languageLabel: model.languageLabel,
      downloadUrl: model.downloadUrl,
      archiveSizeBytes: model.archiveSizeBytes,
      archiveMd5: '00000000000000000000000000000000',
      license: model.license,
      caveat: model.caveat,
    );

    await expectLater(
      store.install(broken),
      throwsA(
        isA<ModelInstallException>().having(
          (error) => error.message,
          'message',
          contains('corrupt'),
        ),
      ),
    );
    expect(await store.isInstalled(broken), isFalse);
  });

  test('cancellation aborts between chunks and removes the download', () async {
    final store = buildStore();
    var sawProgress = false;

    await expectLater(
      store.install(
        model,
        onProgress: (_) => sawProgress = true,
        isCancelled: () => sawProgress,
      ),
      throwsA(isA<ModelInstallCancelled>()),
    );

    expect(await store.isInstalled(model), isFalse);
    final downloads = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}walsey_models'
      '${Platform.pathSeparator}.downloads',
    );
    expect(await downloads.exists(), isFalse);
  });

  test('an HTTP error is reported without touching the model folder', () async {
    statusCode = HttpStatus.notFound;
    final store = buildStore();

    await expectLater(
      store.install(model),
      throwsA(isA<ModelInstallException>()),
    );
    expect(requests, 1);
    expect(await store.isInstalled(model), isFalse);
  });

  test('an already installed model is not downloaded again', () async {
    final store = buildStore();
    await store.install(model);
    final before = requests;

    final outcome = await store.install(model);

    expect(outcome, ModelInstallOutcome.alreadyInstalled);
    expect(requests, before);
  });

  test('an archive without am/final.mdl is rejected', () async {
    final store = buildStore();
    final wrongPayload = ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile.bytes('model/README', utf8.encode('no model'))),
    );
    final wrong = SpeechModel(
      id: 'vosk-model-wrong',
      languageId: 'xx',
      languageLabel: 'Test',
      downloadUrl: model.downloadUrl,
      archiveSizeBytes: wrongPayload.length,
      archiveMd5: md5.convert(wrongPayload).toString(),
      license: 'Apache License 2.0',
      caveat: 'Test model only.',
    );
    payload = wrongPayload;

    await expectLater(
      store.install(wrong),
      throwsA(
        isA<ModelInstallException>().having(
          (error) => error.message,
          'message',
          contains('am/final.mdl'),
        ),
      ),
    );
  });

  test('remove deletes the installed model', () async {
    final store = buildStore();
    await store.install(model);
    expect(await store.isInstalled(model), isTrue);

    await store.remove(model);

    expect(await store.isInstalled(model), isFalse);
  });
}
