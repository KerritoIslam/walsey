import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:walsey_voice_speech/walsey_voice_speech.dart';

Uint8List pcm16(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

void main() {
  group('WAV encoding', () {
    test('writes a canonical 44-byte PCM header', () {
      final bytes = encodePcm16Wav(
        pcm16([0, 1000, -1000, 32767]),
        sampleRate: 16000,
      );

      expect(bytes.length, 44 + 8);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(bytes.sublist(12, 16)), 'fmt ');
      expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(4, Endian.little), 36 + 8);
      expect(view.getUint32(16, Endian.little), 16);
      expect(view.getUint16(20, Endian.little), 1); // PCM
      expect(view.getUint16(22, Endian.little), 1); // mono
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint32(28, Endian.little), 32000); // byte rate
      expect(view.getUint16(32, Endian.little), 2); // block align
      expect(view.getUint16(34, Endian.little), 16);
      expect(view.getUint32(40, Endian.little), 8);
    });

    test('round-trips through the decoder', () {
      final source = pcm16([1234, -1234, 32767, -32768]);
      final decoded = decodePcm16Wav(encodePcm16Wav(source, sampleRate: 16000));

      expect(decoded.sampleRate, 16000);
      expect(decoded.channels, 1);
      expect(decoded.bitsPerSample, 16);
      expect(decoded.pcm, source);
      expect(decoded.isRecognizerFormat, isTrue);
      expect(decoded.description, '16000 Hz, 1 channel, 16-bit PCM');
      expect(decoded.frameCount, 4);
      expect(decoded.durationSeconds, closeTo(0.00025, 1e-9));
    });

    test('drops a trailing partial sample instead of writing a bad frame', () {
      final odd = Uint8List.fromList([1, 2, 3]);
      final decoded = decodePcm16Wav(encodePcm16Wav(odd, sampleRate: 16000));

      expect(decoded.pcm.length, 2);
    });

    test('rejects non-WAV and non-PCM input', () {
      expect(
        () => decodePcm16Wav(Uint8List.fromList(List.filled(64, 0))),
        throwsFormatException,
      );

      // 32-bit float PCM (format 3) is not something the recognizer accepts.
      final wav = encodePcm16Wav(pcm16([0, 0]), sampleRate: 16000);
      final view = ByteData.sublistView(wav);
      view.setUint16(20, 3, Endian.little);
      expect(() => decodePcm16Wav(wav), throwsFormatException);
    });
  });

  group('AudioStats', () {
    test('measures duration, peak, RMS, clipping and silence', () {
      final stats = AudioStats(declaredSampleRate: 16000)
        ..addChunk(pcm16([0, 1000, -1000, 32767, -32768, 0, 0, 0]));

      expect(stats.sampleCount, 8);
      expect(stats.bytes, 16);
      expect(stats.durationSeconds, closeTo(8 / 16000, 1e-9));
      expect(stats.peakAbs, 32768);
      expect(stats.peakDbfs, closeTo(0, 0.01));
      expect(stats.clippedSamples, 2);
      expect(stats.clippedPercent, 25);
      expect(stats.silentPercent, 50);
      expect(stats.trailingSilenceSeconds, closeTo(3 / 16000, 1e-9));
      expect(stats.isSilent, isFalse);
      expect(stats.rmsDbfs, lessThan(0));
    });

    test('a silent take is reported as silence, and dBFS is -inf', () {
      final stats = AudioStats(declaredSampleRate: 16000)
        ..addChunk(pcm16(List.filled(16000, 0)));

      expect(stats.isSilent, isTrue);
      expect(stats.peakDbfs, double.negativeInfinity);
      expect(stats.trailingSilenceSeconds, closeTo(1.0, 1e-9));
      expect(stats.clippedSamples, 0);
    });

    test('tracks chunk sizes and ignores an odd trailing byte', () {
      final stats = AudioStats(declaredSampleRate: 16000)
        ..addChunk(pcm16([1, 2]))
        ..addChunk(Uint8List.fromList([1, 2, 3]))
        ..addChunk(Uint8List(0));

      expect(stats.chunkCount, 2);
      expect(stats.minChunkBytes, 2);
      expect(stats.maxChunkBytes, 4);
      expect(stats.bytes, 6);
      expect(stats.sampleCount, 3);
    });

    test('json summary is finite and rounded', () {
      final stats = AudioStats(declaredSampleRate: 16000)
        ..addChunk(pcm16([100, -100]));

      final json = stats.toJson();
      expect(json['declaredSampleRate'], 16000);
      expect(json['durationSeconds'], closeTo(0.000125, 1e-9));
      expect(json['peakDbfs'], lessThan(0));
      expect(json['clippedPercent'], 0);
    });
  });

  group('SessionDiagnostics', () {
    test('buffers audio, records the transcript and exports a WAV', () async {
      final directory = await Directory.systemTemp.createTemp('walsey_diag');
      addTearDown(() => directory.delete(recursive: true));
      final diagnostics = SessionDiagnostics();
      addTearDown(diagnostics.dispose);

      diagnostics.beginSession(sampleRate: 16000);
      diagnostics.addChunk(pcm16([100, -100, 200, -200]));
      diagnostics.notePartial();
      diagnostics.addChunk(pcm16([300, -300]));
      diagnostics.complete(transcript: 'turn the lights on');

      expect(diagnostics.rawTranscript, 'turn the lights on');
      expect(diagnostics.bytesSincePartial, 4);
      expect(diagnostics.stats!.sampleCount, 6);
      expect(diagnostics.summaryRows.map((row) => row.$1), contains('Peak'));

      final file = await diagnostics.saveWav(directory);
      expect(file, isNotNull);
      expect(diagnostics.wavPath, file!.path);

      final decoded = decodePcm16Wav(await file.readAsBytes());
      expect(decoded.isRecognizerFormat, isTrue);
      expect(decoded.pcm.length, 12);
      expect(decoded.durationSeconds, closeTo(6 / 16000, 1e-9));
    });

    test('stops buffering at the memory cap and reports truncation', () {
      final diagnostics = SessionDiagnostics(maxBufferedBytes: 1000);
      addTearDown(diagnostics.dispose);

      diagnostics.beginSession(sampleRate: 16000);
      diagnostics.addChunk(Uint8List(800));
      diagnostics.addChunk(Uint8List(800));

      expect(diagnostics.bufferedBytes, 1000);
      expect(diagnostics.bufferTruncated, isTrue);
      expect(diagnostics.stats!.bytes, 1600);
      expect(diagnostics.wavBytes().length, 44 + 1000);
    });

    test('cancel drops the transcript but keeps the measurements', () {
      final diagnostics = SessionDiagnostics();
      addTearDown(diagnostics.dispose);

      diagnostics.beginSession(sampleRate: 16000);
      diagnostics.addChunk(pcm16([1000, -1000]));
      diagnostics.complete(transcript: 'turn the lights on');
      diagnostics.cancel();

      expect(diagnostics.rawTranscript, isNull);
      expect(diagnostics.stats!.sampleCount, 2);
      expect(diagnostics.hasSession, isTrue);
    });

    test('clear forgets the session entirely', () {
      final diagnostics = SessionDiagnostics();
      addTearDown(diagnostics.dispose);

      diagnostics.beginSession(sampleRate: 16000);
      diagnostics.addChunk(pcm16([1000]));
      diagnostics.clear();

      expect(diagnostics.hasSession, isFalse);
      expect(diagnostics.stats, isNull);
      expect(diagnostics.summaryRows, isEmpty);
    });

    test(
      'records how long the microphone took to deliver the first chunk',
      () async {
        final diagnostics = SessionDiagnostics();
        addTearDown(diagnostics.dispose);

        diagnostics.beginSession(sampleRate: 16000);
        expect(diagnostics.firstChunkDelay, isNull);

        // Stand-in for the ~750 ms the Windows `record` plugin really needs to
        // open the device: the measurement must be visible, not silently lost.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        diagnostics.addChunk(pcm16([1, 2]));
        final firstDelay = diagnostics.firstChunkDelay;
        expect(firstDelay, isNotNull);
        expect(firstDelay!.inMilliseconds, greaterThanOrEqualTo(100));
        expect(
          diagnostics.summaryRows.map((row) => row.$1),
          contains('First audio'),
        );

        // Later chunks must not move the reported start.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        diagnostics.addChunk(pcm16([3, 4]));
        expect(diagnostics.firstChunkDelay, firstDelay);
      },
    );

    test('a new session forgets the previous first-chunk delay', () async {
      final diagnostics = SessionDiagnostics();
      addTearDown(diagnostics.dispose);

      diagnostics.beginSession(sampleRate: 16000);
      diagnostics.addChunk(pcm16([1]));
      expect(diagnostics.firstChunkDelay, isNotNull);

      diagnostics.beginSession(sampleRate: 16000);
      expect(diagnostics.firstChunkDelay, isNull);

      diagnostics.addChunk(pcm16([2]));
      diagnostics.clear();
      expect(diagnostics.firstChunkDelay, isNull);
    });

    test('rate ratio compares audio duration with wall-clock time', () async {
      final diagnostics = SessionDiagnostics();
      addTearDown(diagnostics.dispose);

      diagnostics.beginSession(sampleRate: 16000);
      expect(diagnostics.rateRatio, isNull);

      // 0.25 s of wall-clock time and 0.25 s of audio must read ~1.0; a 48 kHz
      // stream mislabelled as 16 kHz would read ~3.0.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      diagnostics.addChunk(Uint8List(16000 * 2 * 250 ~/ 1000));
      diagnostics.closeCapture();

      expect(diagnostics.rateRatio, isNotNull);
      expect(diagnostics.rateRatio!, closeTo(1.0, 0.25));
    });
  });
}
