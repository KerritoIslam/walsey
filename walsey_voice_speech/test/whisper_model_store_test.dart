import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

const leGgmlMagic = [0x6c, 0x6d, 0x67, 0x67];
const asciiGgmlMagic = [0x67, 0x67, 0x6d, 0x6c];
const ggufMagic = [0x47, 0x47, 0x55, 0x46];

/// A tiny stand-in for `ggml-base.en.bin`: the header magic the store checks
/// plus a fixed-size body. Sizes and digests are computed from these bytes,
/// exactly like a real publisher would publish them.
List<int> fakeWhisperFile({List<int> magic = leGgmlMagic, int body = 12}) => [
      ...magic,
      ...List.filled(body, 0xAB),
    ];

void main() {
  late Directory tempDirectory;
  late HttpServer server;
  late List<int> payload;
  late int statusCode;
  late int requests;
  late SpeechModel model;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('walsey_whisper_test');
    payload = fakeWhisperFile();
    statusCode = HttpStatus.ok;
    requests = 0;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.statusCode = statusCode;
      if (statusCode == HttpStatus.ok) {
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = payload.length;
        request.response.add(payload);
      }
      await request.response.close();
    });

    model = SpeechModel(
      id: 'ggml-test',
      languageId: 'en-US',
      languageLabel: 'English (US)',
      kind: ModelKind.whisperGgml,
      modelFileName: 'ggml-test.bin',
      downloadUrl: 'http://127.0.0.1:${server.port}/ggml-test.bin',
      archiveSizeBytes: payload.length,
      archiveMd5: md5.convert(payload).toString(),
      modelSha256: sha256.convert(payload).toString(),
      license: 'MIT',
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

  File installedFile() => File(
        '${tempDirectory.path}${Platform.pathSeparator}walsey_models'
        '${Platform.pathSeparator}ggml-test'
        '${Platform.pathSeparator}ggml-test.bin',
      );

  group('installedModelPath validation', () {
    test('a file of the published size with a known magic is installed', () async {
      final store = buildStore();
      final file = await installedFile().create(recursive: true);
      await file.writeAsBytes(payload);

      final path = await store.installedModelPath(model);

      expect(path, isNotNull);
      expect(path, endsWith('ggml-test.bin'));
      expect(await store.isInstalled(model), isTrue);
    });

    test('the little-endian ggml magic of the real base.en model is accepted',
        () async {
      final store = buildStore();
      final file = await installedFile().create(recursive: true);
      await file.writeAsBytes(fakeWhisperFile(magic: leGgmlMagic));
      expect(await store.isInstalled(model), isTrue);
    });

    test('plain ggml ASCII and GGUF magics are accepted too', () async {
      final store = buildStore();
      final file = await installedFile().create(recursive: true);
      await file.writeAsBytes(fakeWhisperFile(magic: asciiGgmlMagic));
      expect(await store.isInstalled(model), isTrue);
      await file.writeAsBytes(fakeWhisperFile(magic: ggufMagic));
      expect(await store.isInstalled(model), isTrue);
    });

    test('a file of the wrong size is not installed', () async {
      final store = buildStore();
      final file = await installedFile().create(recursive: true);
      await file.writeAsBytes([...payload, 0x00]);

      expect(await store.isInstalled(model), isFalse);
      expect(await store.installedModelPath(model), isNull);
    });

    test('a foreign header is not installed', () async {
      final store = buildStore();
      final file = await installedFile().create(recursive: true);
      await file.writeAsBytes(fakeWhisperFile(magic: [0x4e, 0x4f, 0x50, 0x45]));

      expect(await store.isInstalled(model), isFalse);
    });

    test('a missing file is not installed', () async {
      final store = buildStore();

      expect(await store.isInstalled(model), isFalse);
    });
  });

  group('install', () {
    test('streams, verifies and installs the single file', () async {
      final store = buildStore();
      final phases = <ModelInstallPhase>[];

      final outcome = await store.install(
        model,
        onProgress: (progress) => phases.add(progress.phase),
      );

      expect(outcome, ModelInstallOutcome.installed);
      expect(requests, 1);
      final file = installedFile();
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), payload);

      final downloads = Directory(
        '${tempDirectory.path}${Platform.pathSeparator}walsey_models'
        '${Platform.pathSeparator}.downloads',
      );
      expect(
        await downloads.exists(),
        isFalse,
        reason: 'the staged download must be gone after the atomic rename',
      );
      expect(phases, contains(ModelInstallPhase.downloading));
      expect(phases, contains(ModelInstallPhase.verifying));
    });

    test('a corrupt MD5 is rejected and nothing is installed', () async {
      final store = buildStore();
      final broken = SpeechModel(
        id: model.id,
        languageId: model.languageId,
        languageLabel: model.languageLabel,
        kind: model.kind,
        modelFileName: model.modelFileName,
        downloadUrl: model.downloadUrl,
        archiveSizeBytes: model.archiveSizeBytes,
        archiveMd5: '00000000000000000000000000000000',
        modelSha256: model.modelSha256,
        license: model.license,
        caveat: model.caveat,
      );

      await expectLater(
        store.install(broken),
        throwsA(
          isA<ModelInstallException>().having(
            (error) => error.message,
            'message',
            contains('MD5'),
          ),
        ),
      );
      expect(await store.isInstalled(broken), isFalse);
      expect(await installedFile().exists(), isFalse);
    });

    test('a wrong SHA-256 is rejected even when the size matches', () async {
      final store = buildStore();
      final broken = SpeechModel(
        id: model.id,
        languageId: model.languageId,
        languageLabel: model.languageLabel,
        kind: model.kind,
        modelFileName: model.modelFileName,
        downloadUrl: model.downloadUrl,
        archiveSizeBytes: model.archiveSizeBytes,
        archiveMd5: model.archiveMd5,
        modelSha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        license: model.license,
        caveat: model.caveat,
      );

      await expectLater(
        store.install(broken),
        throwsA(
          isA<ModelInstallException>().having(
            (error) => error.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(await installedFile().exists(), isFalse);
    });

    test('a short download is rejected against the published size', () async {
      final store = buildStore();
      payload = payload.sublist(0, 8);

      await expectLater(
        store.install(model),
        throwsA(
          isA<ModelInstallException>().having(
            (error) => error.message,
            'message',
            contains('${model.archiveSizeBytes}'),
          ),
        ),
      );
      expect(await installedFile().exists(), isFalse);
    });

    test('an empty download is rejected', () async {
      final store = buildStore();
      payload = <int>[];

      await expectLater(store.install(model), throwsA(isA<ModelInstallException>()));
      expect(await installedFile().exists(), isFalse);
    });

    test('an HTTP error is reported without touching the model folder', () async {
      statusCode = HttpStatus.notFound;
      final store = buildStore();

      await expectLater(store.install(model), throwsA(isA<ModelInstallException>()));
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

    test('cancellation aborts between chunks and installs nothing', () async {
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
      expect(await installedFile().exists(), isFalse);
    });
  });

  test('remove deletes the installed model file', () async {
    final store = buildStore();
    await store.install(model);
    expect(await store.isInstalled(model), isTrue);

    await store.remove(model);

    expect(await store.isInstalled(model), isFalse);
    expect(await installedFile().exists(), isFalse);
  });
}
